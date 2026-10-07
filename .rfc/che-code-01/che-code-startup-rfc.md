# RFC — Accélérer le démarrage de che-code : copie conditionnelle dans l'init container

Oct 6, 2026 · @Maxime · Statut : Draft

## Résumé

À chaque démarrage d'un workspace VS Code, l'init container `che-code-injector` recopie tout le contenu de l'image che-code (trois assemblies : musl, ubi8, ubi9) dans le volume `checode`. Ce volume est persistant, donc la copie est refaite à l'identique à chaque boot.

Cette RFC rend la copie conditionnelle. L'image porte une clé de version (`<version VS Code>-<hash du contenu>`), le volume garde la clé de ce qu'il contient, et l'init container ne recopie les assemblies que si les deux diffèrent. Les fichiers que le launcher modifie en place à chaque boot, les entrypoints et les settings Machine restent copiés à chaque démarrage, ce qui garde le comportement actuel.

Le changement touche deux fichiers de `che-code` : `build/scripts/entrypoint-init-container.sh` et `build/dockerfiles/assembly.Dockerfile`. Il est développé sur le fork `weebo-si/che-code`, intégré à notre `develop`, puis proposé upstream à `che-incubator/che-code`.

C'est le premier axe d'un travail plus large, qui vise un second boot VS Code sous les 40 s (voir [Objectifs](#objectifs-et-non-objectifs)).

## Contexte et motivation

### Mesures actuelles

| IDE | Premier boot | Second boot |
|---|---|---|
| IntelliJ (JetBrains Gateway) | 3 min 18 s (dont 35 s de téléchargement de l'IDE, plus 30 s de téléchargement d'extensions avant le démarrage) | 37 s (sans le temps de connexion de Gateway) |
| VS Code (che-code) | 1 min 54 s | 1 min 36 s, image en cache ou non |

Le second boot VS Code ne profite presque pas du volume persistant. Le temps ne dépend pas du pull de l'image (1 min 36 s dans les deux cas).

Les mesures détaillées par étape, avant et après cette RFC, sont dans la section [Mesures](#mesures). Au second boot, avec l'image upstream, l'init container prend 31 à 60 s selon sa limite mémoire, soit la majorité du temps de démarrage.

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

La liste `PATCHED_FILES` duplique `launcher/src/files.ts`, plus `product.json`. Un fichier ajouté à `files.ts` et oublié dans le script ferait revenir le bug des masques consommés. Un contrôle dans `assembly.Dockerfile` fait échouer le build dans ce cas : il lit les constantes `FILE_*` du `files.js` compilé du launcher et vérifie que chacune, ainsi que `product.json`, figure dans `PATCHED_FILES`. Il échoue aussi s'il ne trouve aucune constante, par exemple si le format de `files.js` change.

Ce contrôle ne peut pas être un test Jest du launcher : ces tests ne tournent que dans le build Docker de chaque plateforme, où `launcher/` est copié seul, sans `build/scripts/`. L'assembly est le seul endroit où le script et le launcher compilé sont présents ensemble.

## Stratégie de tests

**Automatisés**

- Le contrôle `files.ts` ↔ `PATCHED_FILES` au build de l'assembly, ci-dessus.
- Les tests existants du launcher restent verts (`npm test` dans `launcher/`).

**Manuels, sur le cluster weebo-si, avec la stratégie `per-user`**

1. Second boot d'une même image : l'init container dure moins de 5 s, et ses logs affichent `already on the volume`.
2. Changement de configuration entre deux boots (par exemple `OPENVSX_REGISTRY_URL`, ou les extensions de confiance) : le changement est pris en compte au second boot.
3. Mise à jour de l'image entre deux boots : copie complète, aucun fichier de l'ancienne version dans `checode-*`, et les extensions et settings de l'utilisateur sont présents dans `/checode/remote`.
4. Pod supprimé pendant la copie (`kubectl delete pod` en pleine copie au premier boot) : le boot suivant refait une copie complète et le workspace démarre.
5. Stratégie `ephemeral` : le démarrage fonctionne comme avant.
6. Conteneur dev musl (Alpine) et ubi8 : l'IDE démarre, ce qui confirme que les fichiers patchés sont restaurés dans toutes les assemblies.

## Mesures

Relevées le 7 octobre 2026 sur le cluster weebo-si (un seul nœud, stockage `per-workspace` sur `local-path`), avec `scripts/measure-che-code-boot.sh --fresh` et le `devfile.yaml` de ce repo (image `che-min-mise`, 5 projets à cloner). Chaque premier boot part d'un workspace neuf, créé comme le fait le dashboard. Le second boot est un arrêt puis un redémarrage du même workspace. Images déjà en cache sur le nœud (pulls < 0,5 s). Une seule mesure par combinaison.

- **Avant** : `quay.io/che-incubator/che-code:7.123.0` (upstream).
- **Après** : `ghcr.io/weebo-si/che-code:sha-55a18ad` (`develop` sur `7.123.x`, avec cette RFC et che-code-02).
- **Limite** : `memoryLimit` de `che-code-injector`. Les editor definitions upstream (che-operator 7.121.0 et 7.123.0) utilisent 256Mi.
- **VS Code écoute** : `curl http://127.0.0.1:3100/` répond 200 dans le pod. **URL** : `<mainUrl>healthz` répond 200 depuis l'extérieur (ingress, passerelle Che, passerelle du pod). Le chargement du workbench dans le navigateur n'est pas compté.

Durées en secondes depuis la création (premier boot) ou le redémarrage (second boot) du workspace :

| Image | Limite | Boot | `project-clone` | `che-code-injector` | VS Code écoute | URL accessible |
|---|---|---|---|---|---|---|
| Avant | 256Mi | premier | — | **OOMKilled** | échec | échec |
| Avant | 512Mi | premier | 159 | 28 | 202 | 202 |
| Avant | 512Mi | second | 0 | 38 | 48 | 48 |
| Avant | 1Gi | premier | 149 | 22 | 192 | 192 |
| Avant | 1Gi | second | 0 | 33 | 43 | 43 |
| Avant | 2Gi | premier | 160 | 24 | 205 | 222 |
| Avant | 2Gi | second | 0 | 31 | 40 | 40 |
| Après | 256Mi | premier | — | **OOMKilled** | échec | échec |
| Après | 512Mi | premier | 150 | 24 | 192 | 192 |
| Après | 512Mi | second | 0 | **0** | **10** | **10** |
| Après | 1Gi | premier | 151 | 25 | 193 | 193 |
| Après | 1Gi | second | 0 | **0** | **9** | **9** |
| Après | 2Gi | premier | 163 | 21 | 206 | 221 |
| Après | 2Gi | second | 0 | **0** | **9** | **9** |

`init-persistent-home` prend 0 s dans tous les cas.

Décomposition étape par étape à 1Gi (secondes ; la somme de chaque colonne donne le total) :

| Étape | Avant, premier | Avant, second | Après, premier | Après, second |
|---|---|---|---|---|
| Création ou démarrage du DevWorkspace → pod planifié (DevWorkspace Operator, création du PVC au premier boot) | 7 | 0 | 5 | 0 |
| Pod planifié → `project-clone` démarre (montage du volume) | 3 | 2 | 2 | 2 |
| `project-clone` | 149 | 0 | 151 | 0 |
| `init-persistent-home` et transitions entre init containers | 2 | 2 | 3 | 2 |
| `che-code-injector` | 22 | 33 | 25 | **0** |
| Fin des init containers → conteneurs démarrés | 5 | 2 | 2 | 3 |
| Conteneurs démarrés → VS Code écoute (launcher puis serveur VS Code) | 4 | 4 | 5 | 2 |
| VS Code écoute → URL accessible (routage) | 0 | 0 | 0 | 0 |
| **Total** | **192** | **43** | **193** | **9** |

Le démarrage de l'IDE proprement dit (conteneurs démarrés → VS Code écoute) prend 2 à 5 s, dont 1 à 3 s pour le launcher (patchs, `fonts.css`) et 1 à 2 s pour le serveur VS Code. Au second boot, `project-clone` constate en moins d'une seconde que les projets sont déjà clonés : il ouvre chaque dépôt et vérifie ses remotes, sans accès réseau. Il n'y a rien à gagner de ce côté.

### Temps de clone (hors du périmètre de cette RFC)

Le premier boot passe 150 s dans `project-clone`. Ce que fait DevWorkspace Operator v0.43 (`project-clone/internal`) :

- un `git clone` complet par projet, l'un après l'autre, sans `--depth` ni `--filter`, puis un `git fetch` par remote supplémentaire ;
- le clone se fait dans `/projects/project-clone-*` puis est déplacé par `os.Rename`, sans copie ;
- le conteneur est limité par défaut à **1 CPU** et 1Gi.

Les mêmes clones, faits le même jour depuis un pod du même nœud sans limite CPU (6,5 CPU) :

| Dépôt | Taille | Clone complet | `--filter=blob:none` | `--depth 1` |
|---|---|---|---|---|
| `weebo-si/che-code` | 688 Mo | 66 s | 30 s | 13 s |
| remote `batleforc/che-code` (fetch) | 686 Mo | 0 s (objets déjà là) | | |
| `che-incubator/jetbrains-ide-dev-server` | 170 Mo | 7 s | | 5 s |
| `weebo-si/che-dashboard` | 27 Mo | 3 s | | |
| `batleforc/eclipse-che-gateway-plugin`, `batleforc/weebo-che-project` | < 2 Mo | 1 s | | |

Soit environ 77 s sans limite CPU, contre 150 s dans `project-clone`. La limite de 1 CPU semble expliquer la moitié du temps : la résolution des deltas de `git` est gourmande en CPU. Le dépôt `che-code` représente à lui seul 85 % du temps de clone.

Pistes, à mesurer dans une RFC dédiée :

1. **Monter le CPU de `project-clone`** : `spec.devEnvironments.projectCloneContainer.resources.limits.cpu` dans le CheCluster (che-operator le reporte dans `devworkspace-config`). C'est un réglage du cluster, sans code. Gain estimé : jusqu'à la moitié du clone, non mesuré.
2. **Sortir les gros dépôts des `projects` du devfile** et les cloner en arrière-plan (commande `postStart`, `git clone --filter=blob:none`) : l'IDE est disponible en moins d'une minute au premier boot, le code arrive pendant que le développeur s'installe. En contrepartie, DevWorkspace Operator ne gère plus ces dépôts (remotes, `checkoutFrom`, reclonage au redémarrage).
3. **Clone partiel ou superficiel dans DevWorkspace Operator** : `project-clone` ne propose ni `--depth` ni `--filter` (seulement `sparseCheckout`, qui réduit les fichiers extraits mais pas l'historique téléchargé). Une option `depth` ou `filter` demanderait une contribution à `devfile/devworkspace-operator`.

Référence au même endroit, mesurée le même jour sur un workspace existant (`weebo-dev-setup`, volume déjà rempli) avec l'image en production `che-code:7.121.0` à 256Mi : `che-code-injector` 60 s, VS Code écoute à 73 s.

Constats :

- **Second boot : de 40-48 s à 9-10 s.** L'init container passe de 31-38 s à 0 s (ses logs affichent `already on the volume, restoring patched files`). La cible de 40 s est atteinte jusqu'au serveur VS Code, quelle que soit la limite mémoire au-delà de 256Mi.
- **Premier boot : inchangé, environ 3 min 15.** Il est dominé par le clone des projets (150-163 s, dont le repo `che-code`). La copie de l'injector prend 21-28 s, comme avant : cette RFC ne la ralentit pas.
- **256Mi : le premier boot échoue, avant comme après.** Voir [Risques](#risques).
- **La limite mémoire ralentit la copie.** Upstream, l'injector met 60 s à 256Mi (volume existant), 31-38 s à 512Mi et plus. Au-delà de 512Mi, aucun gain mesurable.
- **Écart URL / VS Code.** Dans les deux runs à 2Gi, l'URL n'a répondu que 15-17 s après VS Code, au moment où le DevWorkspace passe `Ready`. Dans les autres runs, les deux sont simultanés. Écart lié à la réconciliation de DevWorkspace Operator, pas à che-code.

### Reproduire les mesures

`scripts/measure-che-code-boot.sh` ne dépend pas de ce cluster. Prérequis :

- Linux avec les outils GNU (`date -d`, `sort -s`), `kubectl`, `jq`, `yq` (mikefarah v4) et `curl`. Le plus simple est de le lancer depuis un workspace Che.
- Un kubeconfig qui peut créer `devworkspaces` et `devworkspacetemplates`, faire `exec` et lire les logs et les events dans le namespace utilisateur.
- `curl` dans le premier conteneur du devfile (présent dans l'UDI et dans `che-min-mise`).
- L'URL des workspaces (`<mainUrl>healthz`) doit être joignable depuis l'endroit où le script tourne.
- Une editor definition dont l'image est accessible depuis ce cluster : `deploy/develop/che-code-editor.yaml` par défaut, ou un fichier `editors-definitions/*.yaml` de che-operator.
- `CHE_NAMESPACE` si Che n'est pas dans `eclipse-che`. `STORAGE_TYPE` si le compte ne peut pas lire le CheCluster, sinon le script prend `per-user`, ce qui ne correspond pas forcément à ce que fait le dashboard.

Matrice de ce document :

```sh
for image in ghcr.io/weebo-si/che-code:sha-55a18ad quay.io/che-incubator/che-code:7.123.0; do
  for mem in 256Mi 512Mi 1Gi 2Gi; do
    EDITOR_IMAGE=$image EDITOR_MEMORY=$mem TIMEOUT=900 \
      scripts/measure-che-code-boot.sh --fresh <namespace> devfile.yaml > "boot-${image##*:}-$mem.log" 2>&1
    grep RESULT "boot-${image##*:}-$mem.log"
  done
done
```

Chaque run crée puis supprime son propre workspace. Les mesures sont séquentielles : lancées en parallèle sur un même nœud, elles se ralentiraient entre elles.

## Risques

- **OOM de l'injector au premier boot avec la limite upstream de 256Mi.** Sur ce cluster, la copie des 2,7 Go des trois assemblies dans un volume vide est tuée (`OOMKilled`) à 256Mi avec `che-code:7.123.0`, `che-code:next` et nos images, mais pas avec `che-code:7.121.0`, présente sur le nœud depuis des semaines. Le contenu (taille, nombre de fichiers), le script et `cp` sont les mêmes. La mémoire consommée est du cache de pages (fichiers lus et écrits), pas de la mémoire de processus. Hypothèse, non prouvée faute d'un second nœud : le cache des fichiers d'une image déjà lue est compté dans un autre cgroup. Ce problème est upstream et indépendant de cette RFC, mais il bloquera la création de workspaces VS Code au passage à Che 7.123. Mitigation : 512Mi suffisent dans nos mesures, 1Gi laisse de la marge. Copier une seule assembly (non-objectif ci-dessus) diviserait aussi la quantité copiée par trois. À reproduire sur un cluster à plusieurs nœuds, puis à remonter à `che-incubator/che-code`.
- **Changement d'UID entre deux boots.** Si l'UID du pod change (namespace recréé, `securityContext` modifié), `rm` et `cp` sur des fichiers existants peuvent échouer. Avec `set -e`, l'init container échoue de façon visible au lieu de démarrer sur un contenu à moitié copié. Le problème existe déjà aujourd'hui avec `cp` sur des fichiers existants. À vérifier sur OpenShift et sur Kubernetes vanilla.
- **Volume partagé.** Le design suppose un volume `checode` propre à chaque workspace (subpath par workspace avec `per-user`). À confirmer dans DevWorkspace Operator. Si deux workspaces partageaient le même chemin, deux copies simultanées pourraient s'entremêler.
- **Fichier patché oublié.** Couvert par le contrôle au build de l'assembly, à condition que les futurs patchs passent par `files.ts`.

## Plan de livraison

1. Créer le fork `weebo-si/che-code`. Il est déjà déclaré dans `forks.yaml`, avec `feat/init-copy-cache` mergée dans `develop`.
2. ~~Relever les mesures manquantes de la section Contexte sur l'image actuelle.~~ Fait, voir [Mesures](#mesures).
3. Implémenter sur `feat/init-copy-cache` (Dockerfile, script, test), avec `Signed-off-by` sur chaque commit.
4. Construire l'image depuis `develop` poussée sur le fork public, déployer sur le cluster weebo-si, dérouler les tests manuels et remesurer le second boot complet par rapport à la cible de 40 s.
5. Ouvrir la PR upstream vers `che-incubator/che-code` avec les mesures avant/après.
6. Une fois la PR mergée upstream, retirer `feat/init-copy-cache` de `develop.merge`.

## Licences

- `che-code` est sous EPL-2.0. Les fichiers modifiés gardent leur licence et leur en-tête Red Hat, sans ligne weebo-si ajoutée.
- Aucune nouvelle dépendance : `find`, `sha256sum` et `sed` viennent de l'image builder existante.
- Une image che-code donnée à un client ou publiée doit être construite depuis un commit poussé sur le fork public `weebo-si/che-code` (EPL-2.0 §3.2). L'image embarque aussi VS Code (MIT) : ses notices restent dans l'image.
- La contribution upstream demande un ECA signé avec l'email de l'auteur des commits.

## Alternatives considérées

- **Clé = `commit` de `product.json` (commit VS Code).** Déjà présent dans l'image, mais il ne change pas quand seul le code che-code bouge (launcher, extensions che-*). Le volume garderait alors un contenu périmé. Rejeté.
- **Clé = digest de l'image passé par l'editor definition.** Exact, mais le conteneur ne connaît pas son propre digest. Il faudrait toucher `che-operator` et les editor definitions. Rejeté pour rester dans un seul repo.
- **Patcher depuis des copies de référence dans le launcher (`workbench.js.orig`).** Plus robuste à long terme, puisque plus aucune liste n'est à synchroniser. Mais il modifie six fichiers du launcher, le diff est plus gros à faire accepter upstream, et la restauration par l'init container donne le même résultat. Option à reconsidérer si la liste des fichiers patchés devient difficile à maintenir.
- **`rsync --delete`.** Copie incrémentale, mais nouvelle dépendance dans l'image de l'injector. Rejeté.

## Questions ouvertes

- Le volume `checode` est-il bien propre à chaque workspace avec toutes les stratégies de stockage ?
- Combien de temps prend le chargement du workbench dans le navigateur après le 200 de l'URL ? C'est la seule étape du second boot que le script ne mesure pas.
- L'OOM à 256Mi se reproduit-il sur un nœud neuf avec `che-code:7.121.0` (voir [Risques](#risques)) ?
