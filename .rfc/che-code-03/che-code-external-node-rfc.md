# RFC — Exécuter che-code avec le Node.js de l'image de dev

Oct 13, 2026 · @Maxime · Statut : En cours d'implémentation (`weebo-si/che-code`, `feat/external-node`)

## Résumé

L'image che-code embarque un Node.js dans chacune de ses trois assemblies (musl, ubi8, ubi9), avec les bibliothèques partagées dont il dépend (`ld_libs/`). L'init container copie tout cela dans le volume `checode`, puis `entrypoint-volume.sh` lance le launcher et le serveur VS Code avec ce Node.

Cette RFC ajoute une option, la variable d'environnement `CHECODE_EXTERNAL_NODE=true` sur l'init container. Quand elle est posée, l'init container copie tout l'IDE sauf `node` et `ld_libs/`, et `entrypoint-volume.sh` utilise le Node de l'image de dev. Pas de repli sur un Node embarqué : si l'image de dev n'a pas de Node de la bonne majeure, le démarrage de l'IDE s'arrête avec un message clair.

Sans la variable, rien ne change. Il n'y a qu'une seule image : l'option se choisit dans l'editor definition.

Le changement s'appuie sur la clé de version de [che-code-01](../che-code-01/che-code-startup-rfc.md) et touche `build/scripts/entrypoint-init-container.sh`, `build/scripts/entrypoint-volume.sh` et `build/dockerfiles/assembly.Dockerfile` dans `weebo-si/che-code`. Le launcher ne change pas.

## Contexte et motivation

### Le Node embarqué pose des problèmes

- **ICU incomplet.** Le Node des assemblies UBI est construit avec `small-icu` sans le fichier de données `icudt*.dat` (paquet `nodejs-full-i18n` non installé). `Intl.Segmenter().segment()` y provoque un segfault de l'extension host, qui emporte toutes les extensions sans message d'erreur. Constaté avec `vscode-markdownlint` 0.61+ ([batlehub RFC 0034](https://github.com/batlehub/batlehub/blob/main/docs/rfc/0034-full-icu-node.md)). Le contournement actuel est un `NODE_ICU_DATA` dans le devfile.
- **Correctifs de sécurité.** Une CVE Node demande une nouvelle image che-code. Le Node de l'image de dev suit le cycle de mise à jour de cette image, que l'équipe qui la maintient contrôle.
- **Taille copiée.** L'init container copie trois Node et leurs bibliothèques à chaque premier boot et à chaque changement d'image (che-code-01).

### Ce qui existe déjà

`entrypoint-volume.sh` accepte déjà un Node externe par `VSCODE_NODEJS_RUNTIME_DIR`. Le launcher lance `${VSCODE_NODEJS_RUNTIME_DIR}/node out/server-main.js`, puis tout le serveur VS Code réutilise `process.execPath` (extension host, pty host, file watcher, askpass de git). Un seul point d'entrée décide donc du Node de tout l'IDE.

Ce mécanisme ne suffit pas :

- l'init container copie toujours les trois Node et `ld_libs/` ;
- `entrypoint-volume.sh` ajoute `ld_libs/` à `LD_LIBRARY_PATH` **même quand `VSCODE_NODEJS_RUNTIME_DIR` est fourni**. Un Node UBI de l'image de dev, lié dynamiquement à `libnode.so`, charge alors la `libnode.so` de che-code au lieu de la sienne ;
- rien ne vérifie que la version de Node fournie est compatible.

### Ce qui dépend de la version de Node

- Le code de VS Code cible la version de `code/remote/.npmrc` (`target="24.17.0"` aujourd'hui).
- Les modules natifs du serveur sont compilés pendant le build de chaque assembly. `node-pty`, `@parcel/watcher`, `@vscode/spdlog`, `@vscode/sqlite3` et `kerberos` utilisent N-API. `@vscode/native-watchdog` et `@vscode/deviceid` n'ont pas été vérifiés : la même majeure est donc exigée.
- Les assemblies restent nécessaires même sans Node : les modules natifs sont liés à musl ou à la glibc d'UBI 8 / UBI 9.

Exemple concret : ce workspace (`che-min-mise`) fournit Node 26 via mise. Il ne peut pas servir tel quel avec un che-code basé sur Node 24.

## Objectifs et non-objectifs

**Objectifs**

1. Avec `CHECODE_EXTERNAL_NODE=true`, ni `node` ni `ld_libs/` ne sont copiés dans le volume.
2. L'IDE (launcher, serveur, extension host, terminaux, git) tourne alors avec le Node de l'image de dev, et lui seul.
3. Échec explicite au démarrage si l'image de dev n'a pas de Node, ou pas la bonne majeure, avec un message qui dit quoi faire.
4. Sans la variable, aucun changement de comportement.

**Non-objectifs**

- Retirer Node de l'image che-code (le pull et le stockage de l'image ne changent pas).
- Activer l'option par défaut.
- Modifier le launcher ou le code de VS Code.

## Conception

### Init container : `entrypoint-init-container.sh`

- Avec `CHECODE_EXTERNAL_NODE=true`, la copie se fait assembly par assembly, entrée par entrée, en sautant `node` et `ld_libs` (le `cp` de coreutils n'a pas d'exclusion, et l'image n'a ni `find` ni `rsync`).
- La clé de version de che-code-01 reçoit le suffixe `-external-node`. Activer ou retirer l'option sur un volume existant refait donc une copie complète, dans les deux sens.
- Le fichier `/checode.node-version` de l'image est copié dans le volume (`/checode/.checode.node-version`) à chaque démarrage, comme `entrypoint-volume.sh`.

### Image : `assembly.Dockerfile`

Une ligne écrit `/checode.node-version` à partir du `target` de `code/remote/.npmrc`. Le build échoue si le fichier est vide.

### Démarrage : `entrypoint-volume.sh`

Le script ne lit pas la variable (elle est sur l'init container, pas sur le conteneur de dev). Il regarde si l'assembly choisie contient `node`. Si non :

- **Résolution du Node.** `VSCODE_NODEJS_RUNTIME_DIR` d'abord, sinon le `node` du `PATH`. Le `PATH` est celui de l'image (`ENV`), pas celui d'un shell interactif : un Node installé par `mise activate` dans `.bashrc` n'est pas vu.
- **Contrôle de la majeure.** Elle doit être celle de `.checode.node-version`. Une majeure différente est refusée, même plus récente.
- **Échec.** `exit 1` avec deux lignes `[ERROR]` dans `/checode/entrypoint-logs.txt`. L'IDE ne démarre pas, il n'y a pas de repli.
- **`LD_LIBRARY_PATH`.** Non modifié : le Node de l'image de dev et les terminaux voient exactement les bibliothèques de l'image.

**Shims mise / asdf / nvm.** Un shim choisit la version selon le répertoire courant. `VSCODE_NODEJS_RUNTIME_DIR` doit pointer vers un répertoire d'installation fixe (`.../installs/node/24/bin`), pas vers les shims.

### Activation

Dans l'editor definition, sur le composant `che-code-injector` :

```yaml
- name: che-code-injector
  container:
    env:
      - name: CHECODE_EXTERNAL_NODE
        value: 'true'
```

L'option vaut pour tous les workspaces qui utilisent cette editor definition. Elle est donc proposée dans une seconde editor definition, à côté de l'éditeur par défaut : `deploy/develop/che-code-external-node-editor.yaml` (`weebo-si/che-code/develop-external-node`).

Prérequis de l'image de dev :

- Node.js de la majeure de `code/remote/.npmrc` (24 aujourd'hui), compilé pour la même libc que l'image ;
- ICU complet recommandé (`nodejs-full-i18n` sur UBI, ou Node officiel de nodejs.org, qui l'inclut) ;
- `ENV VSCODE_NODEJS_RUNTIME_DIR=<répertoire bin de ce Node>` si ce Node n'est pas le premier du `PATH`.

### Montée de version de Node dans VS Code

Quand un rebase de che-code fait passer `target` à une nouvelle majeure (24 → 26), les workspaces dont l'image de dev n'a pas été mise à jour échouent au démarrage avec le message ci-dessus. C'est le prix du découplage. Mettre à jour les images de dev avant de publier l'image che-code.

## Stratégie de tests

**Fait** : les deux scripts exécutés hors conteneur sur de fausses assemblies. Copie par défaut, copie avec l'option (sans `node` ni `ld_libs`, fichiers cachés copiés), second démarrage sans recopie, retour à la copie complète, démarrage avec le Node du `PATH`, refus d'une autre majeure, refus sans Node, comportement par défaut inchangé.

**À faire, sur le cluster weebo-si**

1. Image de dev UBI 9 avec Node 24 et `nodejs-full-i18n` : l'IDE démarre, `ps` montre ce Node pour le serveur et l'extension host, `LD_LIBRARY_PATH` n'est pas modifié.
2. Même image : terminal (`node-pty`), recherche et file watcher, `git push` avec askpass, `vscode-markdownlint` ≥ 0.61 (le segfault ICU ne se produit pas).
3. Image de dev Alpine avec Node 24 : l'assembly musl est choisie et l'IDE démarre.
4. Image de dev sans Node, puis avec Node 26 seulement (`che-min-mise` actuelle) : message d'erreur dans `/checode/entrypoint-logs.txt`.
5. Même workspace, option activée puis retirée : copie complète à chaque changement, extensions et settings conservés.

**Mesures** : taille du volume et durée de `che-code-injector` au premier boot, avec et sans l'option.

## Risques

- **L'échec est peu visible.** `entrypoint-volume.sh` est lancé en arrière-plan par un `postStart` : le conteneur de dev reste en vie, le workspace n'ouvre simplement pas l'IDE. Le message est dans `/checode/entrypoint-logs.txt`.
- **Couplage des images de dev à la majeure de Node de VS Code.** Chaque montée de majeure casse les images non mises à jour.
- **Node de l'image de dev non standard.** Un Node compilé avec d'autres options (sans `inspector`, `small-icu` sans données) peut faire échouer des fonctions de VS Code sans erreur au démarrage. Le contrôle ne porte que sur la version.
- **Shims de gestionnaires de versions.** Le contrôle au démarrage ne couvre pas un shim qui changerait de version selon le projet ouvert.

## Plan de livraison

1. Branche `feat/external-node` sur `weebo-si/che-code`, basée sur `feat/init-copy-cache` (che-code-01), avec `Signed-off-by` sur chaque commit, puis ajout à `develop.merge`.
2. Construire une image de dev de test (UBI 9 + Node 24 full-i18n), activer l'option dans une editor definition, dérouler les tests et les mesures.
3. Mettre à jour les images de dev weebo-si (`che-min-mise` : Node 24 fixe et `VSCODE_NODEJS_RUNTIME_DIR`), puis retirer le contournement `NODE_ICU_DATA` des devfiles.
4. Upstream : à proposer après la PR de che-code-01, dont cette branche dépend.

## Licences

- `che-code` est sous EPL-2.0. Les trois fichiers modifiés gardent leur en-tête Red Hat, sans ligne weebo-si ajoutée.
- Aucune nouvelle dépendance. L'image distribuée ne change pas de contenu : Node.js et ses bibliothèques y restent, avec leurs notices.
- Les images de dev qui fournissent Node doivent garder sa licence et ses notices (Node officiel ou paquet de la distribution, qui les incluent).

## Alternatives considérées

- **Une variante de l'image sans Node (argument de build, second tag).** C'était la première version de cette RFC. Elle réduit aussi le pull et le stockage de l'image, mais demande un second assemblage dans `che-images`, un second tag et une seconde editor definition obligatoire. À reprendre si la taille de l'image devient le problème.
- **`VSCODE_NODEJS_RUNTIME_DIR` seul, sans option.** Fonctionne déjà, mais copie toujours trois Node, injecte la `libnode.so` de che-code dans le Node de l'image de dev et ne vérifie rien.
- **Repli sur le Node embarqué si l'image de dev n'en a pas.** Il faudrait le copier quand même, et un repli silencieux masquerait une image de dev mal configurée. Rejeté.

## Questions ouvertes

- `@vscode/native-watchdog` et `@vscode/deviceid` sont-ils N-API ? Si oui, accepter une majeure supérieure à `target` (Node 26 pour un VS Code sur 24) ?
- Quel gain réel sur la taille du volume et la durée du premier boot ?
- Faut-il faire remonter l'échec au dashboard (workspace en échec) plutôt que dans un fichier de log ?
