# RFC — Support natif de Forgejo dans les gitServices d'Eclipse Che / Dev Spaces

Sep 30, 2026 · @Maxime · Statut : Draft

## Résumé

Cette RFC ajoute Forgejo comme fournisseur SCM de premier rang dans Eclipse Che, au même niveau que GitHub, GitLab, Bitbucket et Azure DevOps. Elle couvre les quatre dépôts qui forment Dev Spaces : `che-operator` (API `CheCluster`), `che-server` (factory, OAuth, PAT), `che-dashboard` (UI et backend) et l'impact sur DevWorkspace Operator et `che-code`.

L'implémentation vise l'API Gitea/Forgejo v1, ce qui couvre aussi Gitea et Codeberg sans surcoût. La cible est l'upstream Eclipse Che ; Dev Spaces en hérite par le build downstream.

## Contexte et motivation

Forgejo est la forge git de weebo-si, avec signature de commits obligatoire, mais Che ne le reconnaît pas. `CheClusterGitServices` n'expose que `github`, `gitlab`, `bitbucket` et `azure`. Tout dépôt Forgejo retombe donc sur le chemin générique : pas d'OAuth, pas de résolution de devfile authentifiée, pas de `.gitconfig` peuplé.

Le contournement actuel (Secret PAT créé à la main ou par ESO, label `controller.devfile.io/git-credential`) permet le clone, mais échoue en trois points :

- Le factory resolver ne sait pas lire un `devfile.yaml` privé : `ScmPersonalAccessTokenFetcher` lève `UnknownScmProviderException` faute de fetcher pour l'URL.
- Le dashboard détecte le fournisseur par sous-chaîne du hostname (`url.host.includes('gitlab')`) : `git.weebo.poc` est rejeté comme « Provider not supported ».
- L'utilisateur ne peut ni connecter son compte Forgejo depuis *User Preferences*, ni y saisir un PAT typé Forgejo.

L'API Forgejo étant compatible Gitea v1, un seul fournisseur couvre Forgejo, Gitea et Codeberg, ce qui rend la contribution upstream plus acceptable.

## Objectifs et non-objectifs

**Objectifs**

1. Déclarer une ou deux instances Forgejo dans `CheCluster.spec.gitServices.forgejo`, avec un Secret OAuth2 dédié.
2. Lancer un workspace depuis une URL Forgejo (repo, branche, tag, commit, fichier), dépôt public ou privé, avec résolution du devfile.
3. Connecter son compte Forgejo par OAuth2 (avec refresh token) ou par PAT depuis le dashboard.
4. Injecter automatiquement les credentials git et le `.gitconfig` (nom, email) dans le workspace.
5. Fonctionner sur une instance self-hosted derrière une CA interne (`weebo.poc`).

**Non-objectifs**

- Intégration pull requests / issues dans `che-code` (pas d'équivalent de `che-github-authentication`) : RFC séparée si besoin.
- Signature de commits (gitsign / Sigstore) : traitée par le plan de durcissement, pas par Che.
- Refonte générique « N fournisseurs » du modèle SCM de Che : voir Alternatives.

## Architecture actuelle et points d'extension

Che intègre un fournisseur SCM à trois endroits : l'opérateur monte le Secret OAuth, che-server porte toute la logique (URL, devfile, tokens, `.gitconfig`), le dashboard affiche et saisit. DevWorkspace Operator ne voit que des Secrets génériques.

&#91;embedded content: parcours d'une URL Forgejo · 4 dépôts, 4 nouvelles classes che-server\]

Les quatre extensions che-server sont des multibinders Guice déjà en place : `FactoryParametersResolver`, `ScmFileResolver`, `PersonalAccessTokenFetcher` et `GitUserDataFetcher`, plus un provider `OAuthAuthenticator`. Ajouter Forgejo revient donc à fournir une implémentation de chacun, sans toucher au cœur. Le workspace clone ensuite directement depuis Forgejo avec le Secret `git-credential`.

## Conception — che-operator

L'opérateur reprend à l'identique le schéma GitLab : un Secret labellisé par instance, monté dans le pod che-server, avec des variables d'environnement suffixées pour la seconde instance.

**API** — `api/v2/checluster_types.go`

```go
type CheClusterGitServices struct {
	// ... github, gitlab, bitbucket, azure
	// Enables users to work with repositories hosted on Forgejo or Gitea (self-hosted or codeberg.org).
	// +optional
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Forgejo"
	Forgejo []ForgejoService `json:"forgejo,omitempty"`
}

// ForgejoService enables users to work with repositories hosted on Forgejo or Gitea.
type ForgejoService struct {
	// Kubernetes secret containing the Forgejo OAuth2 application client id and client secret.
	// The server endpoint is set with the `che.eclipse.org/scm-server-endpoint` annotation.
	// +kubebuilder:validation:Required
	SecretName string `json:"secretName"`
}
```

Pas de champ `Endpoint` : il est déprécié sur les autres fournisseurs au profit de l'annotation, et Forgejo n'a pas d'instance SaaS par défaut. L'annotation devient donc obligatoire.

**Constantes** — `pkg/common/constants/constants.go` : `ForgejoOAuth = "forgejo"`, `ForgejoOAuthConfigMountPath = "/che-conf/oauth/forgejo"`, fichiers `id` et `secret`.

**Montage** — `pkg/deploy/server/server_deployment.go` : nouvelle fonction `MountForgejoOAuthConfig`, appelée après `MountGitLabOAuthConfig`.

1. Sélectionne les Secrets `app.kubernetes.io/part-of: che.eclipse.org`, `app.kubernetes.io/component: oauth-scm-configuration`, annotés `che.eclipse.org/oauth-scm-server: forgejo`.
2. Trie par `che.eclipse.org/scm-server-endpoint` ; le premier sans suffixe, le second suffixé `__2`.
3. Monte le volume et exporte `CHE_OAUTH2_FORGEJO_CLIENTID__FILEPATH`, `CHE_OAUTH2_FORGEJO_CLIENTSECRET__FILEPATH` et `CHE_INTEGRATION_FORGEJO_OAUTH__ENDPOINT`.

**Validation** — `api/v2/checluster_webhook.go` : branche `forgejo` dans `validateOAuthSecret` (clés `id` et `secret`), refus si l'annotation d'endpoint manque, avertissement au-delà de deux Secrets.

**Génération** — régénérer CRD, bundle OLM et chart Helm, plus la page d'administration dans `che-docs`.

Exemple de Secret, alimenté depuis Vault par External Secrets :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: forgejo-oauth-config
  namespace: eclipse-che
  labels:
    app.kubernetes.io/part-of: che.eclipse.org
    app.kubernetes.io/component: oauth-scm-configuration
  annotations:
    che.eclipse.org/oauth-scm-server: forgejo
    che.eclipse.org/scm-server-endpoint: https://git.weebo.poc
type: Opaque
stringData:
  id: <client-id>
  secret: <client-secret>
```

## Conception — che-server

che-server reçoit quatre nouveaux modules Maven calqués sur GitLab, qui est le seul fournisseur self-hosted OAuth2 déjà géré en double instance. Le nom de fournisseur est `forgejo`, et `forgejo_2` pour la seconde instance.

**Modules**

| Module | Contenu |
| --- | --- |
| `wsmaster/che-core-api-factory-forgejo-common` | Client API, modèle d'URL, classes abstraites |
| `wsmaster/che-core-api-factory-forgejo` | Classes concrètes, variantes `Second`, `ForgejoModule` (Guice) |
| `wsmaster/che-core-api-auth-forgejo-common` | `ForgejoOAuthAuthenticator`, `ForgejoUser`, provider abstrait |
| `wsmaster/che-core-api-auth-forgejo` | Providers concrets et `Second`, module Guice OAuth |

**Classes du factory**

| Classe | Étend / implémente | Rôle |
| --- | --- | --- |
| `ForgejoApiClient` | — | Appels HTTP `/api/v1`, en-tête `Authorization: token <t>` |
| `ForgejoUrl` | `DefaultFactoryUrl` | Hôte, owner, repo, ref, emplacements du devfile |
| `AbstractForgejoUrlParser` | — | Reconnaît et découpe les URL Forgejo |
| `AbstractForgejoFactoryParametersResolver` | `BaseFactoryParameterResolver` | Résout le devfile d'une URL Forgejo |
| `ForgejoAuthorizingFileContentProvider` | `AuthorizingFileContentProvider<ForgejoUrl>` | Lit un fichier avec le token de l'utilisateur |
| `AbstractForgejoScmFileResolver` | `ScmFileResolver` | Endpoint `/api/scm/resolve` |
| `AbstractForgejoOAuthTokenFetcher` | `PersonalAccessTokenFetcher` | Récupère, rafraîchit et valide un token OAuth ou PAT |
| `AbstractForgejoUserDataFetcher` | `AbstractGitUserDataFetcher` | Nom et email pour `.gitconfig` |

**Formes d'URL à reconnaître**

- `https://<host>/<owner>/<repo>` et `…/<repo>.git`
- `…/src/branch/<branch>[/<path>]`, `…/src/tag/<tag>`, `…/src/commit/<sha>`
- `…/raw/branch/<branch>/<path>` (lien direct vers un devfile)
- `git@<host>:<owner>/<repo>.git` et `ssh://git@<host>[:port]/<owner>/<repo>.git`

**Appels API utilisés**

| Usage | Endpoint |
| --- | --- |
| Détection Forgejo vs Gitea | `GET /api/forgejo/v1/version`, repli `GET /api/v1/version` |
| Lecture du devfile | `GET /api/v1/repos/{owner}/{repo}/raw/{filepath}?ref=<ref>` |
| Validation du token et `.gitconfig` | `GET /api/v1/user` (`login`, `full_name`, `email`) |
| OAuth2 | `/login/oauth/authorize`, `/login/oauth/access_token` |

**Détection d'une URL** — `AbstractForgejoUrlParser.isValid()` accepte d'abord les hôtes des endpoints configurés. Pour un hôte inconnu, il ne sonde `/api/forgejo/v1/version` que si l'utilisateur possède déjà un Secret PAT `forgejo` pour cet hôte. Aucune requête sortante n'est donc déclenchée par une URL arbitraire.

**OAuth** — `ForgejoOAuthAuthenticator` étend `OAuthAuthenticator` (`getOAuthProvider()` renvoie `forgejo`, `getEndpointUrl()` l'endpoint configuré). Forgejo émet des refresh tokens : `refreshPersonalAccessToken` les exploite au lieu de forcer une nouvelle autorisation.

**Configuration** — `che.properties` reçoit six clés à `NULL` par défaut : `che.integration.forgejo.oauth_endpoint[_2]`, `che.oauth2.forgejo.clientid_filepath[_2]`, `che.oauth2.forgejo.clientsecret_filepath[_2]`.

**Câblage** — `WsMasterModule` : ajouter les deux resolvers au multibinder `FactoryParametersResolver`, les deux file resolvers au multibinder `ScmFileResolver`, puis `install(new ForgejoModule())` côté factory et côté OAuth. `ForgejoModule` alimente les multibinders `PersonalAccessTokenFetcher` et `GitUserDataFetcher`. Ajouter les dépendances dans `assembly-wsmaster-war/pom.xml`.

**Secrets PAT** — `KubernetesPersonalAccessTokenManager` est déjà agnostique : il suffit que `che.eclipse.org/scm-provider-name` vaille `forgejo` pour que `ScmPersonalAccessTokenFetcher` trouve un fetcher au lieu de lever `UnknownScmProviderException`.

## Conception — che-dashboard

Le dashboard demande deux types de changements : déclarer `forgejo` dans les unions de types, et remplacer la détection de fournisseur par hostname, qui ne peut pas fonctionner pour une forge self-hosted.

**Types et libellés**

| Fichier | Changement |
| --- | --- |
| `packages/common/src/dto/api/index.ts` | `GitOauthProvider` += `'forgejo' \| 'forgejo_2'` ; `GitProvider` += `'forgejo'` |
| `packages/dashboard-frontend/src/pages/UserPreferences/const.ts` | Entrées `Forgejo` et `Forgejo (The second provider)` dans `GIT_OAUTH_PROVIDERS` et `GIT_PROVIDERS` ; `GIT_PROVIDER_ENDPOINTS.forgejo = 'https://codeberg.org'` comme simple valeur par défaut |
| `packages/dashboard-frontend/src/pages/UserPreferences/GitServices/List/index.tsx` | Icône Forgejo ; pas d'ajout à `CAN_REVOKE_FROM_DASHBOARD` en v1 |
| `packages/dashboard-frontend/src/store/Workspaces/devWorkspaces/actions/actionCreators/helpers.ts` | Branche `forgejo` dans `getWarningFromResponse` |
| `packages/dashboard-backend/src/devworkspaceClient/services/personalAccessTokenApi/helpers.ts` | Accepter `forgejo` dans `che.eclipse.org/scm-provider-name` (sans organisation, comme GitHub) |

**Détection du fournisseur** — `ImportFromGit/helpers.ts` fait aujourd'hui `url.host.includes(p.split('-')[0])`. C'est le vrai bloquant : `git.weebo.poc` ne contient aucun nom de fournisseur.

1. Construire une table `hôte → fournisseur` à partir des endpoints déjà chargés dans le store `GitOauthConfig` (réponse de `/api/oauth`) et des `gitProviderEndpoint` des PAT de l'utilisateur.
2. `getSupportedGitService()` consulte cette table d'abord, puis garde l'heuristique par sous-chaîne comme repli.
3. Ajouter les cas `forgejo` dans `getRepositoryUrlFromLocation()` (couper à `/src/`) et `getBranchFromLocation()` (lire `src/branch/<branch>`).

Ce changement profite aussi à GitLab et GitHub Enterprise self-hosted, ce qui renforce l'argument upstream.

**Formulaire PAT** — l'endpoint est obligatoire pour `forgejo`, puisqu'il n'y a pas d'instance canonique. Le champ organisation reste réservé à Azure DevOps.

## DevWorkspace Operator et che-code

Aucun changement n'est requis dans DevWorkspace Operator. Les credentials git passent par des Secrets `controller.devfile.io/git-credential` que `KubernetesGitCredentialManager` génère côté che-server ; ce mécanisme est indépendant du fournisseur. Le `.gitconfig` suit le même chemin via `GitUserDataFetcher`.

`che-code` ne contient qu'une extension spécifique à un fournisseur, `che-github-authentication`. Forgejo n'en a pas besoin pour cloner, pousser ou tirer. Une extension équivalente (session VS Code `forgejo` alimentée par le token Che) relève d'une RFC ultérieure et pourrait vivre dans Batlehub.

## Sécurité

Le modèle de menace ne change pas par rapport à GitLab self-hosted ; les points ci-dessous fixent les choix propres à Forgejo.

- **Application OAuth2** : client confidentiel créé au niveau instance dans Forgejo, redirect URI `https://<che-host>/api/oauth/callback`. Le client secret vient de Vault via External Secrets, jamais du dépôt GitOps.
- **Scopes** : demander le minimum, soit `read:user` et `write:repository`. Le niveau de prise en compte des scopes sur les tokens OAuth2 par la version de Forgejo déployée est à vérifier (voir Questions ouvertes).
- **Stockage des tokens** : inchangé, un Secret `personal-access-token-*` dans le namespace de l'utilisateur. L'isolation est-ouest déjà en place entre namespaces Che couvre ce stockage.
- **Requêtes sortantes** : che-server ne sonde que les endpoints configurés ou les hôtes pour lesquels l'utilisateur a déjà un PAT, ce qui ferme la porte à un SSRF via une URL de factory.
- **CA interne** : `ForgejoApiClient` utilise le truststore JVM par défaut, déjà alimenté par l'opérateur à partir du ConfigMap `ca-certs` ; aucune option « skip TLS » n'est exposée.
- **Journaux** : jamais de token dans les logs ni dans les messages d'erreur renvoyés au dashboard.

## Stratégie de tests

Chaque dépôt teste sa part isolément, puis un e2e unique valide le parcours complet sur une vraie instance Forgejo.

| Niveau | Dépôt | Contenu |
| --- | --- | --- |
| Unitaire | che-server | `AbstractForgejoUrlParser` sur toutes les formes d'URL ; resolvers et fetchers avec WireMock (réponses `/api/v1/user`, `/raw`, 401, 404) |
| Unitaire | che-operator | `MountForgejoOAuthConfig` avec 0, 1 et 2 Secrets ; webhook : clés manquantes, annotation manquante |
| Unitaire | che-dashboard | Détection par table d'endpoints, extraction repo et branche, types PAT |
| Intégration | che-server | Forgejo en Testcontainers (`codeberg.org/forgejo/forgejo`), flux OAuth complet et refresh |
| e2e | che-e2e | Import d'un dépôt privé Forgejo, connexion OAuth depuis *User Preferences*, `git push` depuis le workspace |

Le cas d'une instance derrière une CA privée est couvert en e2e sur weebo-si avant l'ouverture des PR upstream.

## Plan de livraison

La livraison se fait en cinq PR upstream, précédées d'une issue sur `eclipse-che/che` pour valider l'approche avec les mainteneurs. En attendant la fusion, weebo-si tourne sur des images forkées publiées dans Batlehub.

1. **Issue upstream** sur `eclipse-che/che` : lien vers cette RFC, demande d'accord sur le nom `forgejo` et sur le périmètre Gitea.
2. **PR dashboard — détection par endpoint** : indépendante de Forgejo, utile tout de suite pour GitLab et GitHub self-hosted. C'est la PR la plus facile à faire accepter en premier.
3. **PR che-operator** : API, montage, webhook, CRD régénérée. Sans effet tant que che-server ignore les variables.
4. **PR che-server** : les quatre modules, le câblage et les tests. C'est la plus grosse, et elle dépend de 3 pour l'e2e.
5. **PR dashboard — Forgejo** : types, libellés, icône, formulaire PAT. Dépend de 4.
6. **PR che-docs** : page « Configuring OAuth 2.0 for Forgejo », calquée sur celle de GitLab.

Côté Dev Spaces, rien à faire : le build downstream récupère les changements à la version suivante de Che.

## Alternatives considérées

| Alternative | Pourquoi elle est écartée |
| --- | --- |
| Rester sur des Secrets PAT génériques créés par ESO | Clone OK, mais pas de devfile privé, pas de détection dashboard, pas d'OAuth |
| Déclarer Forgejo comme un GitHub Enterprise | L'API REST diffère (`/api/v1` vs `/api/v3`, formes d'URL) : casse à la première requête |
| Fournisseur générique configurable (N instances, gabarits d'URL) | Refonte de tout le modèle SCM de Che ; peu de chances d'être acceptée upstream en une fois |
| Fournisseur nommé `gitea` | Même code, mais Forgejo est la cible réelle ; `/api/forgejo/v1/version` permet de gérer les deux sous un seul nom |
| Support dans un fork weebo-si uniquement | Coût de rebase à chaque version de Che, et aucun bénéfice pour la communauté |

## Questions ouvertes

- [ ] Nom du fournisseur : `forgejo` seul, ou alias `gitea` accepté par l'opérateur et le serveur ?
- [ ] Limiter à deux instances comme GitLab (`forgejo`, `forgejo_2`), ou profiter de ce fournisseur pour introduire N instances ?
- [ ] Les scopes OAuth2 sont-ils appliqués aux tokens OAuth par la version de Forgejo déployée sur weebo-si, ou le token a-t-il un accès complet ?
- [ ] Révocation depuis le dashboard : Forgejo expose-t-il un endpoint de révocation de token OAuth utilisable par che-server ?
- [ ] Reconnaissance des URL SSH : utiliser le port SSH annoncé par `/api/v1/settings/repository` ou exiger une annotation dédiée ?
- [ ] Nom d'utilisateur dans le Secret `git-credential` généré par `KubernetesGitCredentialManager` : utiliser le `login` renvoyé par `GET /api/v1/user` plutôt qu'une valeur fixe (`oauth2`), et vérifier que Forgejo accepte ce couple pour un token OAuth comme pour un PAT.

## Sources

- [eclipse-che/che-server](https://github.com/eclipse-che/che-server) — modules `wsmaster/che-core-api-factory-gitlab*` et `che-core-api-auth-gitlab*`, `WsMasterModule`, `KubernetesPersonalAccessTokenManager`
- [eclipse-che/che-operator](https://github.com/eclipse-che/che-operator) — `api/v2/checluster_types.go`, `pkg/deploy/server/server_deployment.go`, `api/v2/checluster_webhook.go`
- [eclipse-che/che-dashboard](https://github.com/eclipse-che/che-dashboard) — `packages/common/src/dto/api/index.ts`, `ImportFromGit/helpers.ts`, `UserPreferences/const.ts`
- [che-incubator/che-code](https://github.com/che-incubator/che-code) — `code/extensions/che-github-authentication`
