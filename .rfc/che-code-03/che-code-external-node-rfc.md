# RFC — Exécuter che-code avec le Node.js de l'image de dev

Oct 13, 2026 · @Maxime · Statut : Draft

## Résumé

L'image che-code embarque un Node.js dans chacune de ses trois assemblies (musl, ubi8, ubi9), avec les bibliothèques partagées dont il dépend (`ld_libs/`). L'init container copie tout cela dans le volume `checode`, puis `entrypoint-volume.sh` lance le launcher et le serveur VS Code avec ce Node.

Cette RFC ajoute une variante de l'image **sans Node** : l'init container copie tout l'IDE sauf le binaire `node` et `ld_libs/`, et `entrypoint-volume.sh` utilise obligatoirement le Node de l'image de dev. Pas de repli sur un Node embarqué : si l'image de dev n'a pas de Node compatible, le conteneur s'arrête avec un message clair.

Le changement touche `build/dockerfiles/assembly.Dockerfile` et `build/scripts/entrypoint-volume.sh` dans `weebo-si/che-code`, le workflow de `che-images` (un second tag) et une editor definition dans `deploy/`. Le launcher ne change pas.

## Contexte et motivation

### Le Node embarqué pose des problèmes

- **ICU incomplet.** Le Node des assemblies UBI est construit avec `small-icu` sans le fichier de données `icudt*.dat` (paquet `nodejs-full-i18n` non installé). `Intl.Segmenter().segment()` y provoque un segfault de l'extension host, qui emporte toutes les extensions sans message d'erreur. Constaté avec `vscode-markdownlint` 0.61+ ([batlehub RFC 0034](https://github.com/batlehub/batlehub/blob/main/docs/rfc/0034-full-icu-node.md)). Le contournement actuel est un `NODE_ICU_DATA` dans le devfile.
- **Correctifs de sécurité.** Une CVE Node demande une nouvelle image che-code. Le Node de l'image de dev suit le cycle de mise à jour de cette image, que l'équipe qui la maintient contrôle.
- **Taille copiée.** L'init container copie trois Node et leurs bibliothèques à chaque premier boot (et à chaque changement d'image, voir [che-code-01](../che-code-01/che-code-startup-rfc.md)). Cela pèse dans la copie de 2,7 Go qui finit en `OOMKilled` à 256Mi (che-code-01, [Risques](../che-code-01/che-code-startup-rfc.md#risques)).

### Ce qui existe déjà

`entrypoint-volume.sh` accepte déjà un Node externe :

```sh
if [ -z "$VSCODE_NODEJS_RUNTIME_DIR" ]; then
  export VSCODE_NODEJS_RUNTIME_DIR="$(pwd)"
fi
"$VSCODE_NODEJS_RUNTIME_DIR/node" ./launcher/entrypoint.js
```

Le launcher (`launcher/src/vscode-launcher.ts`) lance `${VSCODE_NODEJS_RUNTIME_DIR}/node out/server-main.js`. Ensuite, tout le serveur VS Code réutilise `process.execPath` : extension host, pty host, file watcher, askpass de git (`VSCODE_GIT_ASKPASS_NODE`). Un seul point d'entrée décide donc du Node de tout l'IDE. Le README `build/dockerfiles/README.md` documente cet usage.

Ce mécanisme ne suffit pas :

- l'image copie toujours les trois Node et `ld_libs/` ;
- `entrypoint-volume.sh` ajoute `ld_libs/core` (qui contient `libnode.so*`, `libz`, `libbrotli`) et `ld_libs/openssl` à `LD_LIBRARY_PATH` **même quand `VSCODE_NODEJS_RUNTIME_DIR` est fourni**. Un Node UBI de l'image de dev, lié dynamiquement à `libnode.so`, chargerait alors la `libnode.so` de che-code au lieu de la sienne. À remonter upstream indépendamment de cette RFC ;
- rien ne vérifie que la version de Node fournie est compatible.

### Ce qui dépend de la version de Node

- Le code de VS Code cible la version de `code/remote/.npmrc` (`target="24.17.0"` aujourd'hui).
- Les modules natifs du serveur (`node-pty`, `@parcel/watcher`, `@vscode/spdlog`, `@vscode/sqlite3`, `kerberos`, `@vscode/deviceid`) sont compilés pendant le build de chaque assembly. S'ils utilisent N-API, ils fonctionnent sur tout Node ≥ celui du build. Sinon, ils exigent le même `NODE_MODULE_VERSION` (même majeure). À vérifier à l'implémentation.
- Les assemblies restent nécessaires même sans Node : les modules natifs sont liés à musl ou à la glibc d'UBI 8 / UBI 9.

Exemple concret : ce workspace (`che-min-mise`) fournit Node 26.10 via mise. Il ne pourrait pas servir tel quel avec un che-code basé sur Node 24.

## Objectifs et non-objectifs

**Objectifs**

1. Une variante de l'image che-code dont les assemblies ne contiennent ni `node` ni `ld_libs/`.
2. Avec cette variante, l'IDE (launcher, serveur, extension host, terminaux, git) tourne avec le Node de l'image de dev, et lui seul.
3. Échec explicite au démarrage si l'image de dev n'a pas de Node, ou pas la bonne majeure, avec un message qui dit quoi faire.
4. L'image actuelle (Node embarqué) reste construite et inchangée, pour les images de dev qui n'ont pas de Node compatible.

**Non-objectifs**

- Supprimer le Node de l'image par défaut, ou changer le comportement de l'image actuelle.
- Fusionner les assemblies ubi8 et ubi9 (elles restent nécessaires pour la glibc des modules natifs).
- Fournir le Node par une autre image ou un autre volume (sidecar, image d'outillage).
- Modifier le launcher ou le code de VS Code.

## Conception

### Image : `assembly.Dockerfile`

Un argument de build `CHECODE_NODE`, `bundled` par défaut. Avec `external`, l'étage `ubi-builder` supprime Node et ses bibliothèques, puis note la version attendue dans chaque assembly :

```dockerfile
ARG CHECODE_NODE=bundled
COPY code/remote/.npmrc /tmp/remote.npmrc
# external: the IDE runs with the Node.js of the dev container, see entrypoint-volume.sh
RUN if [ "$CHECODE_NODE" = "external" ]; then \
      node_version=$(sed -n 's/^target="\(.*\)"/\1/p' /tmp/remote.npmrc) \
      && for a in checode-linux-musl checode-linux-libc/ubi8 checode-linux-libc/ubi9; do \
           rm -rf "$a/node" "$a/ld_libs" \
           && printf '%s' "$node_version" > "$a/node.required"; \
         done; \
    fi
```

- Placé **avant** le calcul de la clé de version de che-code-01 : le hash change avec la variante, donc passer d'une variante à l'autre sur un même volume refait une copie complète.
- `node.required` dans l'assembly (et non à la racine) : il est copié dans le volume par le `cp -r /checode-*` existant, sans toucher à l'init container. Sa présence signale la variante `external` à `entrypoint-volume.sh`.
- L'init container ne change pas : il copie ce qui est dans l'image, c'est-à-dire tout l'IDE sauf Node.

À vérifier à l'implémentation : que `node` et `ld_libs/` sont bien les seuls fichiers propres à Node dans les assemblies (`find` sur l'image), et le gain de taille (`du -sh` par assembly, avant et après).

### Démarrage : `entrypoint-volume.sh`

Après le choix de l'assembly (inchangé), et à la place du bloc `VSCODE_NODEJS_RUNTIME_DIR` actuel :

```sh
if [ -f node.required ]; then
  # This assembly ships no Node.js: the dev container must provide it
  required=$(cat node.required)
  if [ -z "$VSCODE_NODEJS_RUNTIME_DIR" ]; then
    node_bin=$(command -v node) || node_bin=""
    VSCODE_NODEJS_RUNTIME_DIR=${node_bin%/node}
  fi
  export VSCODE_NODEJS_RUNTIME_DIR
  actual=$("$VSCODE_NODEJS_RUNTIME_DIR/node" -p 'process.versions.node' 2>/dev/null) || actual=""
  if [ "${actual%%.*}" != "${required%%.*}" ]; then
    echo "[ERROR] This che-code image uses the Node.js of the dev container: Node.js ${required%%.*}.x is required, found '${actual:-none}' in '${VSCODE_NODEJS_RUNTIME_DIR:-PATH}'."
    echo "[ERROR] Install Node.js ${required%%.*} in the dev image and set VSCODE_NODEJS_RUNTIME_DIR to its bin directory, or use the che-code editor with bundled Node.js."
    exit 1
  fi
  # The assembly has no ld_libs: keep the dev container libraries
  runtime_ld_library_path=""
elif [ -z "$VSCODE_NODEJS_RUNTIME_DIR" ]; then
  export VSCODE_NODEJS_RUNTIME_DIR="$(pwd)"
fi
```

Le bloc `LD_LIBRARY_PATH` existant passe après ce bloc, pour profiter du `runtime_ld_library_path=""`.

Points de conception :

- **Résolution du Node.** `VSCODE_NODEJS_RUNTIME_DIR` d'abord (explicite, recommandé), sinon le `node` du `PATH`. Le `PATH` est celui de l'image (`ENV`), pas celui d'un shell interactif : un Node installé par `mise activate` dans `.bashrc` n'est pas vu.
- **Shims mise / asdf / nvm.** Un shim choisit la version selon le répertoire courant (ici l'assembly, puis `PROJECT_SOURCE` pour les processus fils). Il faut que `VSCODE_NODEJS_RUNTIME_DIR` pointe vers un répertoire d'installation fixe (`.../installs/node/24.x/bin`), pas vers les shims. Le contrôle de version attrape le cas où le shim renvoie une autre majeure au démarrage, pas un changement ultérieur. À documenter pour les images de dev.
- **Contrôle sur la majeure seulement.** Une version mineure plus récente que `target` est acceptée. Une majeure différente est refusée, même plus récente, tant que la compatibilité des modules natifs et du code VS Code n'est pas vérifiée (voir [Questions ouvertes](#questions-ouvertes)).
- **Échec.** `exit 1` arrête le conteneur `che-code` : le workspace passe en échec et le message est dans les logs du conteneur. C'est le « forcer » demandé : pas de repli silencieux sur un Node qui n'existe plus.
- **`LD_LIBRARY_PATH`.** Non modifié dans la variante `external`, donc le Node de l'image de dev et les terminaux voient exactement les bibliothèques de l'image.
- **Image par défaut.** Sans `node.required`, le comportement est celui d'aujourd'hui, y compris avec un `VSCODE_NODEJS_RUNTIME_DIR` fourni.

### Build et déploiement

- **`che-images`.** Le job d'assemblage `che-code` est lancé une seconde fois avec `--build-arg CHECODE_NODE=external`, sur les mêmes artefacts de plateforme (les jobs `linux-musl`, `linux-libc-ubi8`, `linux-libc-ubi9` ne sont pas refaits). Tags : `<ref>-external-node` et `sha-<7>-external-node`, mêmes labels OCI et même signature cosign.
- **`deploy/`.** Une seconde editor definition, `deploy/develop/che-code-external-node-editor.yaml`, copie de `che-code-editor.yaml` avec l'image `-external-node`, un autre `metadata.name` et une description qui précise le prérequis Node. Les deux éditeurs sont proposés dans le dashboard, le devfile choisit.
- **Images de dev.** Prérequis de la variante, à documenter dans `che-images` :
  - Node.js de la majeure de `code/remote/.npmrc` (24 aujourd'hui), compilé pour la même libc que l'image ;
  - ICU complet recommandé (`nodejs-full-i18n` sur UBI, ou Node officiel de nodejs.org, qui l'inclut) ;
  - `ENV VSCODE_NODEJS_RUNTIME_DIR=<répertoire bin de ce Node>`.
  - Pour `che-min-mise` : installer un Node 24 en plus du Node de l'utilisateur, à un chemin fixe, et le déclarer dans `VSCODE_NODEJS_RUNTIME_DIR`.

### Montée de version de Node dans VS Code

Quand un rebase de che-code fait passer `target` à une nouvelle majeure (24 → 26), les workspaces dont l'image de dev n'a pas été mise à jour échouent au démarrage avec le message ci-dessus. C'est le prix du découplage. Le plan de rebase de che-code doit inclure : annoncer la nouvelle majeure, mettre à jour les images de dev maintenues par weebo-si, puis seulement publier le tag `-external-node`.

## Stratégie de tests

**Automatisés**

- Au build de la variante `external`, un contrôle dans `assembly.Dockerfile` échoue s'il reste un fichier `node` ou un répertoire `ld_libs` dans `checode-*`, ou si `node.required` est vide.
- Les tests existants du launcher et du build restent verts (ils tournent dans les builds de plateforme, avec le Node du builder).

**Manuels, sur le cluster weebo-si, avec l'editor definition `-external-node`**

1. Image de dev UBI 9 avec `nodejs:24` et `nodejs-full-i18n`, `VSCODE_NODEJS_RUNTIME_DIR=/usr/bin` : l'IDE démarre, `ps` montre ce Node pour le serveur et l'extension host, `LD_LIBRARY_PATH` n'est pas modifié.
2. Même image : terminal (`node-pty`), recherche de fichiers et file watcher (`@parcel/watcher`), `git push` avec askpass, `vscode-markdownlint` ≥ 0.61 sur un fichier Markdown (le segfault ICU ne se produit pas).
3. Image de dev Alpine avec `nodejs` 24 : l'assembly musl est choisie et l'IDE démarre.
4. Image de dev UBI 8 avec Node 24 : l'assembly ubi8 est choisie et l'IDE démarre.
5. Image de dev sans Node : le conteneur s'arrête, le message d'erreur est dans les logs et le dashboard affiche le workspace en échec.
6. Image de dev avec Node 26 seulement (`che-min-mise` actuelle) : même échec, avec la version trouvée dans le message.
7. Même workspace, passage de l'éditeur par défaut à l'éditeur `-external-node` puis retour : copie complète à chaque changement (che-code-01), extensions et settings conservés.
8. Image par défaut : aucun changement de comportement (non-régression).

**Mesures** : taille de l'image et de chaque assembly, durée de `che-code-injector` au premier boot, et premier boot à 256Mi (l'OOM de che-code-01 disparaît-il ?).

## Risques

- **Couplage des images de dev à la majeure de Node de VS Code.** Chaque montée de majeure casse les images non mises à jour. Mitigé par le message d'erreur explicite, l'éditeur par défaut toujours disponible et la procédure de rebase ci-dessus.
- **Node de l'image de dev non standard.** Un Node compilé avec d'autres options (sans `inspector`, sans OpenSSL, `small-icu` sans données) peut faire échouer des fonctions de VS Code ou des extensions sans erreur au démarrage. Le contrôle ne porte que sur la version. Les images de dev weebo-si sont testées avec la liste ci-dessus, les autres sont sous la responsabilité de leurs mainteneurs.
- **Modules natifs.** Si l'un d'eux n'est pas N-API, un Node d'une autre mineure peut quand même poser problème (rare, `NODE_MODULE_VERSION` ne change qu'aux majeures). À confirmer à l'implémentation.
- **Shims de gestionnaires de versions.** Voir [Conception](#démarrage--entrypoint-volumesh). Le contrôle au démarrage ne couvre pas un shim qui changerait de version selon le projet ouvert.
- **Support upstream.** La variante n'existe que chez weebo-si. Les conflits de rebase sont limités à deux fichiers.

## Plan de livraison

1. Branche `feat/external-node` sur `weebo-si/che-code`, avec `Signed-off-by` sur chaque commit, puis ajout à `develop.merge`.
2. Vérifier la liste des fichiers propres à Node et le type (N-API ou non) des modules natifs, mettre à jour cette RFC.
3. `che-images` : second assemblage `CHECODE_NODE=external` et tags `-external-node`.
4. Construire une image de dev de test (UBI 9 + Node 24 full-i18n), déployer l'editor definition `-external-node`, dérouler les tests manuels et les mesures.
5. Mettre à jour les images de dev weebo-si (`che-min-mise` : Node 24 fixe et `VSCODE_NODEJS_RUNTIME_DIR`), puis retirer le contournement `NODE_ICU_DATA` des devfiles qui utilisent l'éditeur `-external-node`.
6. Séparément : proposer upstream de ne pas ajouter `ld_libs` à `LD_LIBRARY_PATH` quand `VSCODE_NODEJS_RUNTIME_DIR` est fourni (bug existant, indépendant de la variante).

## Licences

- `che-code` est sous EPL-2.0. `assembly.Dockerfile` et `entrypoint-volume.sh` gardent leur en-tête Red Hat, sans ligne weebo-si ajoutée.
- Aucune nouvelle dépendance. La variante retire des composants de l'image (Node.js sous MIT, OpenSSL sous Apache-2.0, zlib, brotli) : leurs notices ne sont plus à fournir pour cette image. Celles de VS Code (MIT) restent.
- Les images de dev qui fournissent Node doivent garder sa licence et ses notices (Node officiel ou paquet distribution, qui les incluent).
- La variante est une image distribuée : construite depuis un commit poussé sur le fork public `weebo-si/che-code`, avec les labels `org.opencontainers.image.source`, `.revision` et `.licenses` (EPL-2.0 §3.2).

## Alternatives considérées

- **`VSCODE_NODEJS_RUNTIME_DIR` avec l'image actuelle.** Fonctionne déjà, sans build. Mais l'image copie toujours trois Node, `LD_LIBRARY_PATH` injecte la `libnode.so` de che-code dans le Node de l'image de dev, et rien n'impose ni ne vérifie le Node utilisé. Reste le contournement possible en attendant cette RFC.
- **Une seule image, exclusion de Node par l'init container (variable d'environnement).** Évite un second tag. Mais l'image garde Node (pull et stockage inchangés), `cp` de coreutils n'a pas d'exclusion (il faudrait copier puis supprimer, ou ajouter `find`/`rsync`), et la clé de version de che-code-01 devrait intégrer la variable. Rejeté.
- **Repli sur un Node embarqué si l'image de dev n'en a pas.** Contraire à l'objectif : l'image devrait garder Node, et un repli silencieux masquerait une image de dev mal configurée. Rejeté.
- **Fournir Node par un volume ou une image d'outillage séparée.** Découple Node de che-code sans dépendre de l'image de dev, mais ne règle ni le cycle de mise à jour ni l'ICU, et ajoute une image à maintenir. Hors périmètre.

## Questions ouvertes

- Les modules natifs du serveur sont-ils tous N-API ? Si oui, accepter une majeure supérieure à `target` (par exemple Node 26 pour un VS Code sur 24) ?
- Quel gain réel sur la taille de l'image et sur la mémoire de l'injector au premier boot ?
- Faut-il, à terme, faire de la variante `external` l'éditeur par défaut sur le cluster weebo-si une fois les images de dev à jour ?
