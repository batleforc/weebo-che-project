# RFC — Remplacer xterm.js par ghostty-web dans le terminal de che-code

Nov 17, 2026 · @Maxime · Statut : Draft

## Résumé

Le terminal de che-code est celui de VS Code : il repose sur xterm.js (`@xterm/xterm`, huit addons, et `@xterm/headless` côté serveur). Cette RFC étudie son remplacement par [ghostty-web](https://github.com/coder/ghostty-web), l'émulateur de Ghostty compilé en WebAssembly, qui annonce une API compatible avec xterm.js.

L'inventaire fait pour cette RFC montre que **le remplacement complet n'est pas faisable aujourd'hui** : ghostty-web 0.4.0 ne fournit ni markers, ni décorations, ni hooks du parser, ni sérialisation, ni mode headless, ni lecteur d'écran. Le terminal de VS Code en dépend pour l'intégration shell, la reconnexion, la recherche et l'accessibilité.

La RFC propose donc une première étape limitée : un **moteur de rendu optionnel**, côté navigateur seulement, derrière un réglage désactivé par défaut. xterm.js reste le moteur par défaut et le seul utilisé côté serveur. Un point de décision (go / no-go) précède toute suite.

Le changement touche `weebo-si/che-code` (branche `feat/ghostty-terminal`), `forks.yaml` et `che-images` (aucun changement de workflow attendu). Il n'est pas destiné à l'upstream.

## Contexte et motivation

### Ce que ghostty-web apporte

- Le parser VT de Ghostty (`libghostty-vt`, Zig, compilé en WASM de ~400 Ko), le même que l'application native.
- Gestion des graphèmes pour les écritures complexes (devanagari, arabe), `XTPUSHSGR` / `XTPOPSGR`, absents de xterm.js.
- Licence MIT, aucune dépendance d'exécution.

### Le problème à résoudre

Le terminal intégré se comporte parfois mal avec les applications plein écran qui redessinent beaucoup, Claude Code en premier. L'hypothèse de cette RFC est que le moteur de Ghostty fait mieux. **Elle n'est pas démontrée**, pour deux raisons :

- le défaut peut venir de xterm.js lui-même, ou de ce que VS Code met autour (rendu WebGL, intégration shell, décorations, pty host). Dans le second cas, changer de moteur ne corrige rien ;
- ghostty-web a ses propres bugs ouverts sur ce que Claude Code utilise le plus : Ctrl+C (#204), Alt+touche (#203), collage par Ctrl+V dans un CLI d'agent (#148), forme du curseur et défilement à la souris (#145), redessin à chaque frame (#208).

La première étape est donc de vérifier l'hypothèse avant d'écrire du code dans che-code (voir [Étape 0](#étape-0--vérifier-lhypothèse-sans-toucher-à-che-code)).

### État du projet (relevé le 17 nov. 2026)

- Dernière version stable sur npm : `0.4.0` (9 déc. 2025). La branche `main` avance (dernier commit le 28 oct. 2026) et publie des versions `next` (`0.4.0-next.21.g640db46`). Une nouvelle version stable est demandée dans l'issue #137.
- Le WASM est construit depuis le dépôt Ghostty (sous-module) avec un patch local de 1 620 lignes (`patches/ghostty-wasm-api.patch`). Le README prévoit de consommer une distribution WASM officielle de Ghostty quand elle existera.
- Rendu par canvas 2D uniquement. Le rendu WebGL est une demande ouverte (#155).
- Issues ouvertes qui nous concernent directement : pas de représentation pour lecteur d'écran (#187), chargement du WASM bloqué par une CSP `connect-src 'self'` (#188), `attachCustomKeyEventHandler` avec un contrat inversé par rapport à xterm.js (#192), Ctrl+Shift+C qui envoie `^C` (#204), Alt+touche sans préfixe ESC (#203), redessin à chaque frame (#208), corruptions mémoire WASM après libération d'un terminal (#141, #210), API internes de xterm.js (#105).

### Ce que le terminal de VS Code utilise de xterm.js

Dans `code/src` de che-code (base `7.123.x`, xterm `6.1.0-beta.288`) : 98 fichiers importent `@xterm/*`.

| Besoin de VS Code | API xterm.js | ghostty-web 0.4.0 |
|---|---|---|
| Écriture, saisie, redimensionnement, sélection, défilement | `write`, `input`, `paste`, `resize`, `select`, `scrollToLine`… | Oui |
| Lecture du buffer (liens, IA, accessibilité) | `buffer.active.getLine`, `cursorX/Y`, `baseY`, `viewportY` | Oui, avec des bugs ouverts (#200, #205, lignes repliées du scrollback non signalées) |
| Liens | `registerLinkProvider` | Oui |
| Intégration shell (OSC 633, détection des commandes) | `parser.registerOscHandler`, `registerCsiHandler` | **Non** |
| Décorations de commandes, navigation, sticky scroll, quick fix | `registerMarker`, `registerDecoration` | **Non** |
| Événements de fin d'écriture et de ligne | `onWriteParsed`, `onLineFeed` | **Non** |
| Reconnexion et restauration des terminaux (pty host) | `@xterm/headless`, `addon-serialize` | **Non** (pas de mode sans DOM, pas de sérialisation) |
| Recherche dans le terminal | `addon-search` | **Non** |
| Largeur des caractères | `addon-unicode11`, `unicode.activeVersion` | Géré par Ghostty, sans choix de version |
| Rendu GPU, images, ligatures, progression, presse-papiers OSC 52 | `addon-webgl`, `-image`, `-ligatures`, `-progress`, `-clipboard` | **Non** |
| Lecteur d'écran | `options.screenReaderMode` | **Non** (#187) |
| Options de rendu | une quarantaine d'options (`lineHeight`, `letterSpacing`, `minimumContrastRatio`, `cursorStyle`…) | Une dizaine (`fontSize`, `fontFamily`, `theme`, `cursorBlink`, `scrollback`…) |
| API privées | `_core` : 19 usages dans 6 fichiers | **Non** |

Deux constats structurent la conception :

1. **Un seul point de création côté navigateur.** `terminalInstance.ts` charge le constructeur par `importAMDNodeModule('@xterm/xterm', 'lib/xterm.js')`. Les addons passent par `xtermAddonImporter.ts`. Le moteur peut donc être choisi à cet endroit.
2. **Le serveur est indépendant du rendu.** Le pty host (`ptyService.ts`) tient un xterm headless par terminal pour la sérialisation (reconnexion) et l'intégration shell. Il renvoie au navigateur un flux VT, que n'importe quel émulateur peut rejouer. Il n'a pas besoin de changer.

## Objectifs et non-objectifs

**Objectifs**

1. Un réglage `terminal.integrated.experimental.engine` (`xterm` par défaut, `ghostty`) qui choisit le moteur des nouveaux terminaux du navigateur.
2. Avec `ghostty` : le terminal s'ouvre dans n'importe quel conteneur du pod, affiche, accepte la saisie, se redimensionne, copie et colle, suit le thème et la police (y compris celles de [che-code-02](../che-code-02/che-code-fonts-rfc.md)), et se reconnecte après un rechargement de page.
3. Avec `xterm` : aucun changement de comportement, et le WASM n'est pas téléchargé.
4. Une liste mesurée des écarts, pour décider de la suite.

**Non-objectifs**

- Retirer xterm.js du dépôt ou du pty host.
- Réimplémenter dans che-code les API manquantes (markers, décorations, hooks du parser, recherche). Si elles sont nécessaires, elles se contribuent à ghostty-web.
- Maintenir un fork de ghostty-web ou construire le WASM nous-mêmes.
- Proposer le changement à `che-incubator/che-code`.

## Conception

### Étape 0 : vérifier l'hypothèse sans toucher à che-code

ghostty-web fournit une démo qui ouvre un vrai shell dans une page : `npx @ghostty-web/demo@next`. Lancée dans le conteneur de dev d'un workspace, elle donne le moteur de Ghostty dans le même navigateur, avec le même shell, la même police et le même Claude Code que le terminal intégré.

1. **Lister les symptômes.** Relevé du 17 nov. 2026, à compléter par une reproduction et une capture pour chacun :

   | Symptôme | Cause probable (hypothèse, non vérifiée) | Vérification |
   |---|---|---|
   | Des chaînes de caractères apparaissent dans le shell quand la souris bouge sur le terminal | Suivi de souris resté actif : une application plein écran l'active (`CSI ? 1000/1002/1003/1006 h`) et s'arrête sans le désactiver (processus tué, page rechargée, reconnexion). Le terminal envoie alors chaque mouvement au shell, qui l'affiche (`35;40;12M`…). Ce n'est pas un défaut du moteur : Ghostty applique le même mode | Quand ça arrive, `printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'` : si les chaînes cessent, l'hypothèse est confirmée. Noter ce qui précédait (rechargement, arrêt de Claude Code) |
   | Certains raccourcis ne fonctionnent pas | Touche prise par le navigateur ou par les raccourcis de VS Code avant d'atteindre le terminal (`terminal.integrated.commandsToSkipShell`, `sendKeybindingsToShell`). Un autre moteur dans VS Code ne change pas cette couche | Lister les raccourcis. Les essayer dans la démo ghostty-web (pas de VS Code autour) et avec `sendKeybindingsToShell: true` |
   | Curseur mal placé | Largeur de caractères comptée différemment par l'application et le terminal (emoji, graphèmes), ou curseur matériel masqué puis mal restauré | Noter le texte affiché à ce moment. Comparer avec `terminal.integrated.unicodeVersion` et dans la démo. C'est le symptôme où Ghostty a le plus de chances de faire mieux |
2. **Isoler la cause côté VS Code.** Rejouer chaque symptôme avec `terminal.integrated.gpuAcceleration: off` puis `terminal.integrated.shellIntegration.enabled: false`. Un symptôme qui disparaît n'est pas un défaut du moteur : il se règle par un réglage par défaut dans l'image, sans cette RFC.
3. **Rejouer dans la démo ghostty-web** les symptômes qui restent, plus une session Claude Code normale (saisie longue, collage, Ctrl+C, Échap, Maj+Tab, défilement pendant une réponse, redimensionnement).

La démo écoute sur `127.0.0.1:8080` et ouvre un shell : l'atteindre par un transfert de port du workspace, sans endpoint public dans le devfile.

**Critère pour continuer** : au moins un symptôme de la liste disparaît dans la démo, et aucun des bugs ouverts de ghostty-web ne rend Claude Code moins utilisable que dans le terminal intégré. Sinon, no-go, et les symptômes vont en issues chez xterm.js ou VS Code.

### Choix du moteur

Dans `terminalInstance.ts`, au point où le constructeur xterm est chargé :

```ts
const engine = this._configurationService.getValue(TerminalSettingId.ExperimentalEngine);
const Terminal = engine === 'ghostty'
	? (await import('./xterm/ghosttyTerminal.js')).GhosttyTerminal
	: (await importAMDNodeModule<typeof import('@xterm/xterm')>('@xterm/xterm', 'lib/xterm.js')).Terminal;
```

Le réglage est lu à la création du terminal : un changement s'applique aux terminaux suivants. Il est déclaré dans `terminalConfiguration.ts`, qui a déjà une règle de rebase che-code.

### Adaptateur : `ghosttyTerminal.ts`

Un seul nouveau fichier, `code/src/vs/workbench/contrib/terminal/browser/xterm/ghosttyTerminal.ts`. Il exporte une classe qui étend le `Terminal` de ghostty-web et complète l'interface `Terminal` de `@xterm/xterm` attendue par le reste du code :

- **Chargement du WASM.** `init()` cherche le WASM par une URL `data:`, refusée par notre CSP (`connect-src 'self' ws: wss: https:`, issue #188). L'adaptateur appelle `Ghostty.load(<URL du fichier ghostty-vt.wasm servi par le serveur VS Code>)` une fois, puis passe l'instance à chaque terminal (`new Terminal({ ghostty })`). La compilation WASM est déjà permise par le `'unsafe-eval'` du `script-src` de `workbench.html`. Aucune modification de CSP.
- **Membres absents, neutralisés.** `parser.register*Handler` renvoie un `IDisposable` vide, `registerMarker` et `registerDecoration` renvoient `undefined`, `onWriteParsed` est émis après chaque `write`, `onLineFeed` n'émet jamais, `unicode` expose une version fixe, `loadAddon` ignore les addons xterm (webgl, search, serialize, image, ligatures, progress, clipboard, unicode11).
- **Options.** Les options inconnues de ghostty-web sont ignorées.
- **Contrat de `attachCustomKeyEventHandler`.** Inversé dans l'adaptateur tant que #192 est ouverte, avec un commentaire qui cite l'issue.

Conséquences assumées en mode `ghostty` : pas de décorations ni de navigation entre commandes, pas de sticky scroll, pas de quick fix, pas de recherche, pas de suggestions du terminal, pas de rendu GPU, pas de lecteur d'écran. Les outils d'agent qui lisent la sortie par les markers ne fonctionnent pas. La détection des commandes côté serveur continue (xterm headless).

À vérifier à l'implémentation : que le code appelant accepte partout un `registerMarker` qui renvoie `undefined` (40 appels hors tests), et le sort des 19 usages de `_core`. Chaque garde ajoutée hors de l'adaptateur est une ligne de plus à porter aux rebases : au-delà d'une dizaine de fichiers touchés, c'est un critère de no-go.

### Build et image

- `ghostty-web` est ajouté à `code/package.json` et `code/remote/web/package.json`, version exacte (pas de `^` : le projet est en 0.x).
- `ghostty-vt.wasm` doit être servi avec les modules web. Le mécanisme exact dans le build `vscode-reh-web` est à vérifier à l'implémentation (comment les `.wasm` de `vscode-oniguruma` y sont déjà inclus).
- Règles de rebase dans `.rebase/` pour les fichiers upstream modifiés (`terminalInstance.ts` et `terminalConfiguration.ts` ont déjà les leurs, `package.json` aussi).
- `che-images` : aucun changement, l'image est construite depuis `develop`.

### Point de décision

Après les tests ci-dessous, trois issues possibles :

- **No-go.** Fermer la RFC, retirer la branche de `develop`. Coût : un fichier et quatre règles de rebase.
- **Garder le moteur optionnel**, sans plus, tant que ghostty-web n'a pas les API manquantes.
- **Go pour la suite** : contribuer à ghostty-web les API nécessaires (au minimum hooks du parser, markers, sérialisation), dans une RFC séparée. Le remplacement par défaut ne s'envisage qu'après.

## Stratégie de tests

**Automatisés**

- Un test navigateur (`ghosttyTerminal.test.ts`) : création, `write`, lecture d'une ligne du buffer, `resize`, `dispose`, et appel de chaque membre neutralisé sans exception.
- Les tests existants du terminal restent verts (moteur par défaut inchangé).

**Manuels, sur le cluster weebo-si, réglage `ghostty`**

1. Ouvrir un terminal dans le conteneur de dev et dans un second conteneur du pod (extension `che-terminal`).
2. `vim`, `htop`, `tmux`, `less` : écran alternatif, souris, redimensionnement du panneau.
3. Prompt `starship` avec une Nerd Font du conteneur (che-code-02) : glyphes et séparateurs powerline (#184).
4. Copier, coller, Ctrl+C avec et sans sélection (#204), Alt+touche (#203), saisie avec touches mortes (clavier français).
5. Recharger la page pendant une commande longue : le terminal se reconnecte et retrouve son contenu.
6. Ouvrir et fermer 50 terminaux à des largeurs différentes : pas d'erreur WASM (#141, #210).
7. Thème clair, sombre et changement de thème à chaud (#125).
8. Réglage `xterm` : non-régression, et `ghostty-vt.wasm` absent de l'onglet réseau.

**Mesures**, sur les deux moteurs : temps d'ouverture du premier terminal, `cat` d'un fichier de 100 Mo, CPU du navigateur au repos (#208), mémoire avec 10 terminaux.

## Risques

- **Maturité.** Projet en 0.x, dernière version stable vieille de onze mois, bugs de corruption mémoire ouverts. Mitigé par le réglage désactivé par défaut et la version épinglée.
- **Accessibilité.** Aucun support de lecteur d'écran : le moteur ne peut pas devenir le défaut tant que #187 est ouverte.
- **Coût de rebase.** VS Code modifie son terminal à chaque version et monte xterm.js en continu. L'adaptateur doit suivre l'interface `Terminal` de xterm à chaque rebase de che-code. Limité tant que tout tient dans un fichier.
- **Divergence serveur / navigateur.** Le pty host calcule l'état avec xterm, le navigateur avec Ghostty. Les largeurs de caractères (emoji, graphèmes) peuvent différer et décaler le contenu restauré après reconnexion. À observer au test 5.
- **Chaîne d'approvisionnement.** Le WASM publié sur npm est un binaire construit par Coder depuis Ghostty et un patch. Nous ne le reconstruisons pas.
- **Fonctions perdues en mode `ghostty`.** Voir [Conception](#adaptateur--ghosttyterminalts). À documenter dans la description du réglage.

## Plan de livraison

1. Étape 0 : liste des symptômes, essais des réglages VS Code, essai de la démo ghostty-web. Résultats ajoutés à cette RFC. Arrêt ici si le critère n'est pas rempli.
2. Branche `feat/ghostty-terminal` sur `weebo-si/che-code`, créée depuis l'ancêtre commun de `main` et `7.123.x` comme les autres, avec `Signed-off-by` sur chaque commit.
3. Adaptateur, réglage, ressource WASM, test, règles de rebase.
4. `forks.yaml` : ajouter `{ branch: feat/ghostty-terminal, rfc: che-code-04 }` à `che-code.develop.merge`, puis `task forks:update` pour reconstruire `develop`.
5. Image construite par `che-images`, tests manuels et mesures sur le cluster weebo-si.
6. Décision, puis mise à jour du statut de cette RFC.

## Licences

- `che-code` est sous EPL-2.0, VS Code (`code/`) sous MIT. Les fichiers upstream modifiés gardent leur en-tête Microsoft. Le nouveau fichier `ghosttyTerminal.ts` est dans `code/` : en-tête à confirmer avant d'écrire le fichier (l'en-tête du launcher décidé le 7 oct. 2026 vise les fichiers che-code, pas l'arbre VS Code).
- `ghostty-web` : MIT, `Copyright (c) 2025 Coder`. Autorisé par nos règles. Sa notice doit être livrée dans l'image.
- `ghostty-vt.wasm` contient du code de Ghostty (MIT, Mitchell Hashimoto et contributeurs) lié statiquement. **À vérifier avant d'ajouter la dépendance** : la liste des bibliothèques tierces compilées dans la cible `lib-vt` en `wasm32-freestanding` et leurs licences, puisque le paquet npm ne livre que la licence de Coder. Leurs notices sont à ajouter à celles de l'image.
- Pas d'approbation Eclipse Foundation (ClearlyDefined / IP) à demander tant que le changement reste sur le fork. Elle deviendrait nécessaire pour une contribution upstream.
- L'image reste construite depuis un commit poussé sur le fork public, avec les labels `org.opencontainers.image.source`, `.revision` et `.licenses`.
- Marques : « Ghostty » est le nom d'un projet tiers. Le réglage et sa description disent « moteur basé sur ghostty-web », sans logo.

## Alternatives considérées

- **Remplacer l'import `@xterm/xterm` par `ghostty-web` partout** (ce que propose le README). Ne compile pas : 98 fichiers utilisent des API absentes. Rejeté.
- **Remplacer aussi `@xterm/headless` dans le pty host.** ghostty-web n'a pas de sérialisation, donc plus de reconnexion. Rejeté.
- **Implémenter markers, décorations et hooks du parser dans l'adaptateur.** Revient à réécrire une partie de xterm.js au-dessus d'un buffer qui n'expose pas ses événements. À faire dans ghostty-web, pas dans che-code. Rejeté pour cette étape.
- **Attendre.** La feuille de route de ghostty-web (#156) et la distribution WASM officielle de Ghostty peuvent combler les écarts sans travail de notre part. C'est l'issue « no-go » : elle reste ouverte à chaque étape.
- **Corriger xterm.js ou régler VS Code** pour les symptômes précis. Profite à l'upstream et n'ajoute rien à maintenir. C'est l'issue de l'étape 0 quand un symptôme vient d'un réglage ou d'un bug identifié.

## Questions ouvertes

- Quels sont précisément les symptômes avec Claude Code (scintillement, lignes en double, curseur mal placé, raccourcis perdus, lenteur) ? À lister à l'étape 0.
- Version à épingler : `0.4.0` (stable, ancienne) ou une `next` (à jour, sans garantie) ?
- Les fonctions perdues en mode `ghostty` sont-elles acceptables pour un usage quotidien, ou le moteur reste-t-il une démonstration ?
- weebo-si est-elle prête à contribuer à ghostty-web (hooks du parser, markers, sérialisation) si la décision est « go » ?
