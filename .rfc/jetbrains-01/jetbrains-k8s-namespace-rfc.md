# RFC — Utiliser le plugin JetBrains Gateway sur un cluster Kubernetes (namespace saisi par l'utilisateur)

Oct 7, 2026 · @Maxime · Statut : Brouillon

## Résumé

Le plugin JetBrains Gateway de Che (`redhat-developer/devspaces-gateway-plugin`, notre fork : `weebo-si/devspaces-gateway-plugin`) ne trouve les workspaces que sur OpenShift. Pour savoir où chercher les DevWorkspaces, l'assistant liste les `projects.project.openshift.io`. Cette API n'existe pas sur Kubernetes : la liste échoue (404) et aucun workspace ne s'affiche, alors que tout le reste du plugin (DevWorkspaces, exec et port-forward vers le pod, watch) n'utilise que des API Kubernetes standard.

Cette RFC ajoute un champ **Namespace** à l'étape de connexion de l'assistant. S'il est rempli, le plugin cherche les DevWorkspaces dans ce namespace et n'appelle pas l'API des projects. S'il est vide, rien ne change (comportement OpenShift actuel). Le champ est prérempli avec la dernière valeur saisie pour ce cluster, sinon avec le `namespace` du contexte kubeconfig.

Pour l'authentification, l'onglet Token utilise le plugin `exec` du kubeconfig (`kubectl oidc-login`) quand l'utilisateur du cluster en a un, sinon le jeton déjà présent dans le kubeconfig, comme aujourd'hui.

Le changement touche le plugin Gateway seulement : l'étape serveur (`DevSpacesServerStepView`), l'onglet Token (`TokenAuthenticationStrategy`), l'étape workspaces (`DevSpacesWorkspacesStepView`), `DevSpacesContext` et `DevSpacesSettings`. Il est développé sur notre fork `weebo-si/devspaces-gateway-plugin` (branche `feat/k8s-namespace`, intégrée à `develop` via `forks.yaml`), puis proposé upstream.

## Contexte et motivation

### Le besoin

Notre Che tourne sur Kubernetes (Talos), pas sur OpenShift. Le namespace de chaque utilisateur suit le template `dev-ws-<username>` (`deploy/develop/checluster.yaml`, `spec.devEnvironments.defaultNamespace`). Un développeur qui veut ouvrir son workspace dans IntelliJ via l'assistant Gateway ne voit aucun workspace. Le seul chemin qui marche est le lien profond depuis le dashboard (voir plus bas).

Le README du fork le dit déjà (commit `085a82d`, « feat: wip ») : l'objectif du fork est de rendre le plugin compatible avec Kubernetes sans casser OpenShift.

### Ce qui dépend d'OpenShift dans le plugin

Relevé sur l'upstream `main` (`2699f5c`, 2026-10-07) :

| Élément | Dépend d'OpenShift ? | Détail |
|---|---|---|
| Liste des namespaces (`openshift/Projects.kt`, `list()`) | **Oui** | `listClusterCustomObject("project.openshift.io", "v1", "projects")`. Seul appelant : `DevSpacesWorkspacesStepView.refreshAllDevWorkspaces()` |
| Vérification d'authentification (`Projects.isAuthenticated()`) | Non | Une `SelfSubjectAccessReview` : l'API existe sur Kubernetes et répond 201 même si l'accès est refusé. Seul un 401 compte |
| Watch des DevWorkspaces (`DevWorkspaceWatchManager.start()`) | Non | Il surveille les namespaces que `refreshAllDevWorkspaces()` lui passe |
| DevWorkspaces, pods, exec, port-forward | Non | API Kubernetes standard et CRD `workspace.devfile.io` |
| Lien profond (`DevSpacesConnectionProvider`, paramètres `dwNamespace` et `dwName`) | Non | Le namespace vient du lien, le client vient du kubeconfig courant |
| Authentification par token et par certificat client | Non | Mais l'onglet Token ne lit que le champ `token` de l'utilisateur kubeconfig (`KubeConfigNamedUser.getUserTokenForCluster`) : un utilisateur `exec` (`kubectl oidc-login`) n'a pas de jeton prérempli |
| Authentification OpenShift (OAuth PKCE, identifiants, Red Hat SSO) | Oui | Hors périmètre : ces onglets ne servent pas sur Kubernetes |

Il n'y a donc qu'un appel à remplacer pour les namespaces, plus le préremplissage du jeton pour les utilisateurs OIDC.

### L'authentification sur notre cluster

L'API Kubernetes de notre cluster accepte les jetons OIDC d'Authentik. Côté poste, le kubeconfig des développeurs utilise `kubectl oidc-login` (plugin `exec`), qui ouvre le navigateur au premier appel puis met le jeton en cache.

Le client Java gère déjà ce cas : `KubeConfig.getCredentials()` (`client-java` 24.0.0) lance la commande `exec` (API `client.authentication.k8s.io/v1`, `v1beta1` ou `v1alpha1`) et la fait passer avant le champ `token`. Le lien profond, qui construit son client avec `ClientBuilder.kubeconfig(...)`, en profite déjà. Seul l'assistant ne le fait pas : il lit le champ `token` et construit son propre client.

### État de notre fork

L'ancien fork `batleforc/eclipse-che-gateway-plugin` est en retard sur l'upstream (dernier commit commun en septembre). L'upstream a depuis réorganisé le code : `DevWorkspaceWatchManager` est dans son propre fichier et ne liste plus les projects lui-même. Le nouveau fork `weebo-si/devspaces-gateway-plugin` part de l'upstream `main` et est géré par `forks.yaml` comme les autres. Le commit README `wip` de l'ancien fork n'est pas repris.

## Objectifs et non-objectifs

**Objectifs**

1. Sur un cluster Kubernetes, l'assistant Gateway liste, démarre, arrête et ouvre les workspaces du namespace saisi par l'utilisateur.
2. Sur OpenShift, avec le champ vide, le comportement est le même qu'aujourd'hui.
3. Le namespace saisi est retenu pour ce cluster d'une session à l'autre.
4. Un développeur dont le kubeconfig utilise `kubectl oidc-login` se connecte sans copier de jeton.
5. Une erreur claire quand le namespace est vide sur un cluster sans API des projects, ou quand l'utilisateur n'a pas accès au namespace.

**Non-objectifs**

- Deviner le namespace (template `dev-ws-<username>`, appel à l'API du dashboard ou de che-server). Voir [Alternatives](#alternatives-considérées).
- Plusieurs namespaces à la fois (décidé : un seul). Che donne un namespace par utilisateur.
- Un flux OIDC intégré au plugin (découverte Authentik, PKCE). `kubectl oidc-login` le fait déjà.
- Rafraîchir le jeton pendant la session (voir [Risques](#risques)).
- Masquer les onglets d'authentification propres à OpenShift sur Kubernetes.
- Renommer le plugin ou ses libellés (« OpenShift Dev Spaces », « Connecting to OpenShift… »). Voir [Licences](#licences-et-marques).
- Le plugin `che-integration-plugin` de `jetbrains-ide-dev-server`, qui tourne dans le workspace et n'utilise pas d'API OpenShift.

## Conception

### Étape serveur : le champ Namespace

Un champ texte **Namespace** sous le sélecteur de cluster, commun à tous les onglets d'authentification. Facultatif, avec le texte d'aide « Leave empty on OpenShift to list all your projects ».

Préremplissage, quand l'utilisateur choisit un cluster :

1. la valeur enregistrée pour l'URL de ce serveur dans `DevSpacesSettings` ;
2. sinon le champ `namespace` du contexte kubeconfig de ce cluster (déjà lu par `KubeConfigNamedContext`) ;
3. sinon vide.

Dans `onNext()`, après une authentification réussie : la valeur (après `trim()`, `null` si vide) va dans `DevSpacesContext.namespace` et dans les settings, à côté du `settings.save(selectedCluster)` existant.

Le nom n'est pas vérifié dans l'étape serveur : l'étape workspaces le lit juste après et affiche l'erreur (voir plus bas). Une vérification plus tôt demanderait un appel de plus pour un gain faible.

### Onglet Token : `exec` d'abord, jeton existant sinon

Quand l'utilisateur clique sur Suivant avec le champ Token vide, et que l'utilisateur kubeconfig du cluster choisi a une entrée `exec` :

1. le plugin appelle `KubeConfig.getCredentials()` sur ce contexte, dans le thread de la barre de progression (« Getting a token from kubectl oidc-login… ») ; `oidc-login` ouvre le navigateur si son cache est vide ;
2. le jeton obtenu suit le chemin actuel (`createValidatedApiClient`) ;
3. il n'est **pas** écrit dans le kubeconfig, même si « Save configuration » est coché : un `token` statique à côté de l'`exec` ferait utiliser un jeton expiré à d'autres outils.

Sans `exec`, rien ne change : le champ est prérempli avec le `token` du kubeconfig (`getUserTokenForCluster`), comme aujourd'hui. Un jeton saisi à la main passe toujours avant `exec`.

Pour savoir si le champ peut rester vide, `KubeConfigUser` gagne un booléen `hasExec` (lu dans `fromMap`). Le texte d'aide du champ devient « Leave empty to use the kubeconfig exec plugin (kubectl oidc-login) » quand il est vrai. `isNextEnabled()` accepte un champ vide dans ce cas.

L'`exec` lance une commande écrite dans le kubeconfig de l'utilisateur, avec ses droits : c'est ce que fait déjà `kubectl`, et le lien profond du plugin. Aucune commande n'est lancée sans clic sur Suivant.

### Contexte et settings

```kotlin
// DevSpacesContext
var namespace: String? = null

// DevSpacesState
var namespaces by map<String, String>()   // URL du serveur -> namespace
```

La clé est l'URL du serveur, pas le nom du cluster : le nom dépend du kubeconfig de chacun et change d'un poste à l'autre, l'URL non.

### Étape workspaces : la source des namespaces

`refreshAllDevWorkspaces()` reçoit sa liste de namespaces d'un seul endroit :

```kotlin
val namespaces = devSpacesContext.namespace?.let { listOf(it) }
    ?: Projects(devSpacesContext.client).list()
        .map { Utils.getValue(it, arrayOf("metadata", "name")) as String }
```

Le reste ne change pas : `fetchDevWorkspacesForNamespace()` pour chaque namespace, puis le watch démarre sur les namespaces de `lastResourceVersions`. Le log qui compte les projects compte maintenant des namespaces.

### Messages d'erreur

| Cas | Code | Message |
|---|---|---|
| Champ vide, cluster sans `project.openshift.io` | 404 sur la liste des projects | « This cluster is not OpenShift. Go back and enter the namespace of your workspaces. » |
| Namespace sans droits | 403 sur la liste des DevWorkspaces | « You have no access to DevWorkspaces in namespace “x”. » |
| CRD absente ou namespace inexistant | 404 sur la liste des DevWorkspaces | « No DevWorkspaces found in namespace “x”. Check the namespace and that the DevWorkspace Operator is installed. » |

Les trois passent par le `Dialogs.error(...)` existant de `refreshAndWatchAllDevWorkspaces()`. Il suffit de traduire l'`ApiException` en message. `ApiExceptionUtils.kt` a déjà des helpers pour ça.

## Stratégie de tests

**Unitaires** (dans les tests existants, `src/test/kotlin`) :

- `KubeConfigUser.fromMap` : `hasExec` vrai avec une entrée `exec`, faux sinon.
- Onglet Token : champ vide + `exec` → jeton tiré de `getCredentials()` (commande factice dans le test), rien d'écrit dans le kubeconfig ; champ rempli → `exec` ignoré.

- Choix de la source des namespaces : `namespace` renseigné → aucun appel à `CustomObjectsApi` ; `null` → liste des projects (cas actuel).
- Préremplissage : la valeur des settings passe avant celle du kubeconfig, et celle du kubeconfig avant le vide.
- Traduction des erreurs : 404 sur les projects, 403 et 404 sur les DevWorkspaces.

**Manuels**, avec `./gradlew runIde` (Gateway) :

| Cluster | Namespace | Attendu |
|---|---|---|
| Notre cluster Kubernetes, `kubectl oidc-login` (cache vide puis plein) | `dev-ws-<moi>` | Workspaces listés, démarrage, ouverture dans IntelliJ, arrêt, mises à jour par le watch |
| Notre cluster Kubernetes, jeton collé à la main | `dev-ws-<moi>` | Pareil |
| Notre cluster Kubernetes | vide | Message « not OpenShift » |
| Notre cluster Kubernetes | namespace d'un autre utilisateur | Message « no access » |
| Notre cluster Kubernetes | lien profond depuis le dashboard | Ouverture du workspace (aucun changement attendu, vérifier quand même) |
| OpenShift (Developer Sandbox) | vide | Comportement actuel |

## Risques

- **Jeton qui expire pendant la session** (risque déjà présent aujourd'hui, pas introduit par cette RFC). Le client de l'assistant garde le jeton obtenu au clic sur Suivant. Quand il expire (durée de vie du jeton Authentik), les appels suivants (rafraîchir la liste, démarrer, arrêter) échouent avec un 401. Le port-forward déjà ouvert vers l'IDE n'est pas touché. Parade : revenir à l'étape serveur. Si c'est trop fréquent, construire le client avec `ClientBuilder.kubeconfig(...)`, qui relance l'`exec` à chaque expiration, dans une RFC suivante.
- **`oidc-login` absent du PATH de Gateway** (déjà le cas pour le lien profond, pas introduit par cette RFC). Gateway lancé depuis le bureau n'a pas toujours le PATH du shell (macOS surtout). L'erreur de `getCredentials()` doit le dire, avec la commande attendue.
- **Refus upstream.** Le plugin est un produit Red Hat centré sur OpenShift Dev Spaces. Ils peuvent refuser un champ qui ne sert pas sur OpenShift. Le changement est petit et isolé : on le garde sur notre fork sans difficulté.
- **Retard du fork.** Partir d'un fork ancien donnerait des conflits sur `DevSpacesWorkspacesStepView`. D'où le départ depuis l'upstream `main`.

## Plan de livraison

1. ~~Créer le fork `weebo-si/devspaces-gateway-plugin` et l'ajouter à `forks.yaml`~~ (fait le 2026-10-07).
2. Branche `feat/k8s-namespace` : champ, contexte, settings, source des namespaces, `exec` dans l'onglet Token, messages, tests unitaires. L'ajouter aux `merge` de `develop` dans `forks.yaml`.
3. Tests manuels sur notre cluster et sur le Developer Sandbox.
4. PR upstream sur `redhat-developer/devspaces-gateway-plugin`.
5. Distribution aux développeurs : voir [Licences](#licences-et-marques) avant toute distribution hors de l'équipe.

## Licences et marques

- **Licence.** Le plugin est sous EPL-2.0 (`LICENSE`, en-têtes `Copyright (c) 2024 Red Hat, Inc.`). Les fichiers modifiés restent EPL-2.0 et gardent leurs en-têtes. La RFC n'ajoute aucun fichier ni aucune dépendance.
- **En-tête des nouveaux fichiers.** Le repo n'a pas de vérificateur d'en-tête et `CLAUDE.md` ne fixe pas de règle pour ce repo. Si un fichier doit être ajouté (un test par exemple), il faut décider de l'en-tête, comme pour `che-code` (`Copyright (c) <année> Contributors to the Eclipse Foundation` ?).
- **Disponibilité du source.** Un plugin construit depuis notre fork et donné à un client est une distribution d'un binaire EPL : il doit être construit depuis un commit poussé sur le fork public `weebo-si/devspaces-gateway-plugin`.
- **Marques.** « OpenShift », « Dev Spaces » et « Red Hat » sont des marques de Red Hat. Le plugin publié s'appelle « OpenShift Dev Spaces » (ID `com.redhat.devtools.gateway`). Un build distribué par weebo-si sous ce nom pourrait laisser croire à un produit Red Hat. Avant toute distribution hors de l'équipe, il faut un nom et un ID de plugin à nous, présentés comme *basés sur* le plugin Red Hat.
- **Contribution upstream.** Le repo `redhat-developer` n'est pas un projet Eclipse : l'ECA ne s'applique pas. Vérifier s'il demande un DCO (`Signed-off-by`) ou un CLA.

## Alternatives considérées

- **Deviner le namespace depuis le template Che** (`dev-ws-<username>`). Il faudrait connaître le template (dans la `CheCluster`, souvent illisible pour un utilisateur) et le nom d'utilisateur tel que Che le voit. Fragile, et le champ saisi couvre le même cas.
- **Demander le namespace à che-server** (`GET /api/kubernetes/namespace`). C'est la bonne source, mais il faut l'URL de Che et un token accepté par la passerelle Che, en plus de celui de l'API Kubernetes. Peut venir plus tard comme préremplissage, sans changer le champ.
- **Lister les namespaces avec `listNamespace()`.** Un utilisateur Che n'a en général pas le droit de lister les namespaces du cluster (403).
- **Lister les DevWorkspaces de tout le cluster** (`listClusterCustomObject` sur `devworkspaces`). Même problème de droits.
- **Détecter OpenShift et n'afficher le champ que sur Kubernetes.** Un appel de plus avant d'afficher l'étape, pour masquer un champ facultatif. Le champ vide fait déjà le travail.

## Questions ouvertes

1. **En-tête** des nouveaux fichiers éventuels dans ce repo (voir [Licences](#licences-et-marques)).
2. **Durée de vie du jeton Authentik** : si elle est courte (5 min), le risque « jeton qui expire » devient le cas normal et le client `ClientBuilder.kubeconfig(...)` passe dans cette RFC.

## Décisions

- 2026-10-07 : un seul namespace.
- 2026-10-07 : authentification par `kubectl oidc-login` (`exec` du kubeconfig) si présent, sinon jeton existant.
- 2026-10-07 : fork déplacé sous `weebo-si/devspaces-gateway-plugin`, géré par `forks.yaml`.
