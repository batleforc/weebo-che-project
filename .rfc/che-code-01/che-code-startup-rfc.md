# RFC — Accélérer le démarrage de che-code : copie conditionnelle dans l'init container

Oct 6, 2026 · @Maxime · Statut : Draft

## Résumé

À chaque démarrage d'un workspace VS Code, l'init container `che-code-injector` recopie tout le contenu de l'image che-code (trois assemblies : musl, ubi8, ubi9) dans le volume `checode`. Ce volume est persistant, donc la copie est refaite à l'identique à chaque boot.

Cette RFC rend la copie conditionnelle. L'image porte une clé de version (`<version VS Code>-<hash du contenu>`), le volume garde la clé de ce qu'il contient, et l'init container ne recopie les assemblies que si les deux diffèrent. Les fichiers que le launcher modifie en place à chaque boot, les entrypoints et les settings Machine restent copiés à chaque démarrage, ce qui garde le comportement actuel.

Le changement touche deux fichiers de `che-code` : `build/scripts/entrypoint-init-container.sh` et `build/dockerfiles/assembly.Dockerfile`, plus un test du launcher. Il est développé sur le fork `weebo-si/che-code`, intégré à notre `develop`, puis proposé upstream à `eclipse-che/che-code`.

C'est le premier axe d'un travail plus large, qui vise un second boot VS Code sous les 40 s (voir [Objectifs](#objectifs-et-non-objectifs)).

## Contexte et motivation

### Mesures actuelles

| IDE | Premier boot | Second boot |
|---|---|---|
| IntelliJ (JetBrains Gateway) | 3 min 18 s (dont 35 s de téléchargement de l'IDE, plus 30 s de téléchargement d'extensions avant le démarrage) | 37 s (sans le temps de connexion de Gateway) |
| VS Code (che-code) | 1 min 54 s | 1 min 36 s, image en cache ou non |

Le second boot VS Code ne profite presque pas du volume persistant. Le temps ne dépend pas du pull de l'image (1 min 36 s dans les deux cas).

À relever avant l'implémentation, pour fixer la base et la cible de cette RFC :

| Étape (second boot VS Code) | Durée |
|---|---|
| Pod `Scheduled` → init container démarré (attachement du PVC, etc.) | _à mesurer_ |
| Durée de l'init container `che-code-injector` | _à mesurer_ |
| Conteneur dev démarré → launcher terminé | _à mesurer_ |
| Launcher terminé → IDE affiché dans le navigateur | _à mesurer_ |

```sh
kubectl get pod <pod> -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{" "}{.state.terminated.startedAt}{" "}{.state.terminated.finishedAt}{"\n"}{end}'
kubectl get events --field-selector involvedObject.name=<pod>
```

### Ce que fait l'init container aujourd'hui

`build/scripts/entrypoint-init-container.sh` :

```sh
cp -r /checode-* /checode/          # les 3 assemblies, avec node et machine-exec
cp /entrypoint-volume.sh /checode/
mkdir -p /checode/remote
cp -r /remote /checode              # remote/data/Machine/settings.json
ls -la /checode
```

Le volume `checode` est déclaré `volume: {}` dans l'editor definition. Il n'est pas éphémère : avec les stratégies de stockage `per-user` et `per-workspace`, il vit sur un PVC (subpath par workspace) et persiste entre deux boots. Avec la stratégie `ephemeral`, c'est un `emptyDir`.

`entrypoint-volume.sh` n'utilise qu'une seule des trois assemblies, choisie selon la libc et la version d'OpenSSL du conteneur dev. Il exporte `VSCODE_AGENT_FOLDER=/checode/remote`, qui contient les données de l'utilisateur : settings User et Machine, extensions installées, globalStorage.

### Le précédent JetBrains

L'init container JetBrains (`che-incubator/jetbrains-ide-dev-server`, `build/scripts/entrypoint-init-container.sh`) écrit l'URL de téléchargement de l'IDE dans `.ide-download-complete` et saute le téléchargement quand elle n'a pas changé. C'est ce qui fait passer son second boot de 3 min 18 s à 37 s. Cette RFC applique le même principe à che-code.

### Le launcher modifie l'assembly en place

Le launcher (`launcher/src/`) tourne dans le répertoire de l'assembly choisie (par exemple `/checode/checode-linux-libc/ubi9/`) et modifie ces fichiers à chaque boot :

| Fichier | Modifié par | Méthode |
|---|---|---|
| `product.json` | `product-json.ts` (via `openvsix-registry`, `trusted-extensions`, `webview-resources`) | Réécriture du JSON |
| `out/vs/code/browser/workbench/workbench.js` | `devworkspace-id.ts`, `openvsix-registry.ts`, `local-storage-key-provider.ts`, `webview-resources.ts` | `content.replace(MASQUE, valeur)` |
| `out/vs/workbench/workbench.web.main.internal.js` | idem | idem |
| `out/vs/workbench/api/node/extensionHostProcess.js` | `webview-resources.ts` | idem |
| `<les trois .js>.gz` | `post-patch-compression.ts` | Générés après les patchs |

La liste des `.js` est centralisée dans `launcher/src/files.ts`.

Les patchs remplacent des **masques à usage unique** (`{{LOCAL-STORAGE}}/{{SECURE-KEY}}`, masque `DEVWORKSPACE_ID`, URL d'origine de la gallery, URL des webviews). Aujourd'hui, la copie complète remet des fichiers vierges à chaque boot. Si on sautait simplement la copie, le second boot ne trouverait plus les masques. Tout changement de configuration du cluster (URL OpenVSX, domaine des webviews, extensions de confiance, clé SSH) serait ignoré sans erreur jusqu'à la prochaine image. Les `.gz` de l'ancien boot seraient aussi servis à la place des fichiers à jour.

## Objectifs et non-objectifs

**Objectif global (au-delà de cette RFC)**

Passer sous **40 s** entre le clic du développeur sur l'IDE et l'affichage de l'IDE, au second boot VS Code (1 min 36 s aujourd'hui). C'est le niveau atteint par JetBrains (37 s).

Cette RFC est le premier axe. Les mesures détaillées de la section Contexte diront si elle suffit à atteindre la cible, ou combien il reste à gagner sur d'autres axes (launcher, serveur VS Code, chargement du workbench, attachement du PVC). Ces axes feront l'objet de RFC séparées.

**Objectifs de cette RFC**

1. Au second boot d'une même image, l'init container ne copie plus que quelques fichiers, pour une durée cible inférieure à **5 s**.
2. Comportement fonctionnel identique à aujourd'hui : configuration du launcher appliquée à chaque boot, settings Machine de l'image réappliqués à chaque boot, données utilisateur intactes.
3. Un changement d'image entraîne une copie complète et propre, sans fichier résiduel de l'ancienne version.
4. Un boot interrompu pendant la copie se répare tout seul au boot suivant.
5. Aucune régression avec la stratégie de stockage `ephemeral`.

**Non-objectifs**

- Ne copier que l'assembly utilisée par le conteneur dev. L'init container ne connaît pas la libc ni la version d'OpenSSL du conteneur dev. C'est un axe possible plus tard, via une variable d'environnement ou une détection déléguée à `entrypoint-volume.sh`.
- Patcher depuis des copies de référence dans le launcher (voir [Alternatives](#alternatives-considérées)).
- Rendre les settings Machine modifiables et persistants par l'utilisateur.
- Optimiser le launcher, le serveur VS Code ou le chargement du workbench.

## Conception

### Clé de version

L'image porte un fichier `/checode.version`. Le volume garde une copie `/checode/.checode.version` de la clé de son contenu.

- Format : `<version VS Code>-<sha256 du contenu>`, par exemple `1.128.1-3f9a2c0d71be…`. La version est lisible dans les logs, et le hash détecte n'importe quel changement, y compris dans le launcher, les extensions che-* ou `machine-exec`.
- La version vient du `package.json` de l'assembly (`1.128.1` aujourd'hui, la même que `code/package.json`). che-code n'a pas de version propre, et un sha git demanderait un `--build-arg` dans la CI, donc on n'en met pas.
- Le hash porte sur `checode-linux-musl` et `checode-linux-libc` dans leur état de l'image. Les fichiers patchés y sont vierges, et ils ne changent qu'avec l'image, donc les inclure ne pose pas de problème. Les entrypoints et `remote/` sont hors de `checode-*` et ne comptent pas dans le hash.
- Le fichier s'appelle `checode.version` et non `checode-version`, pour ne pas être pris par le glob `cp -r /checode-*`.

`build/dockerfiles/assembly.Dockerfile`, dans l'étage `ubi-builder`, après les `COPY` de `machine-exec` :

```dockerfile
# Version key of the assemblies, read by entrypoint-init-container.sh to skip the copy when unchanged
RUN cd /mnt/rootfs \
    && version=$(sed -n 's/^\s*"version": *"\([^"]*\)".*/\1/p' checode-linux-libc/ubi9/package.json | head -1) \
    && hash=$(find checode-linux-musl checode-linux-libc -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1) \
    && printf '%s-%s' "$version" "$hash" > checode.version
```

`find` et `sha256sum` tournent dans l'image `ubi8/ubi` du builder, pas dans l'image finale. À vérifier pendant l'implémentation : le chemin du `package.json` dans l'assembly, et le coût du hash au build (quelques secondes attendues).

### Init container

`build/scripts/entrypoint-init-container.sh` (l'en-tête EPL-2.0 Red Hat existant reste inchangé) :

```sh
set -e

# Files the launcher patches in place on every start: always restore them from the image.
# Keep in sync with launcher/src/files.ts and launcher/src/product-json.ts.
PATCHED_FILES="product.json
out/vs/code/browser/workbench/workbench.js
out/vs/workbench/workbench.web.main.internal.js
out/vs/workbench/api/node/extensionHostProcess.js"
ASSEMBLIES="checode-linux-musl checode-linux-libc/ubi8 checode-linux-libc/ubi9"

version=$(cat /checode.version)
if [ "$(cat /checode/.checode.version 2>/dev/null)" != "$version" ]; then
  echo "[INFO] Copying checode $version to the volume"
  # The marker goes first and comes back last: an interrupted copy is redone on the next start
  rm -f /checode/.checode.version
  rm -rf /checode/checode-*
  cp -r /checode-* /checode/
  printf '%s' "$version" > /checode/.checode.version
else
  echo "[INFO] checode $version already on the volume, restoring patched files"
  for assembly in $ASSEMBLIES; do
    for file in $PATCHED_FILES; do
      cp "/$assembly/$file" "/checode/$assembly/$file"
      rm -f "/checode/$assembly/$file.gz"
    done
  done
fi

# Copy entrypoint
cp /entrypoint-volume.sh /checode/
# Copy remote configuration (machine settings from the image win, as before)
mkdir -p /checode/remote/data/Machine
cp /remote/data/Machine/settings.json /checode/remote/data/Machine/

echo "listing all files copied"
ls -la /checode
```

Points de conception :

- **`/checode/remote` n'est jamais supprimé.** Seuls `checode-*` et le marqueur le sont, donc les settings et les extensions de l'utilisateur ne bougent pas, même lors d'un changement d'image.
- **`rm -rf` puis `cp`, sans `rsync --delete`.** `cp -r` n'efface pas les fichiers que la nouvelle version a supprimés, d'où le `rm -rf`. `rsync` serait plus rapide sur une petite mise à jour, mais ajouterait une dépendance à l'image.
- **`set -e`.** Une copie ratée (disque plein, permissions) fait échouer l'init container au lieu de poser le marqueur sur un volume incomplet. Aujourd'hui, une erreur de `cp` passe inaperçue.
- **`remote/`.** Seul `remote/data/Machine/settings.json` est copié, au lieu de `cp -r /remote /checode`. Le résultat est le même, puisque l'image ne contient que ce fichier dans `remote/`. Le launcher y fusionne ensuite la ConfigMap des settings, comme aujourd'hui.
- **Fichiers patchés.** Les quatre fichiers sont restaurés dans les trois assemblies, puisque l'init container ne sait pas laquelle sera utilisée. Leurs `.gz` sont supprimés pour que `post-patch-compression.ts` les régénère depuis les fichiers patchés.
- **Stratégie `ephemeral`.** Le volume est vide à chaque boot, le marqueur est absent, donc on copie tout, comme aujourd'hui.

### Synchronisation avec le launcher

La liste `PATCHED_FILES` duplique `launcher/src/files.ts`, plus `product.json`. Un fichier ajouté à `files.ts` et oublié dans le script ferait revenir le bug des masques consommés. Un test du launcher protège contre cet oubli :

`launcher/tests/init-container-patched-files.spec.ts` : lit `build/scripts/entrypoint-init-container.sh` et vérifie que chaque constante exportée par `files.ts`, ainsi que `product.json`, figure dans `PATCHED_FILES`.

## Stratégie de tests

**Automatisés**

- Le test de synchronisation `files.ts` ↔ `PATCHED_FILES` ci-dessus.
- Les tests existants du launcher restent verts (`yarn test` dans `launcher/`).

**Manuels, sur le cluster weebo-si, avec la stratégie `per-user`**

1. Second boot d'une même image : l'init container dure moins de 5 s, et ses logs affichent `already on the volume`.
2. Changement de configuration entre deux boots (par exemple `OPENVSX_REGISTRY_URL`, ou les extensions de confiance) : le changement est pris en compte au second boot.
3. Mise à jour de l'image entre deux boots : copie complète, aucun fichier de l'ancienne version dans `checode-*`, et les extensions et settings de l'utilisateur sont présents dans `/checode/remote`.
4. Pod supprimé pendant la copie (`kubectl delete pod` en pleine copie au premier boot) : le boot suivant refait une copie complète et le workspace démarre.
5. Stratégie `ephemeral` : le démarrage fonctionne comme avant.
6. Conteneur dev musl (Alpine) et ubi8 : l'IDE démarre, ce qui confirme que les fichiers patchés sont restaurés dans toutes les assemblies.

## Risques

- **Changement d'UID entre deux boots.** Si l'UID du pod change (namespace recréé, `securityContext` modifié), `rm` et `cp` sur des fichiers existants peuvent échouer. Avec `set -e`, l'init container échoue de façon visible au lieu de démarrer sur un contenu à moitié copié. Le problème existe déjà aujourd'hui avec `cp` sur des fichiers existants. À vérifier sur OpenShift et sur Kubernetes vanilla.
- **Volume partagé.** Le design suppose un volume `checode` propre à chaque workspace (subpath par workspace avec `per-user`). À confirmer dans DevWorkspace Operator. Si deux workspaces partageaient le même chemin, deux copies simultanées pourraient s'entremêler.
- **Fichier patché oublié.** Couvert par le test de synchronisation, à condition que les futurs patchs passent par `files.ts`.

## Plan de livraison

1. Créer le fork `weebo-si/che-code`. Il est déjà déclaré dans `forks.yaml`, avec `feat/init-copy-cache` mergée dans `develop`.
2. Relever les mesures manquantes de la section Contexte sur l'image actuelle.
3. Implémenter sur `feat/init-copy-cache` (Dockerfile, script, test), avec `Signed-off-by` sur chaque commit.
4. Construire l'image depuis `develop` poussée sur le fork public, déployer sur le cluster weebo-si, dérouler les tests manuels et remesurer le second boot complet par rapport à la cible de 40 s.
5. Ouvrir la PR upstream vers `eclipse-che/che-code` avec les mesures avant/après.
6. Une fois la PR mergée upstream, retirer `feat/init-copy-cache` de `develop.merge`.

## Licences

- `che-code` est sous EPL-2.0. Les fichiers modifiés gardent leur licence et leur en-tête Red Hat, sans ligne weebo-si ajoutée.
- Le nouveau test (`launcher/tests/init-container-patched-files.spec.ts`) reçoit exactement l'en-tête de licence attendu par le repo che-code.
- Aucune nouvelle dépendance : `find`, `sha256sum` et `sed` viennent de l'image builder existante.
- Une image che-code donnée à un client ou publiée doit être construite depuis un commit poussé sur le fork public `weebo-si/che-code` (EPL-2.0 §3.2). L'image embarque aussi VS Code (MIT) : ses notices restent dans l'image.
- La contribution upstream demande un ECA signé avec l'email de l'auteur des commits.

## Alternatives considérées

- **Clé = `commit` de `product.json` (commit VS Code).** Déjà présent dans l'image, mais il ne change pas quand seul le code che-code bouge (launcher, extensions che-*). Le volume garderait alors un contenu périmé. Rejeté.
- **Clé = digest de l'image passé par l'editor definition.** Exact, mais le conteneur ne connaît pas son propre digest. Il faudrait toucher `che-operator` et les editor definitions. Rejeté pour rester dans un seul repo.
- **Patcher depuis des copies de référence dans le launcher (`workbench.js.orig`).** Plus robuste à long terme, puisque plus aucune liste n'est à synchroniser. Mais il modifie six fichiers du launcher, le diff est plus gros à faire accepter upstream, et la restauration par l'init container donne le même résultat. Option à reconsidérer si la liste des fichiers patchés devient difficile à maintenir.
- **`rsync --delete`.** Copie incrémentale, mais nouvelle dépendance dans l'image de l'injector. Rejeté.

## Questions ouvertes

- Quelle est la durée réelle de l'init container aujourd'hui, et combien de temps reste-t-il après lui ? (Mesures de la section Contexte, à relever avant l'étape 3.)
- Le volume `checode` est-il bien propre à chaque workspace avec toutes les stratégies de stockage ?
- Quelle part du temps restant revient au launcher et au serveur VS Code ? Si cette RFC ne suffit pas à passer sous les 40 s, cette part orientera les prochaines RFC.
