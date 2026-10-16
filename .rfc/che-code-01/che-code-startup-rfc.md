# RFC — Accélérer le démarrage de che-code : copie conditionnelle dans l'init container

Oct 6, 2026 · @Maxime · Statut : Implémentée (`weebo-si/che-code`, `develop`), révisée après review le 16 oct. 2026 (restauration déplacée dans le launcher, implémentée dans `a0ee3d3`, tests manuels 1, 2 et 6 à refaire), PR upstream ouverte

## Résumé

À chaque démarrage d'un workspace VS Code, l'init container `che-code-injector` recopie tout le contenu de l'image che-code (trois assemblies : musl, ubi8, ubi9) dans le volume `checode`. Ce volume est persistant, donc la copie est refaite à l'identique à chaque boot.

Cette RFC rend la copie conditionnelle. L'image porte une clé de version (`<version VS Code>-<hash du contenu>`), le volume garde la clé de ce qu'il contient, et l'init container ne recopie les assemblies que si les deux diffèrent. Le launcher restaure les fichiers qu'il patche depuis une copie vierge qu'il garde à côté (`<fichier>.orig`), donc l'init container n'a plus besoin de les connaître. Les entrypoints et les settings Machine restent copiés à chaque démarrage, ce qui garde le comportement actuel.

Le changement touche `build/scripts/entrypoint-init-container.sh`, `build/dockerfiles/assembly.Dockerfile` et les patchers du launcher (`launcher/src/`) dans `che-code`. Il est développé sur le fork `weebo-si/che-code`, intégré à notre `develop`, puis proposé upstream à `che-incubator/che-code`.

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
| `product.json` | `product-json.ts` (via `openvsix-registry`, `trusted-extensions`, `webview-resources`, `editor-configurations`) | Réécriture du JSON |
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

version=$(cat /checode.version)
if [ "$(cat /checode/.checode.version 2>/dev/null)" != "$version" ]; then
  echo "[INFO] Copying checode $version to the volume"
  # The marker goes first and comes back last: an interrupted copy is redone on the next start
  rm -f /checode/.checode.version
  rm -rf /checode/checode-*
  cp -r /checode-* /checode/
  printf '%s' "$version" > /checode/.checode.version
else
  echo "[INFO] checode $version already on the volume"
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
- **Fichiers patchés.** L'init container ne les restaure plus, c'est le launcher qui le fait (section suivante). Au second boot, il ne copie plus que l'entrypoint et les settings Machine.
- **Stratégie `ephemeral`.** Le volume est vide à chaque boot, le marqueur est absent, donc on copie tout, comme aujourd'hui.

### Restauration des fichiers patchés dans le launcher

Révisé le 16 oct. 2026 après review de la PR upstream (@RomanNikitenko, @batleforc). La première version restaurait les fichiers patchés depuis l'init container, avec une liste `PATCHED_FILES` synchronisée avec le launcher par un contrôle au build de l'assembly. Cette liste dupliquait une connaissance qui appartient au launcher, et rien dans le launcher n'y renvoyait. Le contrôle ne voyait que les constantes `export const FILE_*` de `files.ts` : un chemin littéral, une constante définie ailleurs ou formatée autrement, ou un nouveau fichier comme `product.json` passait à travers. Un fichier oublié échoue en silence : le premier démarrage marche, les suivants gardent l'ancienne valeur parce que le masque a disparu, et ça ne se voit que quand cette valeur change entre deux démarrages.

La restauration passe dans le launcher, là où le patch a lieu. Chaque patcher lit le fichier qu'il patche via un seul helper :

```ts
// launcher/src/fs-extra.ts
const restored = new Set<string>();

/**
 * Reads a file of the assembly that the launcher patches in place.
 * The assembly persists between starts, so the first read in this process restores the file
 * from `<file>.orig` (created on first use): every start patches the content of the image.
 * Later reads in the same process return the file with the previous patchers' changes.
 */
export async function readPatchable(file: string): Promise<string> {
  if (!restored.has(file)) {
    const orig = `${file}.orig`;
    if (fs.existsSync(orig)) {
      fs.copyFileSync(orig, file);
    } else {
      // Copy then rename: a start killed mid-copy must not leave a truncated .orig behind
      fs.copyFileSync(file, `${orig}.tmp`);
      fs.renameSync(`${orig}.tmp`, orig);
    }
    restored.add(file);
  }
  return readFile(file);
}
```

- **Restaurer à la première lecture seulement.** La review proposait un `readPristine` qui renvoie toujours le `.orig`. Or les patchers s'enchaînent sur les mêmes fichiers : `workbench.js` et `workbench.web.main.internal.js` passent par `devworkspace-id`, `openvsix-registry`, `webview-resources` et `local-storage-key-provider` ; `product.json` par `openvsix-registry`, `webview-resources`, `trusted-extensions` et `editor-configurations`. Toujours lire le `.orig` ferait que chaque patcher défait le précédent. Le helper restaure le fichier à sa première lecture dans le processus, et les patchers suivants lisent le fichier courant.
- **Patchers à modifier.** `devworkspace-id.ts`, `openvsix-registry.ts`, `webview-resources.ts`, `local-storage-key-provider.ts` (`update` seulement, pas la lecture de la clé publique) et `ProductJSON.load()` dans `product-json.ts`. Leurs specs mockent `fs-extra` et doivent aussi mocker `readPatchable`.
- **Les `.orig` correspondent toujours à l'image.** Un changement de version efface `checode-*`, `.orig` compris. Seule l'assembly réellement utilisée en reçoit.
- **Fichiers `.gz`.** L'init container ne les supprime plus. `post-patch-compression.ts` les réécrit à chaque démarrage, mais en cas d'échec il laisse le `.gz` précédent, que le serveur servirait avec les valeurs du démarrage précédent. Son `catch` doit aussi supprimer le `.gz`, comme le faisait l'init container.
- **Redémarrage du launcher.** Un nouveau processus launcher dans le même conteneur part d'un ensemble vide et restaure les fichiers depuis `.orig`, comme un nouveau démarrage.
- **Plus rien à synchroniser.** `PATCHED_FILES`, la boucle de restauration et le contrôle de `assembly.Dockerfile` disparaissent. Un nouveau patcher est correct par défaut tant qu'il lit via `readPatchable`. Un build downstream (Dev Spaces) qui ajoute ses propres patchers n'a plus à toucher l'init container.

## Stratégie de tests

**Automatisés**

- Tests de `readPatchable` (nouveau `launcher/tests/fs-extra.spec.ts`, sur un répertoire temporaire) : la première lecture crée `.orig` ; deux patchers dans le même processus s'appliquent tous les deux ; un nouveau processus (`jest.isolateModules`) retrouve le masque et applique une nouvelle valeur ; un `.orig.tmp` résiduel est ignoré.
- Test garde-fou : seuls `fs-extra.ts` et `post-patch-compression.ts` importent `fs`, et chaque appel `fs.readFile(` de `launcher/src/` figure dans une liste de lectures autorisées hors de l'assembly (devfile, fichier workspace, settings, certificats, clé publique). Un nouveau patcher qui lit avec `fs.readFile` le fait échouer, et son auteur doit choisir entre les deux helpers.
- Les tests existants du launcher restent verts (`npm test` dans `launcher/`).

**Manuels, sur le cluster weebo-si, avec la stratégie `per-user`**

1. Second boot d'une même image : l'init container dure moins de 5 s, et ses logs affichent `already on the volume`.
2. Changement de configuration entre deux boots (par exemple `OPENVSX_REGISTRY_URL`, ou les extensions de confiance) : le changement est pris en compte au second boot.
3. Mise à jour de l'image entre deux boots : copie complète, aucun fichier de l'ancienne version dans `checode-*`, et les extensions et settings de l'utilisateur sont présents dans `/checode/remote`.
4. Pod supprimé pendant la copie (`kubectl delete pod` en pleine copie au premier boot) : le boot suivant refait une copie complète et le workspace démarre.
5. Stratégie `ephemeral` : le démarrage fonctionne comme avant.
6. Conteneur dev musl (Alpine) et ubi8 : l'IDE démarre, et les fichiers `.orig` n'existent que dans l'assembly utilisée.

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

### Mise à jour de l'IDE

Relevées le 14 octobre 2026, même cluster et même devfile, limite 1Gi, avec `UPDATE_IMAGE` (voir plus bas) : premier boot, second boot, puis le workspace est arrêté, l'image de `che-code-injector` de son DevWorkspaceTemplate est remplacée, et il est redémarré sur le volume rempli par l'image précédente. C'est ce que vivent les workspaces existants quand Che passe à une nouvelle release de che-code. Images en cache sur le nœud (pulls < 1 s), le pull d'une nouvelle release n'est donc pas compté. Une seule mesure par scénario.

- **Avant** : `quay.io/che-incubator/che-code:7.121.0` → `7.123.0` (upstream).
- **Après** : `ghcr.io/weebo-si/che-code:sha-55a18ad` → `sha-725f14b` (deux builds de `develop` avec des clés de version différentes).

| Scénario | Boot | `project-clone` | `che-code-injector` | VS Code écoute | URL joignable |
|---|---|---|---|---|---|
| Avant | premier | 157 | 68 | 248 | 248 |
| Avant | second | 1 | 93 | 104 | 104 |
| Avant | mise à jour | 1 | 88 | 98 | 98 |
| Après | premier | 157 | 40 | 216 | 240 |
| Après | second | 0 | **0** | **9** | **10** |
| Après | mise à jour | 0 | 64 | 77 | 77 |

Constats :

- **La mise à jour est le boot coûteux de cette RFC.** Les logs de l'injector affichent `Copying checode <nouvelle clé>` : la clé a changé, la copie complète est refaite, comme prévu (objectif 3). Elle coûte à peu près un boot upstream (77 s contre 98-104 s), une fois par workspace et par release.
- **La copie de mise à jour est plus lente que la première copie (64 s contre 40 s).** Elle supprime d'abord les 2,7 Go de la version précédente (`rm -rf /checode/checode-*`), puis copie dans un volume non vide. Piste, non mesurée : renommer les anciens répertoires et les supprimer après la copie, ou ne copier que l'assembly utilisée (non-objectif plus haut).
- **Le cluster était plus lent que le 7 octobre.** L'injector upstream a pris 88-93 s à 1Gi, contre 31-38 s une semaine plus tôt. Comparer les scénarios du même jour entre eux, pas avec le tableau principal.
- Une première tentative du scénario « après » a échoué : `sha-55a18ad` n'était plus sur le nœud, son pull (79 s) plus le clone ont dépassé le timeout de progression de 300 s de DevWorkspace Operator. La seconde tentative, image en cache, est celle ci-dessus.

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

Scénarios de mise à jour (`UPDATE_IMAGE` ajoute un troisième boot sur la nouvelle image) :

```sh
EDITOR_IMAGE=quay.io/che-incubator/che-code:7.121.0 UPDATE_IMAGE=quay.io/che-incubator/che-code:7.123.0 \
  EDITOR_MEMORY=1Gi TIMEOUT=900 scripts/measure-che-code-boot.sh --fresh <namespace> devfile.yaml
EDITOR_IMAGE=ghcr.io/weebo-si/che-code:sha-55a18ad UPDATE_IMAGE=ghcr.io/weebo-si/che-code:sha-725f14b \
  EDITOR_MEMORY=1Gi TIMEOUT=900 scripts/measure-che-code-boot.sh --fresh <namespace> devfile.yaml
```

Chaque run crée puis supprime son propre workspace. Les mesures sont séquentielles : lancées en parallèle sur un même nœud, elles se ralentiraient entre elles.

## Risques

- **OOM de l'injector au premier boot avec la limite upstream de 256Mi.** Sur ce cluster, la copie des 2,7 Go des trois assemblies dans un volume vide est tuée (`OOMKilled`) à 256Mi avec `che-code:7.123.0`, `che-code:next` et nos images, mais pas avec `che-code:7.121.0`, présente sur le nœud depuis des semaines. Le contenu (taille, nombre de fichiers), le script et `cp` sont les mêmes. La mémoire consommée est du cache de pages (fichiers lus et écrits), pas de la mémoire de processus. Hypothèse, non prouvée faute d'un second nœud : le cache des fichiers d'une image déjà lue est compté dans un autre cgroup. Ce problème est upstream et indépendant de cette RFC, mais il bloquera la création de workspaces VS Code au passage à Che 7.123. Mitigation : 512Mi suffisent dans nos mesures, 1Gi laisse de la marge. Copier une seule assembly (non-objectif ci-dessus) diviserait aussi la quantité copiée par trois. À reproduire sur un cluster à plusieurs nœuds, puis à remonter à `che-incubator/che-code`.
- **Changement d'UID entre deux boots.** Si l'UID du pod change (namespace recréé, `securityContext` modifié), `rm` et `cp` sur des fichiers existants peuvent échouer. Avec `set -e`, l'init container échoue de façon visible au lieu de démarrer sur un contenu à moitié copié. Le problème existe déjà aujourd'hui avec `cp` sur des fichiers existants. À vérifier sur OpenShift et sur Kubernetes vanilla.
- **Volume partagé.** Le design suppose un volume `checode` propre à chaque workspace (subpath par workspace avec `per-user`). À confirmer dans DevWorkspace Operator. Si deux workspaces partageaient le même chemin, deux copies simultanées pourraient s'entremêler.
- **Patcher qui contourne `readPatchable`.** Fait revenir le bug silencieux pour ce fichier. Couvert par le test garde-fou, tant qu'il passe par `fs-extra`. Un patcher hors de `launcher/src/` ne serait pas couvert.

## Plan de livraison

1. Créer le fork `weebo-si/che-code`. Il est déjà déclaré dans `forks.yaml`, avec `feat/init-copy-cache` mergée dans `develop`.
2. ~~Relever les mesures manquantes de la section Contexte sur l'image actuelle.~~ Fait, voir [Mesures](#mesures).
3. Implémenter sur `feat/init-copy-cache` (Dockerfile, script, test), avec `Signed-off-by` sur chaque commit.
4. Réviser après review : ajouter `readPatchable` et ses tests, y passer les cinq patchers, supprimer le `.gz` périmé quand la compression échoue, retirer `PATCHED_FILES`, la boucle de restauration et le contrôle de `assembly.Dockerfile`. Refaire les tests manuels 1, 2 et 6.
5. Construire l'image depuis `develop` poussée sur le fork public, déployer sur le cluster weebo-si, dérouler les tests manuels et remesurer le second boot complet par rapport à la cible de 40 s.
6. Ouvrir la PR upstream vers `che-incubator/che-code` avec les mesures avant/après.
7. Une fois la PR mergée upstream, retirer `feat/init-copy-cache` de `develop.merge`.

## Licences

- `che-code` est sous EPL-2.0. Les fichiers modifiés gardent leur licence et leur en-tête Red Hat, sans ligne weebo-si ajoutée.
- Le nouveau `launcher/tests/fs-extra.spec.ts` reçoit l'en-tête du launcher avec `Copyright (c) 2026 Contributors to the Eclipse Foundation` (che-code n'a pas de vérificateur d'en-tête, décidé le 2026-10-07).
- Aucune nouvelle dépendance : `find`, `sha256sum` et `sed` viennent de l'image builder existante.
- Une image che-code donnée à un client ou publiée doit être construite depuis un commit poussé sur le fork public `weebo-si/che-code` (EPL-2.0 §3.2). L'image embarque aussi VS Code (MIT) : ses notices restent dans l'image.
- La contribution upstream demande un ECA signé avec l'email de l'auteur des commits.

## Alternatives considérées

- **Clé = `commit` de `product.json` (commit VS Code).** Déjà présent dans l'image, mais il ne change pas quand seul le code che-code bouge (launcher, extensions che-*). Le volume garderait alors un contenu périmé. Rejeté.
- **Clé = digest de l'image passé par l'editor definition.** Exact, mais le conteneur ne connaît pas son propre digest. Il faudrait toucher `che-operator` et les editor definitions. Rejeté pour rester dans un seul repo.
- **Restaurer depuis l'init container avec une liste `PATCHED_FILES` (première version de cette RFC).** Diff plus petit, tout dans l'init container. Mais la liste duplique le launcher, le contrôle au build ne voit que les constantes `FILE_*` de `files.ts`, et un fichier oublié échoue en silence, seulement quand une valeur change entre deux démarrages. Remplacé après review.
- **Restaurer tous les fichiers patchés au début de `Main.start()`.** Un appel au lieu d'un helper, mais ça ramène une liste de fichiers à maintenir. Rejeté.
- **`rsync --delete`.** Copie incrémentale, mais nouvelle dépendance dans l'image de l'injector. Rejeté.

## Questions ouvertes

- Le volume `checode` est-il bien propre à chaque workspace avec toutes les stratégies de stockage ?
- Combien de temps prend le chargement du workbench dans le navigateur après le 200 de l'URL ? C'est la seule étape du second boot que le script ne mesure pas.
- L'OOM à 256Mi se reproduit-il sur un nœud neuf avec `che-code:7.121.0` (voir [Risques](#risques)) ?
