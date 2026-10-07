# RFC — Rendre les polices du conteneur dev utilisables dans VS Code (navigateur)

Oct 7, 2026 · @Maxime · Statut : En cours d'implémentation (`weebo-si/che-code`, `feat/container-fonts`)

## Résumé

Dans che-code, VS Code s'affiche dans le navigateur. Les réglages `editor.fontFamily` et `terminal.integrated.fontFamily` ne voient donc que les polices installées sur le poste du développeur, jamais celles de l'image du conteneur dev. Une image qui embarque une Nerd Font (prompt, icônes de `eza`, `starship`…) affiche des carrés dans le terminal tant que le développeur n'a pas installé la même police en local.

Cette RFC déclare au navigateur les polices du conteneur dev. Au démarrage, le launcher liste les polices avec `fc-list` et écrit `/checode/fonts.css`, une suite de `@font-face` dont les `src` pointent vers l'endpoint `/vscode-remote-resource` du serveur VS Code. `workbench.html` charge ce fichier. Le navigateur ne télécharge que les polices réellement utilisées.

Le changement touche `che-code` : un nouveau module du launcher (`launcher/src/fonts.ts`), `launcher/src/main.ts`, `code/src/vs/code/browser/workbench/workbench.html` et sa règle de rebase. Il est développé sur le fork `weebo-si/che-code` (branche `feat/container-fonts`), intégré à notre `develop`, puis proposé upstream à `che-incubator/che-code`.

## Contexte et motivation

### Le besoin

Notre image de dev (`WeeboDevImage`, utilisée par le devfile de ce repo) installe FiraCode Nerd Font dans `/usr/local/share/fonts` (19 fichiers, 46 Mo) en plus de DejaVu. Ces polices servent aux outils du terminal, mais le terminal de VS Code tourne dans le navigateur et ne peut pas les utiliser. Chaque développeur doit installer la police sur son poste, ce qui casse la promesse « tout est dans l'image ».

### Ce qui existe déjà dans che-code

- **Accès aux fichiers.** Le serveur VS Code expose `GET /vscode-remote-resource?path=<chemin absolu>` (`code/src/vs/server/node/remoteExtensionHostAgentServer.ts`). Il sert n'importe quel fichier lisible par l'utilisateur du conteneur, avec ETag. Le commentaire du code cite explicitement les polices. che-code lance le serveur avec `--without-connection-token` (`launcher/src/vscode-launcher.ts`) : l'authentification repose sur la passerelle Che, comme pour le reste de l'IDE.
- **CSP.** Le workbench est servi avec `font-src 'self' blob:` et `style-src 'self' 'unsafe-inline'` (`code/src/vs/server/node/webClientServer.ts`). `/vscode-remote-resource` est sur la même origine : aucune modification de CSP n'est nécessaire.
- **Chemins relatifs.** `workbench.html` référence déjà ses ressources en relatif (`./oss-dev/static/...`) pour fonctionner derrière le préfixe de chemin de la passerelle. Une feuille de style chargée par `./vscode-remote-resource?path=/checode/fonts.css` peut donc contenir des `url(vscode-remote-resource?path=...)` relatives, résolues contre la même base.
- **Le launcher tourne dans le conteneur dev.** `entrypoint-volume.sh` lance le launcher dans le conteneur dev, pas dans l'init container. Il voit donc le système de fichiers et le `fontconfig` de l'image de l'utilisateur.

Il ne manque que les déclarations `@font-face`.

## Objectifs et non-objectifs

**Objectifs**

1. Une police installée dans l'image du conteneur dev (dossiers `fontconfig` standard) est utilisable par son nom de famille dans `editor.fontFamily` et `terminal.integrated.fontFamily`, sans rien installer sur le poste.
2. Les variantes (gras, italique, graisses intermédiaires) sont déclarées avec la bonne `font-weight` et le bon `font-style`.
3. Aucun coût réseau pour les polices non utilisées, et un coût de démarrage négligeable (< 1 s pour le launcher).
4. Aucune régression quand l'image n'a pas de police ou pas de `fontconfig` : le workbench démarre comme aujourd'hui.

**Non-objectifs**

- Proposer les polices du conteneur dans l'autocomplétion des settings (elle passe par `queryLocalFonts()`, qui ne voit que le poste).
- Prendre en compte une police installée après le démarrage du workspace (il faut redémarrer le workspace).
- Formats non supportés par les navigateurs (`.pcf`, `.pfb`, Type 1) et collections `.ttc`.
- Convertir les polices en `woff2` pour réduire le transfert.
- Embarquer des polices dans l'image che-code elle-même.

## Conception

### Ce qui est généré au démarrage, ce qui est fixé au build

| Élément | Quand | Pourquoi |
|---|---|---|
| `/checode/fonts.css` (les `@font-face`) | À chaque démarrage, par le launcher | Les polices dépendent de l'image du conteneur dev, qui change d'un workspace à l'autre. L'image che-code ne la connaît pas au build. Le launcher tourne dans le conteneur dev et voit son `fontconfig` |
| `<link>` vers `fonts.css` dans `workbench.html` | Au build de l'image che-code | Il pointe toujours vers le même chemin. Le patcher au démarrage ajouterait un fichier à `PATCHED_FILES` (RFC che-code-01) et un masque à gérer, sans gain |

Chaîne au chargement : `workbench.html` (statique) → `fonts.css` (généré au boot) → fichiers de police de l'image, servis par `/vscode-remote-resource`.

Le seul code ajouté au runtime du navigateur serait la parade au risque de mesure des polices (voir [Risques](#risques)) : du code dans `code/src/vs/code/browser/workbench/che/` qui attend le chargement des familles configurées. Il n'est ajouté que si les tests montrent le problème, et ne modifie pas le HTML.

### Launcher : génération de `/checode/fonts.css`

Nouveau module `launcher/src/fonts.ts`, appelé dans `main.ts` avant `VSCodeLauncher.launch()`. Il ne patche aucun fichier de l'assembly : il écrit un fichier neuf à chaque boot.

1. Exécute `fc-list -f '%{family[0]}|%{style[0]}|%{weight}|%{slant}|%{file}\n'`.
2. Garde les fichiers `.ttf`, `.otf`, `.woff` et `.woff2`.
3. Écrit un `@font-face` par fichier dans `/checode/fonts.css` :

```css
@font-face {
  font-family: "FiraCode Nerd Font";
  src: url("vscode-remote-resource?path=%2Fusr%2Flocal%2Fshare%2Ffonts%2FFiraCodeNerdFont-Bold.ttf");
  font-weight: 700;
  font-style: normal;
  font-display: swap;
}
```

4. Si `fc-list` est absent ou échoue, écrit un fichier vide et logue `[INFO] fc-list not found, no container font declared`. Le démarrage continue dans tous les cas.

Conversion des valeurs `fontconfig` :

| `fontconfig` `weight` | CSS `font-weight` |
|---|---|
| 0 / 40 / 50 | 100 / 200 / 300 |
| 80 (regular) | 400 |
| 100 / 180 / 200 | 500 / 600 / 700 |
| 205 / 210 | 800 / 900 |
| autre | valeur la plus proche du tableau |

`slant` 0 donne `normal`, 100 (italic) et 110 (oblique) donnent `italic`.

Points de conception :

- **`fc-list` plutôt que lire les fichiers.** `fontconfig` donne le nom de famille, la graisse et le style déjà extraits des tables `name` et `OS/2`, et connaît les dossiers de l'image (`/usr/share/fonts`, `/usr/local/share/fonts`, `~/.local/share/fonts`). Une image qui installe des polices a presque toujours `fontconfig` (dépendance des paquets de polices, et nécessaire aux outils qui les utilisent). Sans lui, la fonctionnalité est simplement inactive.
- **`family[0]` seulement.** `fc-list` renvoie parfois plusieurs noms (`FiraCode Nerd Font Propo,FiraCode Nerd Font Propo Light`). Le premier est le nom de famille typographique, celui que l'utilisateur met dans ses settings.
- **Encodage du chemin.** Le chemin est passé par `encodeURIComponent`, et le nom de famille est échappé (`\` et `"`), pour qu'un nom de fichier exotique ne casse pas la feuille de style.
- **`font-display: swap`.** Le texte s'affiche tout de suite avec la police de repli, puis bascule.
- **Emplacement.** `/checode/fonts.css` est hors de `checode-*` : la copie conditionnelle de la RFC che-code-01 ne le touche pas, et il est régénéré à chaque boot, donc il suit toujours l'image du conteneur dev.

### Workbench : chargement de la feuille de style

`code/src/vs/code/browser/workbench/workbench.html`, après la ligne de `workbench.css` :

```html
<link rel="stylesheet" href="./vscode-remote-resource?path=/checode/fonts.css">
```

- Le `<link>` est dans le `<head>`, donc les `@font-face` sont déclarées avant le chargement du workbench.
- Si le fichier n'existe pas (launcher plus ancien), le serveur répond 404 et le navigateur ignore la feuille de style.
- La modification est ajoutée à la règle existante `.rebase/replace/code/src/vs/code/browser/workbench/workbench.html.json` (entrée de `workbench.css`), et `.rebase/CHANGELOG.md` est mis à jour, comme le demande le process de rebase de che-code.
- `workbench.html` n'est pas modifié par le launcher : rien à ajouter à `PATCHED_FILES` (RFC che-code-01).

## Stratégie de tests

**Automatisés (Jest, `launcher/tests/fonts.spec.ts`)**

- Une sortie `fc-list` simulée (regular, bold, italic, `.pcf.gz`, `.ttc`, famille multiple, nom avec guillemet) donne le CSS attendu.
- `fc-list` absent : fichier vide, aucune exception.

**Vérifié le 7 octobre 2026** (image `ghcr.io/weebo-si/che-code:sha-55a18ad`, devfile de ce repo, image `che-min-mise`) : `/checode/fonts.css` déclare 26 `@font-face`, soit FiraCode Nerd Font, FiraCode Nerd Font Mono et FiraCode Nerd Font Propo (6 fichiers chacune), plus DejaVu Sans, Sans Mono et Serif (8 fichiers, installés par `fonts-dejavu-core`). DejaVu est gardé : le navigateur ne télécharge que les polices affichées. Le launcher écrit le fichier environ 1 s avant que VS Code écoute.

**Manuels, sur le cluster weebo-si, avec `WeeboDevImage`**

1. `"terminal.integrated.fontFamily": "FiraCode Nerd Font"` sur un poste sans cette police : les glyphes Nerd Font s'affichent dans le terminal.
2. Même chose pour `editor.fontFamily`, avec les ligatures, en gras et en italique (thème qui utilise les deux).
3. Onglet réseau du navigateur : seuls les fichiers des graisses affichées sont téléchargés, et un rechargement renvoie des `304`.
4. Image sans `fontconfig` (par exemple `ubi9-minimal`) : le workspace démarre, `fonts.css` est vide, aucune erreur dans la console.
5. Conteneur dev musl (Alpine avec `font-noto`) : les polices sont déclarées.

## Risques

- **Mesure des polices par l'éditeur.** Monaco mesure la police au démarrage (`fontMeasurements.ts`) et ne remesure pas quand une police web finit de charger. Si la police arrive après la mesure, l'espacement et le curseur peuvent être décalés jusqu'au prochain changement de police ou de zoom. À vérifier au test 2. Si le problème se présente : dans `code/src/vs/code/browser/workbench/che/`, attendre `document.fonts.load()` des familles configurées avant de créer le workbench, ou appeler `FontMeasurements.clearAllFontInfos()` sur l'événement `loadingdone` de `document.fonts`.
- **Terminal.** xterm.js mesure aussi sa police à l'ouverture. Même vérification au test 1.
- **Durée de `fc-list`.** Rapide quand le cache `fontconfig` est construit dans l'image (`fc-cache` au build). Sans cache, `fc-list` rescanne les polices à chaque boot. À mesurer sur une image avec beaucoup de polices. Le launcher peut borner l'appel par un timeout de quelques secondes.
- **Type MIME des polices.** `/vscode-remote-resource` sert les `.ttf` en `text/plain`, sans `X-Content-Type-Options: nosniff`. Les navigateurs ne contrôlent pas le type MIME des polices, et `fonts.css` est bien servi en `text/css` (vérifié sur le serveur d'un workspace). À confirmer aux tests 1 et 2.
- **Exposition de fichiers.** Aucune nouvelle exposition : `/vscode-remote-resource` sert déjà tout fichier lisible, et `fonts.css` ne fait que lister des chemins de polices.

## Plan de livraison

1. Créer `feat/container-fonts` sur `weebo-si/che-code` et l'ajouter à `develop.merge` dans `forks.yaml`.
2. Implémenter le module, le test Jest, le `<link>` et la règle de rebase, avec `Signed-off-by` sur chaque commit.
3. Construire l'image depuis `develop` poussée sur le fork public, déployer sur le cluster weebo-si, dérouler les tests manuels.
4. Ouvrir la PR upstream vers `che-incubator/che-code`.
5. Une fois la PR mergée upstream, retirer `feat/container-fonts` de `develop.merge`.

## Licences

- `che-code` est sous EPL-2.0. `main.ts`, `workbench.html` et la règle de rebase gardent leur licence et leur en-tête. `workbench.html` vient de VS Code (MIT, en-tête Microsoft) : on ne touche pas à son en-tête.
- **En-tête de `fonts.ts` et `fonts.spec.ts`** : en-tête EPL-2.0 du launcher avec `Copyright (c) 2026 Contributors to the Eclipse Foundation` (décision du 2026-10-07, consignée dans le CLAUDE.md). Pas `Red Hat, Inc.`, qui n'a pas écrit ce code, ni de ligne weebo-si.
- Aucune nouvelle dépendance : `fc-list` vient de l'image du conteneur dev, si elle l'a.
- **Licences des polices.** Les polices ne sont pas redistribuées par che-code : elles restent dans l'image de l'utilisateur et sont servies à son propre navigateur. Pour nos images qui embarquent des polices (`WeeboDevImage`), leur licence doit autoriser la redistribution et l'usage web : FiraCode et Nerd Fonts (OFL-1.1, MIT) et DejaVu le permettent. Une police commerciale ajoutée plus tard devra être vérifiée.
- Une image che-code donnée à un client ou publiée doit être construite depuis un commit poussé sur le fork public `weebo-si/che-code` (EPL-2.0 §3.2).
- La contribution upstream demande un ECA signé avec l'email de l'auteur des commits.

## Alternatives considérées

- **Installer la police sur le poste.** La situation actuelle. Dépend de chaque développeur et de son OS. Rejeté.
- **Embarquer des polices dans l'image che-code.** Un seul jeu de polices pour tous les workspaces, choisi par nous et non par l'image de l'utilisateur, et du poids ajouté à l'image. Rejeté.
- **Lire les tables `name` et `OS/2` des fichiers dans le launcher.** Marche sans `fontconfig`, mais demande un parseur de fichiers de polices (ou une dépendance) pour un cas rare. À reconsidérer si des images sans `fontconfig` portent des polices.
- **Une extension VS Code qui injecte les `@font-face`.** Les extensions ne peuvent pas injecter de CSS dans le workbench. Rejeté.
- **Patcher `workbench.html` depuis le launcher.** Ajouterait un fichier à `PATCHED_FILES` (RFC che-code-01) sans gain : le `<link>` est statique.

## Questions ouvertes

- Faut-il une variable d'environnement pour désactiver la fonctionnalité (ou limiter les dossiers scannés), ou est-ce inutile tant que le coût mesuré reste négligeable ?
- Le problème de mesure de Monaco et de xterm.js se produit-il en pratique (tests 1 et 2) ?
