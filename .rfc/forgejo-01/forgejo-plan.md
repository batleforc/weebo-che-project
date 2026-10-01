# Implementation plan — Native Forgejo support in Eclipse Che gitServices

- **Author:** Maxime (maxleriche.60@gmail.com)
- **Status:** Draft
- **Related RFC:** RFC — Support natif de Forgejo dans les gitServices d'Eclipse Che / Dev Spaces
- **Target:** upstream Eclipse Che (Dev Spaces inherits through the downstream build)

## 0. Overview

| # | Phase | Repository | Depends on | Upstream PR |
|---|-------|------------|------------|-------------|
| 0 | Dev environment & upstream issue | — | — | Issue on `eclipse-che/che` |
| 1 | Endpoint-based provider detection | `che-dashboard` | — | Yes (standalone) |
| 2 | `CheCluster` API + OAuth secret mounting | `che-operator` | — | Yes |
| 3 | Forgejo factory + OAuth modules | `che-server` | 2 (for e2e only) | Yes |
| 4 | Forgejo provider in the UI | `che-dashboard` | 1, 3 | Yes |
| 5 | Documentation | `che-docs` | 2, 3, 4 | Yes |
| 6 | weebo-si rollout (forked images) | weebo-si GitOps | 2, 3, 4 | No |

Phases 1, 2 and 3 can run in parallel. DevWorkspace Operator and `che-code` are **not** modified.

---

## Phase 0 — Dev environment & upstream alignment

- [ ] Open an issue on `eclipse-che/che` linking the RFC; ask maintainers to confirm:
  - provider name `forgejo` (Gitea covered under the same name),
  - two-instance limit (`forgejo`, `forgejo_2`) mirroring GitLab.
- [ ] Fork `che-server`, `che-operator`, `che-dashboard`, `che-docs` under `batleforc`; branch `feat/forgejo-gitservice` everywhere.
- [ ] Local Forgejo for development:
  ```bash
  podman run -d --name forgejo -p 3000:3000 -p 2222:22 codeberg.org/forgejo/forgejo:<version>
  ```
  - Create an admin user, a private repo `test/devfile-sample` with a `devfile.yaml`, an OAuth2 application (redirect `https://<che-host>/api/oauth/callback`) and a scoped PAT.
- [ ] Dev Che instance: a dedicated `CheCluster` on a throwaway namespace of the Talos cluster, images overridden via `spec.components.*.deployment.containers[].image`.
- [ ] Image publishing: build pipeline in Forgejo Actions pushing `che-server`, `che-operator`, `che-dashboard` dev images to the internal registry, signed with Sigstore.

**Done when:** a stock Che instance runs with overridden images and the Forgejo test repo is reachable from a workspace.

---

## Phase 1 — `che-dashboard`: endpoint-based provider detection

Standalone refactor, useful for any self-hosted GitHub/GitLab. Ships first to build trust upstream.

### Tasks

- [ ] `packages/dashboard-frontend/src/components/ImportFromGit/helpers.ts`
  - [ ] Add `buildProviderByHost(gitOauth: IGitOauth[], tokens: api.PersonalAccessToken[]): Map<string, api.GitProvider>`.
  - [ ] `getSupportedGitService(location, providerByHost?)`: lookup by `url.host` first, keep the substring heuristic as fallback.
  - [ ] Thread the map through `getRepositoryUrlFromLocation()` and `getBranchFromLocation()`.
- [ ] Selector in `store/GitOauthConfig` exposing the host → provider map (endpoints from `/api/oauth`).
- [ ] Wire callers (Import from Git form, factory flow) to pass the map.

### Tests

- [ ] `git.example.internal` configured as GitLab endpoint → detected as `gitlab`.
- [ ] Host matched by both table and heuristic → table wins.
- [ ] Unknown host, no config → unchanged behaviour (error).

**Done when:** importing from a self-hosted GitLab whose host does not contain `gitlab` works; existing tests green.

---

## Phase 2 — `che-operator`: API and OAuth secret mounting

### Tasks

- [ ] `api/v2/checluster_types.go`
  - [ ] Add `Forgejo []ForgejoService \`json:"forgejo,omitempty"\`` to `CheClusterGitServices`.
  - [ ] Add `ForgejoService { SecretName string }` (no `Endpoint` field).
- [ ] `pkg/common/constants/constants.go`
  - [ ] `ForgejoOAuth = "forgejo"`
  - [ ] `ForgejoOAuthConfigMountPath = "/che-conf/oauth/forgejo"`
  - [ ] `ForgejoOAuthConfigClientIdFileName = "id"`, `ForgejoOAuthConfigClientSecretFileName = "secret"`
- [ ] `pkg/deploy/server/server_deployment.go`
  - [ ] `MountForgejoOAuthConfig()` copied from `MountGitLabOAuthConfig()`; secrets sorted by `che.eclipse.org/scm-server-endpoint`, second one suffixed `__2`.
  - [ ] Env: `CHE_OAUTH2_FORGEJO_CLIENTID__FILEPATH`, `CHE_OAUTH2_FORGEJO_CLIENTSECRET__FILEPATH`, `CHE_INTEGRATION_FORGEJO_OAUTH__ENDPOINT` (+ `__2` variants).
  - [ ] Call it right after `MountGitLabOAuthConfig()`.
- [ ] `api/v2/checluster_webhook.go`
  - [ ] Loop over `Spec.GitServices.Forgejo` in `validate()`.
  - [ ] `case "forgejo"` in `validateOAuthSecret()` → required keys `id`, `secret`.
  - [ ] Reject when `che.eclipse.org/scm-server-endpoint` is missing.
  - [ ] Warning when more than two Forgejo secrets exist.
- [ ] Regenerate CRD, deepcopy, OLM bundle and Helm chart (`make update-dev-resources`).

### Tests

- [ ] `server_deployment_test.go`: 0, 1, 2 secrets → expected volumes, mounts and env vars.
- [ ] Webhook tests: missing keys, missing endpoint annotation, valid secret.

**Done when:** applying the Forgejo OAuth secret makes the env vars appear on the `che` deployment; CRD diff limited to the new field.

---

## Phase 3 — `che-server`: Forgejo modules

Largest phase. Mirror the GitLab layout file by file.

### 3.1 Module skeletons

- [ ] `wsmaster/che-core-api-factory-forgejo-common`
- [ ] `wsmaster/che-core-api-factory-forgejo`
- [ ] `wsmaster/che-core-api-auth-forgejo-common`
- [ ] `wsmaster/che-core-api-auth-forgejo`
- [ ] Register in `wsmaster/pom.xml`, root `pom.xml` (dependencyManagement), `assembly/assembly-wsmaster-war/pom.xml`.

### 3.2 API client & URL model (`factory-forgejo-common`)

- [ ] `ForgejoApiClient`
  - [ ] `getUser(token)` → `GET /api/v1/user` (`login`, `full_name`, `email`)
  - [ ] `getFileContent(owner, repo, path, ref, token?)` → `GET /api/v1/repos/{owner}/{repo}/raw/{path}?ref=`
  - [ ] `isForgejoServer()` → `GET /api/forgejo/v1/version`, fallback `GET /api/v1/version`
  - [ ] Header `Authorization: token <t>`; 401 → `ScmUnauthorizedException("forgejo", …)`; 404 → `ScmItemNotFoundException`.
  - [ ] Default JVM truststore only, no TLS bypass; tokens never logged.
- [ ] `ForgejoUrl extends DefaultFactoryUrl` (host, owner, repo, branch/tag/commit, devfile locations).
- [ ] `AbstractForgejoUrlParser`
  - [ ] HTTPS forms: `/<owner>/<repo>[.git]`, `/src/branch/<b>[/<path>]`, `/src/tag/<t>`, `/src/commit/<sha>`, `/raw/branch/<b>/<path>`.
  - [ ] SSH forms: `git@<host>:<owner>/<repo>.git`, `ssh://git@<host>[:port]/<owner>/<repo>.git`.
  - [ ] `isValid()`: configured endpoints first; unknown host probed **only** if the user has a `forgejo` PAT secret for that host.
- [ ] `ForgejoAuthorizingFileContentProvider extends AuthorizingFileContentProvider<ForgejoUrl>`
- [ ] `AbstractForgejoFactoryParametersResolver extends BaseFactoryParameterResolver`
- [ ] `AbstractForgejoScmFileResolver implements ScmFileResolver`
- [ ] `AbstractForgejoOAuthTokenFetcher implements PersonalAccessTokenFetcher` (fetch, refresh via refresh token, `isValid` via `/api/v1/user`).
- [ ] `AbstractForgejoUserDataFetcher extends AbstractGitUserDataFetcher`

### 3.3 Concrete classes (`factory-forgejo`)

- [ ] `Forgejo*` + `Forgejo*Second` for each abstract class, bound to `che.integration.forgejo.oauth_endpoint` / `_2`.
- [ ] `ForgejoModule`: multibinders `PersonalAccessTokenFetcher`, `GitUserDataFetcher`.

### 3.4 OAuth (`auth-forgejo-common`, `auth-forgejo`)

- [ ] `ForgejoOAuthAuthenticator extends OAuthAuthenticator`
  - [ ] `getOAuthProvider()` → `forgejo` / `forgejo_2`; `getEndpointUrl()` → configured endpoint.
  - [ ] Authorize `/login/oauth/authorize`, token `/login/oauth/access_token`, scopes `read:user write:repository`.
- [ ] `ForgejoUser implements User`
- [ ] `AbstractForgejoOAuthAuthenticatorProvider` (+ `NoopOAuthAuthenticator` when unconfigured), concrete + `Second`.
- [ ] Auth-side `ForgejoModule`.

### 3.5 Wiring & config

- [ ] `WsMasterModule`: resolvers into `FactoryParametersResolver` multibinder, file resolvers into `ScmFileResolver` multibinder, `install()` both Forgejo modules.
- [ ] `che.properties`: `che.integration.forgejo.oauth_endpoint[_2]`, `che.oauth2.forgejo.clientid_filepath[_2]`, `che.oauth2.forgejo.clientsecret_filepath[_2]`, all `NULL`.
- [ ] `KubernetesGitCredentialManager`: use the Forgejo `login` as username (see RFC open question).

### Tests

- [ ] Unit: URL parser table-driven over every URL form; resolvers/fetchers with WireMock (200, 401, 404, refresh).
- [ ] Integration: Testcontainers `codeberg.org/forgejo/forgejo`, full OAuth flow + refresh, private devfile resolution.

**Done when:** a private Forgejo repo URL starts a workspace with devfile resolved, OAuth connect works, `.gitconfig` filled, `git push` succeeds.

---

## Phase 4 — `che-dashboard`: Forgejo provider

### Tasks

- [ ] `packages/common/src/dto/api/index.ts`: `GitOauthProvider += 'forgejo' | 'forgejo_2'`, `GitProvider += 'forgejo'`.
- [ ] `pages/UserPreferences/const.ts`: labels, `GIT_PROVIDER_ENDPOINTS.forgejo = 'https://codeberg.org'`.
- [ ] `pages/UserPreferences/GitServices/List/index.tsx`: icon; **not** added to `CAN_REVOKE_FROM_DASHBOARD`.
- [ ] PAT form: endpoint required for `forgejo`.
- [ ] `ImportFromGit/helpers.ts`: `forgejo` cases in `getRepositoryUrlFromLocation()` (cut at `/src/`) and `getBranchFromLocation()` (`src/branch/<b>`).
- [ ] `store/.../actionCreators/helpers.ts`: `forgejo` branch in `getWarningFromResponse()`.
- [ ] `dashboard-backend/.../personalAccessTokenApi/helpers.ts`: accept `forgejo` provider name.
- [ ] Forgejo logo asset (check CC BY-SA 4.0 attribution requirements).

### Tests

- [ ] Unit: provider detection, repo/branch extraction, PAT creation payload.
- [ ] Manual: User Preferences → Git Services shows Forgejo; PAT add/delete.

**Done when:** full user journey works from the dashboard against Forgejo, with no manual secret.

---

## Phase 5 — Documentation (`che-docs`)

- [ ] Admin guide: "Configuring OAuth 2.0 for Forgejo" (application creation, secret YAML, annotations).
- [ ] User guide: Forgejo in "Using a Git provider access token" and supported URL formats.
- [ ] `CheCluster` reference: `spec.gitServices.forgejo`.

---

## Phase 6 — weebo-si rollout

- [ ] Forgejo OAuth2 application created at instance level; client id/secret stored in Vault.
- [ ] `ExternalSecret` producing `forgejo-oauth-config` in `eclipse-che` with the labels/annotations from the RFC.
- [ ] `CheCluster` (GitOps): `spec.gitServices.forgejo: [{secretName: forgejo-oauth-config}]` + forked image overrides.
- [ ] Kyverno / admission: allow the forked image references.
- [ ] Remove the manual `git-credential` secrets once OAuth is validated.
- [ ] Switch back to upstream images when the PRs ship in a Che release.

---

## Upstream PR order

1. `che-dashboard` — endpoint-based detection (Phase 1)
2. `che-operator` — API + mounting (Phase 2)
3. `che-server` — Forgejo modules (Phase 3)
4. `che-dashboard` — Forgejo provider (Phase 4)
5. `che-docs` (Phase 5)

## Open questions carried from the RFC

- [ ] `forgejo` only, or a `gitea` alias?
- [ ] Two instances max, or N?
- [ ] OAuth2 scope enforcement on the deployed Forgejo version.
- [ ] Token revocation endpoint for dashboard revoke.
- [ ] SSH port discovery: `/api/v1/settings/repository` vs dedicated annotation.
- [ ] Username written in the `git-credential` secret.