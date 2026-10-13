# RFC — Page d'accueil développeur dans les IDE du workspace (VS Code et JetBrains)

Oct 13, 2026 · @Maxime · Statut : Draft

## Résumé

À l'ouverture d'un workspace, le développeur n'a aucune information sur l'environnement : les outils de l'image, les commandes du devfile, les URL utiles ou le support. Cette RFC propose d'afficher au premier démarrage une page d'accueil écrite en Markdown. Le même fichier sert dans VS Code (che-code) et dans les IDE JetBrains (Gateway).

L'approche se fait par paliers, et on s'arrête au premier qui suffit :

1. **Sans extension** : un `WELCOME.md` dans le repo, et le réglage `workbench.startupEditor` de VS Code.
2. **Extension VS Code minimale** : elle ouvre le fichier dans la preview Markdown intégrée au premier démarrage du workspace.
3. **Plugin JetBrains minimal** : un `ProjectActivity` côté backend ouvre le même fichier.

Pas de webview ni de rendu HTML maison : on réutilise le rendu Markdown de chaque IDE.

## Contexte et motivation

### Le besoin

- Onboarding : un nouveau développeur ouvre le workspace et doit savoir quoi lancer, où trouver la doc et qui contacter.
- Offre de support : la page est l'endroit naturel pour afficher le contact support et la version de l'environnement.
- Point de départ pour l'item du todo « extension qui fournirait une Home Page customisable ».

### Ce qui existe déjà

- **VS Code** : `workbench.startupEditor: "readme"` ouvre le README du dossier quand aucun éditeur n'est ouvert. La preview Markdown est intégrée (commande `markdown.showPreview`). Les walkthroughs (`contributes.walkthroughs`) sont déclaratifs, mais ils s'affichent dans la page Welcome de VS Code, pas en page dédiée.
- **che-code** : `DEFAULT_EXTENSIONS` (liste de chemins `.vsix` séparés par `;`) installe des extensions au démarrage (`code/src/vs/server/node/che/defaultExtensionsInstaller.ts`). On peut le bloquer avec la policy `BlockDefaultExtensionsInstallation`.
- **JetBrains** : le plugin Markdown est intégré. `FileEditorManager.openFile` ouvre un `.md` avec l'éditeur et la preview. En remote dev, les plugins du projet tournent sur le **backend**, dans le conteneur du workspace, et non dans le client Gateway.

## Objectifs et non-objectifs

**Objectifs**

1. Une seule source de contenu (Markdown) pour VS Code et JetBrains.
2. Le contenu est versionné avec le projet et modifiable sans rebuild d'image ni d'extension.
3. La page s'ouvre au premier démarrage du workspace, puis reste disponible via une commande ou une action.
4. Aucun effet si le fichier est absent : l'IDE démarre comme aujourd'hui.

**Non-objectifs**

- Contenu dynamique (état du workspace, quotas, liens générés), à envisager dans une RFC suivante.
- Remplacer la page Welcome native de VS Code ou l'écran d'accueil de JetBrains.
- Personnalisation par utilisateur ou par organisation depuis le dashboard.
- Télémétrie (savoir si la page a été lue).

## Conception

### Le contenu : `WELCOME.md`

- Emplacement par défaut : `.devfile/WELCOME.md` à la racine du projet, puis `WELCOME.md`.
- Surcharge par la variable d'environnement `WEEBO_WELCOME_FILE`, posée dans le devfile (`env` du composant). Elle permet de pointer un fichier fourni par l'image.
- Markdown standard, sans HTML ni script, pour que le rendu soit identique dans les deux IDE.

### Palier 1 : sans extension (VS Code)

Dans `.vscode/settings.json` du projet :

```json
{ "workbench.startupEditor": "readme" }
```

Limites : seul un fichier nommé `README*` est pris en compte, il est ouvert à chaque démarrage, et ça ne marche pas pour JetBrains. Ce palier suffit si le README du projet joue déjà ce rôle.

### Palier 2 : extension VS Code

Extension sans dépendance runtime :

- `activationEvents: ["onStartupFinished"]`.
- Elle résout le fichier (variable `WEEBO_WELCOME_FILE`, puis chemins par défaut dans le premier dossier du workspace). Si aucun n'existe, elle ne fait rien.
- Au premier démarrage du workspace, elle exécute `markdown.showPreview` sur le fichier. Elle enregistre `welcome.shown` dans `context.workspaceState`, qui est persisté dans le volume du workspace.
- Elle expose une commande `Weebo: Show Welcome` pour rouvrir la page.

Distribution : le `.vsix` est ajouté à `DEFAULT_EXTENSIONS`, soit dans l'image du conteneur dev, soit dans l'image che-code. Il ne passe pas par Open VSX, voir les questions ouvertes.

### Palier 3 : plugin JetBrains

- Un `postStartupActivity` (`ProjectActivity`) résout le fichier avec les mêmes règles.
- Au premier démarrage, il appelle `FileEditorManager.openFile` sur le fichier. L'état « déjà affiché » est stocké dans `PropertiesComponent` au niveau du projet.
- Une action `Weebo: Show Welcome` est ajoutée dans le menu Help.
- Il est installé sur le **backend** (IDE dans le workspace), pas dans le client Gateway.

## Stratégie de tests

- VS Code : test manuel sur un workspace avec et sans `WELCOME.md`, et avec `WEEBO_WELCOME_FILE`. On vérifie la première ouverture puis l'absence d'ouverture au redémarrage.
- JetBrains : mêmes cas via Gateway, en vérifiant que la preview s'affiche dans le thin client.
- Les deux : un fichier absent ou illisible ne doit ni produire d'erreur visible ni bloquer le démarrage.

## Risques

- **Preview JetBrains en remote dev** : selon les réglages, le `.md` peut s'ouvrir en mode éditeur seul plutôt qu'en preview. À vérifier ; la parade est de forcer la disposition via `TextEditorWithPreview`.
- **Installation du plugin backend** : le mécanisme d'installation d'un plugin dans l'IDE backend de Che n'est pas encore choisi (image de l'éditeur, `remote-dev-server.sh installPlugins`, dossier `plugins`).
- **Policy `BlockDefaultExtensionsInstallation`** : si elle est activée chez un client, l'extension VS Code n'est pas installée.

## Plan de livraison

1. Palier 1 sur le repo de ce projet pour valider le contenu type de `WELCOME.md`.
2. Palier 2 : extension VS Code, `.vsix` dans `DEFAULT_EXTENSIONS` de notre image de dev.
3. Palier 3 : plugin JetBrains, une fois l'installation côté backend tranchée.

## Licences et marques

- Code nouveau écrit par weebo-si : il ne copie aucun code Che (EPL-2.0) et peut donc prendre sa propre licence, Apache-2.0 comme `che-images`. Fichier `LICENSE` à la racine du repo.
- Dépendances : `@types/vscode` et `@vscode/vsce` (MIT) côté VS Code ; IntelliJ Platform Gradle Plugin (Apache-2.0) côté JetBrains. Aucune dépendance runtime.
- Si le `.vsix` ou le plugin est distribué à un client, publier le source sur un repo public weebo-si.
- Nom : ne pas utiliser « Eclipse » ni « Che » dans le nom de l'extension, du plugin ou de leur identifiant (par exemple `weebo-si.welcome`, pas `che-welcome`).
- Le contenu de `WELCOME.md` relève du projet et ne pose pas de question de licence. S'il mentionne Eclipse Che, présenter l'environnement comme *basé sur* Eclipse Che.

## Alternatives considérées

| Alternative | Raison du rejet |
|---|---|
| Webview VS Code avec HTML maison | Plus de code (CSP, thème, rendu), aucun gain pour du contenu statique. À reconsidérer pour du contenu dynamique |
| Walkthrough VS Code (`contributes.walkthroughs`) | Le contenu est figé dans l'extension (rebuild à chaque modification) et il n'a pas d'équivalent JetBrains |
| Éditeur JCEF HTML côté JetBrains (`HTMLEditorProvider`) | Affichage dans le thin client Gateway non vérifié, et un deuxième format de contenu à maintenir |
| Patcher la page Welcome de che-code | Modifie du code EPL du fork, crée une divergence avec l'upstream et ne couvre pas JetBrains |

## Questions ouvertes

1. Dans quel repo vit le code : un nouveau repo `weebo-si/welcome`, ou Batlehub comme le suggère le todo ?
2. Le `.vsix` est-il embarqué dans l'image de dev, dans l'image che-code, ou publié sur Open VSX ?
3. Comment installer un plugin dans l'IDE JetBrains backend d'un workspace Che ?
4. La page doit-elle s'ouvrir une seule fois par workspace, ou à chaque démarrage tant qu'elle n'a pas été fermée ?
