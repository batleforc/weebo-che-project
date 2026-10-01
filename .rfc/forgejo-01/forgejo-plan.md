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
- [ ] Image publishing: [`weebo-si/che-images`](https://github.com/weebo-si/che-images) builds `che-server`, `che-operator`, `che-dashboard` from the weebo-si forks and pushes them to `ghcr.io/weebo-si/<image>`, signed with cosign keyless.
  - Changed from Forgejo Actions + internal registry: the forks live on GitHub, so GitHub Actions + GHCR avoids mirroring them.
  - [x] Repo created from the `batleforc/weebo-base` template; matrix workflow (nightly, manual, on workflow change), actions pinned to SHAs, no build cache.
  - [x] Tags: `feat-forgejo-gitservice` and `sha-<short>` of the fork commit.
  - [ ] First green run (`task images:build` then `task images:watch`).
  - [ ] GHCR packages set to public (they start private), or a pull secret on the cluster.

**Done when:** a stock Che instance runs with overridden images and the Forgejo test repo is reachable from a workspace.

---

## Phase 1 — `che-dashboard`: endpoint-based provider detection

Standalone refactor, useful for any self-hosted GitHub/GitLab. Ships first to build trust upstream.

### Tasks

- [x] `packages/dashboard-frontend/src/components/ImportFromGit/helpers.ts`
  - [x] Add `buildProviderByHost(gitOauth: IGitOauth[], tokens: api.PersonalAccessToken[]): Map<string, api.GitProvider>`.
  - [x] `getSupportedGitService(location, providerByHost?)`: lookup by `url.host` first, keep the substring heuristic as fallback.
  - [x] Thread the map through `getRepositoryUrlFromLocation()` and `getBranchFromLocation()`.
- [x] Selector in `store/GitOauthConfig` exposing the host → provider map (endpoints from `/api/oauth`).
- [x] Wire callers (Import from Git form, factory flow) to pass the map.
  - Only caller is `ImportFromGit/RepoOptionsAccordion`; the factory flow does not use these helpers. The accordion now loads `/api/oauth` and the user PATs on mount.

### Tests

- [x] `git.example.internal` configured as GitLab endpoint → detected as `gitlab`.
- [x] Host matched by both table and heuristic → table wins.
- [x] Unknown host, no config → unchanged behaviour (error).

**Done when:** importing from a self-hosted GitLab whose host does not contain `gitlab` works; existing tests green.

---

## Phase 2 — `che-operator`: API and OAuth secret mounting

### Tasks

- [x] `api/v2/checluster_types.go`
  - [x] Add `Forgejo []ForgejoService \`json:"forgejo,omitempty"\`` to `CheClusterGitServices`.
  - [x] Add `ForgejoService { SecretName string }` (no `Endpoint` field).
- [x] `pkg/common/constants/constants.go`
  - [x] `ForgejoOAuth = "forgejo"`
  - [x] `ForgejoOAuthConfigMountPath = "/che-conf/oauth/forgejo"`
  - [x] `ForgejoOAuthConfigClientIdFileName = "id"`, `ForgejoOAuthConfigClientSecretFileName = "secret"`
- [x] `pkg/deploy/server/server_deployment.go`
  - [x] `MountForgejoOAuthConfig()` copied from `MountGitLabOAuthConfig()`; secrets sorted by `che.eclipse.org/scm-server-endpoint`, second one suffixed `__2`.
  - [x] Env: `CHE_OAUTH2_FORGEJO_CLIENTID__FILEPATH`, `CHE_OAUTH2_FORGEJO_CLIENTSECRET__FILEPATH`, `CHE_INTEGRATION_FORGEJO_OAUTH__ENDPOINT` (+ `__2` variants).
  - [x] Call it right after `MountGitLabOAuthConfig()`.
- [x] `api/v2/checluster_webhook.go`
  - [x] Loop over `Spec.GitServices.Forgejo` in `validate()`.
  - [x] `case "forgejo"` in `validateOAuthSecret()` → required keys `id`, `secret`.
  - [x] Reject when `che.eclipse.org/scm-server-endpoint` is missing.
  - [x] Warning when more than two Forgejo secrets exist.
- [x] Regenerate CRD, deepcopy, OLM bundle and Helm chart (`make update-dev-resources`).
  - Ran `generate manifests`, `bundle CHANNEL=next INCREMENT_BUNDLE_VERSION=false`, `gen-deployment`, `update-helmcharts CHANNEL=next` individually (skips the unrelated UBI bump; needs kislyuk `yq` and `rsync`).
- Note: `ForgejoMaxOAuthConfigs = 2`: all secrets are still mounted (`__3`…) like GitLab; the webhook only warns.
- Note: v1 API (`api/v1`) intentionally not extended, same as Azure DevOps.

### Tests

- [x] `server_deployment_test.go`: 0, 1, 2 secrets → expected volumes, mounts and env vars.
- [x] Webhook tests: missing keys, missing endpoint annotation, valid secret.

**Done when:** applying the Forgejo OAuth secret makes the env vars appear on the `che` deployment; CRD diff limited to the new field.

---

## Phase 3 — `che-server`: Forgejo modules

Largest phase. Mirror the GitLab layout file by file.

### 3.1 Module skeletons

- [x] `wsmaster/che-core-api-factory-forgejo-common`
- [x] `wsmaster/che-core-api-factory-forgejo`
- [x] `wsmaster/che-core-api-auth-forgejo-common`
- [x] `wsmaster/che-core-api-auth-forgejo`
- [x] Register in `wsmaster/pom.xml`, root `pom.xml` (dependencyManagement), `assembly/assembly-wsmaster-war/pom.xml`.

### 3.2 API client & URL model (`factory-forgejo-common`)

- [x] `ForgejoApiClient`
  - [x] `getUser(token)` → `GET /api/v1/user` (`login`, `full_name`, `email`)
  - [x] `getFileContent(owner, repo, path, ref, token?)` → `GET /api/v1/repos/{owner}/{repo}/raw/{path}?ref=`
  - [x] `isForgejoServer()` → `GET /api/forgejo/v1/version`, fallback `GET /api/v1/version`
  - [x] Header `Authorization: token <t>`; 401 → `ScmUnauthorizedException("forgejo", …)`; 404 → `ScmItemNotFoundException`.
  - [x] Default JVM truststore only, no TLS bypass; tokens never logged.
- [x] `ForgejoUrl extends DefaultFactoryUrl` (host, owner, repo, branch/tag/commit, devfile locations).
- [x] `AbstractForgejoUrlParser`
  - [x] HTTPS forms: `/<owner>/<repo>[.git]`, `/src/branch/<b>`, `/src/tag/<t>`, `/src/commit/<sha>[/<path>]`.
    - Branch/tag names may contain `/`: a multi-segment `/src/branch|tag/<ref>[/<path>]` is resolved at parse time via `GET /api/v1/repos/{o}/{r}/branches|tags/{ref}` (shortest prefix first as Forgejo does, max 5 calls, user token if any, path ignored); on no match/API failure the whole rest is the ref. `/raw/branch/...` still unsupported.
  - [x] SSH forms: `git@<host>:<owner>/<repo>.git`, `ssh://git@<host>[:port]/<owner>/<repo>.git`.
  - [x] `isValid()`: configured endpoints first; unknown host probed **only** if the user has a `forgejo` PAT secret for that host.
- [x] `ForgejoAuthorizingFileContentProvider extends AuthorizingFileContentProvider<ForgejoUrl>`
- [x] `AbstractForgejoFactoryParametersResolver extends BaseFactoryParameterResolver`
- [x] `AbstractForgejoScmFileResolver implements ScmFileResolver`
- [x] `AbstractForgejoOAuthTokenFetcher implements PersonalAccessTokenFetcher` (fetch, refresh via refresh token, `isValid` via `/api/v1/user`).
- [x] `AbstractForgejoUserDataFetcher extends AbstractGitUserDataFetcher`

### 3.3 Concrete classes (`factory-forgejo`)

- [x] `Forgejo*` + `Forgejo*Second` for each abstract class, bound to `che.integration.forgejo.oauth_endpoint` / `_2`.
- [x] `ForgejoModule`: multibinders `PersonalAccessTokenFetcher`, `GitUserDataFetcher`.

### 3.4 OAuth (`auth-forgejo-common`, `auth-forgejo`)

- [x] `ForgejoOAuthAuthenticator extends OAuthAuthenticator`
  - [x] `getOAuthProvider()` → `forgejo` / `forgejo_2`; `getEndpointUrl()` → configured endpoint.
  - [x] Authorize `/login/oauth/authorize`, token `/login/oauth/access_token`, scopes `read:user write:repository`.
- [x] `ForgejoUser implements User`
- [x] `AbstractForgejoOAuthAuthenticatorProvider` (+ `NoopOAuthAuthenticator` when unconfigured), concrete + `Second`.
- [x] Auth-side `ForgejoModule`.

### 3.5 Wiring & config

- [x] `WsMasterModule`: resolvers into `FactoryParametersResolver` multibinder, file resolvers into `ScmFileResolver` multibinder, `install()` both Forgejo modules.
  - Forgejo resolvers are bound **first**: the GitHub parser accepts any server whose `/api/v1/user` returns 401 (Gitea-compatible detection), Forgejo included, and ties are won by the first bound resolver. To discuss upstream (see open questions).
- [x] `che.properties`: `che.integration.forgejo.oauth_endpoint[_2]`, `che.oauth2.forgejo.clientid_filepath[_2]`, `che.oauth2.forgejo.clientsecret_filepath[_2]`, all `NULL`.
- [x] `KubernetesGitCredentialManager`: no change needed — PATs already use `scmUserName` (= Forgejo `login`), OAuth tokens use `oauth2:<token>`, which Forgejo accepts (the password is used as the token). To confirm against a live instance.

### Tests

- [x] Unit: URL parser table-driven over every URL form; resolvers/fetchers with WireMock (200, 401, 404, refresh).
- [ ] Integration: Testcontainers `codeberg.org/forgejo/forgejo`, full OAuth flow + refresh, private devfile resolution. (No container runtime in the dev workspace.)

**Done when:** a private Forgejo repo URL starts a workspace with devfile resolved, OAuth connect works, `.gitconfig` filled, `git push` succeeds.

---

## Phase 4 — `che-dashboard`: Forgejo provider

### Tasks

- [x] `packages/common/src/dto/api/index.ts`: `GitOauthProvider += 'forgejo' | 'forgejo_2'`, `GitProvider += 'forgejo'`.
- [x] `pages/UserPreferences/const.ts`: labels, `GIT_PROVIDER_ENDPOINTS.forgejo = ''`.
  - Changed from `https://codeberg.org`: the endpoint field is pre-filled with the default, so a self-hosted token would silently be saved against Codeberg.
- [x] `pages/UserPreferences/GitServices/List/index.tsx`: **not** added to `CAN_REVOKE_FROM_DASHBOARD` (the existing tooltip links to the Forgejo instance for manual revocation). No icon: the list has none for any provider.
- [x] PAT form: endpoint required for `forgejo` (form invalid while the endpoint is empty).
- [x] `ImportFromGit/helpers.ts`: `forgejo` cases in `getRepositoryUrlFromLocation()` (cut at `/src/`) and `getBranchFromLocation()` (`src/branch/<b>`).
- [x] `store/.../actionCreators/helpers.ts`: `forgejo` branch in `getWarningFromResponse()`.
- [x] `dashboard-backend/.../personalAccessTokenApi/helpers.ts`: accept `forgejo` provider name (type-driven, no code change; test added).
- [x] ~~Forgejo logo asset~~: not needed, the dashboard shows no provider logos.

### Tests

- [x] Unit: provider detection, repo/branch extraction, PAT creation payload.
- [ ] Manual: User Preferences → Git Services shows Forgejo; PAT add/delete. (Needs the Phase 0 dev instance.)

**Done when:** full user journey works from the dashboard against Forgejo, with no manual secret.

---

## Phase 5 — Documentation (`che-docs`)

- [x] Admin guide: "Configuring OAuth 2.0 for Forgejo" (application creation, secret YAML, annotations).
  - `integrate/pages/configuring-oauth-2-for-forgejo.adoc` + 2 partials, nav, Git providers overview, "what to configure next", troubleshooting (redirect URI, mandatory endpoint annotation, 2-secret limit).
- [x] User guide: Forgejo in "Using a Git provider access token" and supported URL formats.
- [x] `CheCluster` reference: `spec.gitServices.forgejo` (`tools/checluster_docs_gen.sh` section + TOC entry; the table is generated from the operator CRD).

**Merge order:** the generator fetches the CRD of the operator release branch matching the docs version and fails on a missing section (verified: exit 5 against the current upstream CRD). Merge this PR only once a `che-operator` release contains `spec.gitServices.forgejo`.

**Verified:** local Antora build (without collector/htmltest, reference generated from the forked operator CRD): no new error or warning.

---

## Phase 6 — weebo-si rollout

- [ ] Forgejo OAuth2 application created at instance level; client id/secret stored in Vault.
- [ ] `ExternalSecret` producing `forgejo-oauth-config` in `eclipse-che` with the labels/annotations from the RFC.
- [ ] `CheCluster` (GitOps): `spec.gitServices.forgejo: [{secretName: forgejo-oauth-config}]` + forked image overrides (`ghcr.io/weebo-si/che-server`, `ghcr.io/weebo-si/che-dashboard`; `ghcr.io/weebo-si/che-operator` on the operator Deployment).
- [ ] Kyverno / admission: allow `ghcr.io/weebo-si/*` and verify the cosign signature (identity `https://github.com/weebo-si/che-images/.github/workflows/build.yml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com`).
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
- [ ] GitHub resolver claims Gitea/Forgejo servers (`AbstractGithubURLParser#isGiteaCompatibleServer`): keep Forgejo-first ordering, or exclude configured Forgejo hosts from the GitHub detection?
- [ ] Token revocation: Forgejo has no OAuth revoke endpoint; `ForgejoOAuthAuthenticator#invalidateToken` only drops the token on the Che side (it stays valid on Forgejo until it expires or the app is revoked in the Forgejo settings).