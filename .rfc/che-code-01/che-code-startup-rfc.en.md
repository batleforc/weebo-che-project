# RFC — Speed up che-code startup: conditional copy in the init container

Oct 6, 2026 · @Maxime · Status: Implemented (`weebo-si/che-code`, `develop`), upstream PR to open

## Summary

On every VS Code workspace start, the `che-code-injector` init container copies the whole content of the che-code image (three assemblies: musl, ubi8, ubi9) into the `checode` volume. This volume is persistent, so the same copy is redone on every boot.

This RFC makes the copy conditional. The image carries a version key (`<VS Code version>-<content hash>`), the volume keeps the key of what it contains, and the init container only copies the assemblies when the two differ. The files the launcher patches in place on every boot, the entrypoints and the Machine settings are still copied on every start, which keeps the current behavior.

The change touches two files in `che-code`: `build/scripts/entrypoint-init-container.sh` and `build/dockerfiles/assembly.Dockerfile`. It is developed on the `weebo-si/che-code` fork, merged into our `develop`, then proposed upstream to `che-incubator/che-code`.

It is the first axis of a broader effort that targets a VS Code second boot under 40 s (see [Goals](#goals-and-non-goals)).

## Context and motivation

### Current measurements

| IDE | First boot | Second boot |
|---|---|---|
| IntelliJ (JetBrains Gateway) | 3 min 18 s (including 35 s to download the IDE, plus 30 s to download extensions before startup) | 37 s (excluding Gateway connection time) |
| VS Code (che-code) | 1 min 54 s | 1 min 36 s, image cached or not |

The VS Code second boot barely benefits from the persistent volume. The time does not depend on the image pull (1 min 36 s in both cases).

Detailed per-step measurements, before and after this RFC, are in the [Measurements](#measurements) section. On the second boot, with the upstream image, the init container takes 31 to 60 s depending on its memory limit, which is most of the startup time.

### What the init container does today

`build/scripts/entrypoint-init-container.sh`:

```sh
cp -r /checode-* /checode/          # the 3 assemblies, with node and machine-exec
cp /entrypoint-volume.sh /checode/
mkdir -p /checode/remote
cp -r /remote /checode              # remote/data/Machine/settings.json
ls -la /checode
```

The `checode` volume is declared `volume: {}` in the editor definition. It is not ephemeral: with the `per-user` and `per-workspace` storage strategies, it lives on a PVC (one subpath per workspace) and persists between boots. With the `ephemeral` strategy, it is an `emptyDir`.

`entrypoint-volume.sh` uses only one of the three assemblies, chosen from the libc and OpenSSL version of the dev container. It exports `VSCODE_AGENT_FOLDER=/checode/remote`, which holds the user data: User and Machine settings, installed extensions, globalStorage.

### The JetBrains precedent

The JetBrains init container (`che-incubator/jetbrains-ide-dev-server`, `build/scripts/entrypoint-init-container.sh`) writes the IDE download URL to `.ide-download-complete` and skips the download when it has not changed. This is what brings its second boot from 3 min 18 s down to 37 s. This RFC applies the same principle to che-code.

### The launcher modifies the assembly in place

The launcher (`launcher/src/`) runs in the directory of the chosen assembly (for example `/checode/checode-linux-libc/ubi9/`) and modifies these files on every boot:

| File | Modified by | Method |
|---|---|---|
| `product.json` | `product-json.ts` (via `openvsix-registry`, `trusted-extensions`, `webview-resources`) | JSON rewrite |
| `out/vs/code/browser/workbench/workbench.js` | `devworkspace-id.ts`, `openvsix-registry.ts`, `local-storage-key-provider.ts`, `webview-resources.ts` | `content.replace(MASK, value)` |
| `out/vs/workbench/workbench.web.main.internal.js` | same | same |
| `out/vs/workbench/api/node/extensionHostProcess.js` | `webview-resources.ts` | same |
| `<the three .js>.gz` | `post-patch-compression.ts` | Generated after the patches |

The list of `.js` files is centralized in `launcher/src/files.ts`.

The patches replace **single-use masks** (`{{LOCAL-STORAGE}}/{{SECURE-KEY}}`, the `DEVWORKSPACE_ID` mask, the original gallery URL, the webviews URL). Today, the full copy puts pristine files back on every boot. If we simply skipped the copy, the second boot would no longer find the masks. Any cluster configuration change (OpenVSX URL, webviews domain, trusted extensions, SSH key) would be silently ignored until the next image. The `.gz` files from the previous boot would also be served instead of the up-to-date files.

## Goals and non-goals

**Overall goal (beyond this RFC)**

Get under **40 s** between the developer clicking the IDE and the IDE showing up, on the VS Code second boot (1 min 36 s today). This is the level JetBrains reaches (37 s).

This RFC is the first axis. The detailed measurements in the Context section will tell whether it is enough to reach the target, or how much is left to gain on other axes (launcher, VS Code server, workbench loading, PVC attachment). These axes will be covered by separate RFCs.

**Goals of this RFC**

1. On the second boot of the same image, the init container only copies a few files, with a target duration under **5 s**.
2. Same functional behavior as today: launcher configuration applied on every boot, Machine settings from the image reapplied on every boot, user data untouched.
3. An image change triggers a full, clean copy, with no leftover file from the previous version.
4. A boot interrupted during the copy repairs itself on the next boot.
5. No regression with the `ephemeral` storage strategy.

**Non-goals**

- Copying only the assembly used by the dev container. The init container does not know the libc or OpenSSL version of the dev container. This is a possible future axis, through an environment variable or detection delegated to `entrypoint-volume.sh`.
- Patching from reference copies in the launcher (see [Alternatives](#alternatives-considered)).
- Making the Machine settings editable and persistent for the user.
- Optimizing the launcher, the VS Code server or the workbench loading.

## Design

### Version key

The image carries a `/checode.version` file. The volume keeps a copy `/checode/.checode.version` of the key of its content.

- Format: `<VS Code version>-<sha256 of the content>`, for example `1.128.1-3f9a2c0d71be…`. The version is readable in the logs, and the hash detects any change, including in the launcher, the che-* extensions or `machine-exec`.
- The version comes from the assembly's `package.json` (`1.128.1` today, the same as `code/package.json`). che-code has no version of its own, and a git sha would require a `--build-arg` in the CI, so we don't include one.
- The hash covers `checode-linux-musl` and `checode-linux-libc` as they are in the image. The patched files are pristine there, and they only change with the image, so including them is not a problem. The entrypoints and `remote/` are outside `checode-*` and do not count in the hash.
- The file is named `checode.version` and not `checode-version`, so it is not caught by the `cp -r /checode-*` glob.

`build/dockerfiles/assembly.Dockerfile`, in the `ubi-builder` stage, after the `machine-exec` `COPY`s:

```dockerfile
# Version key of the assemblies, read by entrypoint-init-container.sh to skip the copy when unchanged
RUN cd /mnt/rootfs \
    && version=$(sed -n 's/^\s*"version": *"\([^"]*\)".*/\1/p' checode-linux-libc/ubi9/package.json | head -1) \
    && hash=$(find checode-linux-musl checode-linux-libc -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1) \
    && printf '%s-%s' "$version" "$hash" > checode.version
```

`find` and `sha256sum` run in the builder's `ubi8/ubi` image, not in the final image. To check during implementation: the path of `package.json` in the assembly, and the cost of the hash at build time (a few seconds expected).

### Init container

`build/scripts/entrypoint-init-container.sh` (the existing Red Hat EPL-2.0 header stays unchanged):

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

Design points:

- **`/checode/remote` is never deleted.** Only `checode-*` and the marker are, so the user's settings and extensions stay in place, even on an image change.
- **`rm -rf` then `cp`, no `rsync --delete`.** `cp -r` does not remove the files the new version deleted, hence the `rm -rf`. `rsync` would be faster on a small update, but would add a dependency to the image.
- **`set -e`.** A failed copy (disk full, permissions) makes the init container fail instead of setting the marker on an incomplete volume. Today, a `cp` error goes unnoticed.
- **`remote/`.** Only `remote/data/Machine/settings.json` is copied, instead of `cp -r /remote /checode`. The result is the same, since the image only contains that file in `remote/`. The launcher then merges the settings ConfigMap into it, as today.
- **Patched files.** The four files are restored in all three assemblies, since the init container does not know which one will be used. Their `.gz` files are deleted so that `post-patch-compression.ts` regenerates them from the patched files.
- **`ephemeral` strategy.** The volume is empty on every boot, the marker is missing, so everything is copied, as today.

### Keeping in sync with the launcher

The `PATCHED_FILES` list duplicates `launcher/src/files.ts`, plus `product.json`. A file added to `files.ts` and forgotten in the script would bring back the consumed-masks bug. A check in `assembly.Dockerfile` fails the build in that case: it reads the `FILE_*` constants from the launcher's compiled `files.js` and verifies that each of them, as well as `product.json`, is in `PATCHED_FILES`. It also fails if it finds no constant, for example if the format of `files.js` changes.

This check cannot be a launcher Jest test: those tests only run in each platform's Docker build, where `launcher/` is copied alone, without `build/scripts/`. The assembly is the only place where the script and the compiled launcher are present together.

## Test strategy

**Automated**

- The `files.ts` ↔ `PATCHED_FILES` check at assembly build time, above.
- The existing launcher tests stay green (`npm test` in `launcher/`).

**Manual, on the weebo-si cluster, with the `per-user` strategy**

1. Second boot of the same image: the init container lasts less than 5 s, and its logs show `already on the volume`.
2. Configuration change between two boots (for example `OPENVSX_REGISTRY_URL`, or the trusted extensions): the change is applied on the second boot.
3. Image update between two boots: full copy, no file from the previous version in `checode-*`, and the user's extensions and settings are present in `/checode/remote`.
4. Pod deleted during the copy (`kubectl delete pod` in the middle of the copy on the first boot): the next boot redoes a full copy and the workspace starts.
5. `ephemeral` strategy: startup works as before.
6. musl (Alpine) and ubi8 dev containers: the IDE starts, which confirms the patched files are restored in all assemblies.

## Measurements

Taken on October 7, 2026 on the weebo-si cluster (single node, `per-workspace` storage on `local-path`), with `scripts/measure-che-code-boot.sh --fresh` and this repo's `devfile.yaml` (`che-min-mise` image, 5 projects to clone). Each first boot starts from a new workspace, created the way the dashboard does it. The second boot is a stop then restart of the same workspace. Images already cached on the node (pulls < 0.5 s). A single measurement per combination.

- **Before**: `quay.io/che-incubator/che-code:7.123.0` (upstream).
- **After**: `ghcr.io/weebo-si/che-code:sha-55a18ad` (`develop` on `7.123.x`, with this RFC and che-code-02).
- **Limit**: `memoryLimit` of `che-code-injector`. The upstream editor definitions (che-operator 7.121.0 and 7.123.0) use 256Mi.
- **VS Code listening**: `curl http://127.0.0.1:3100/` returns 200 inside the pod. **URL**: `<mainUrl>healthz` returns 200 from outside (ingress, Che gateway, pod gateway). Workbench loading in the browser is not counted.

Durations in seconds since the workspace was created (first boot) or restarted (second boot):

| Image | Limit | Boot | `project-clone` | `che-code-injector` | VS Code listening | URL reachable |
|---|---|---|---|---|---|---|
| Before | 256Mi | first | — | **OOMKilled** | failed | failed |
| Before | 512Mi | first | 159 | 28 | 202 | 202 |
| Before | 512Mi | second | 0 | 38 | 48 | 48 |
| Before | 1Gi | first | 149 | 22 | 192 | 192 |
| Before | 1Gi | second | 0 | 33 | 43 | 43 |
| Before | 2Gi | first | 160 | 24 | 205 | 222 |
| Before | 2Gi | second | 0 | 31 | 40 | 40 |
| After | 256Mi | first | — | **OOMKilled** | failed | failed |
| After | 512Mi | first | 150 | 24 | 192 | 192 |
| After | 512Mi | second | 0 | **0** | **10** | **10** |
| After | 1Gi | first | 151 | 25 | 193 | 193 |
| After | 1Gi | second | 0 | **0** | **9** | **9** |
| After | 2Gi | first | 163 | 21 | 206 | 221 |
| After | 2Gi | second | 0 | **0** | **9** | **9** |

`init-persistent-home` takes 0 s in every case.

Step-by-step breakdown at 1Gi (seconds; each column sums to the total):

| Step | Before, first | Before, second | After, first | After, second |
|---|---|---|---|---|
| DevWorkspace created or started → pod scheduled (DevWorkspace Operator, PVC creation on first boot) | 7 | 0 | 5 | 0 |
| Pod scheduled → `project-clone` starts (volume mount) | 3 | 2 | 2 | 2 |
| `project-clone` | 149 | 0 | 151 | 0 |
| `init-persistent-home` and transitions between init containers | 2 | 2 | 3 | 2 |
| `che-code-injector` | 22 | 33 | 25 | **0** |
| Init containers done → containers started | 5 | 2 | 2 | 3 |
| Containers started → VS Code listening (launcher then VS Code server) | 4 | 4 | 5 | 2 |
| VS Code listening → URL reachable (routing) | 0 | 0 | 0 | 0 |
| **Total** | **192** | **43** | **193** | **9** |

The IDE startup itself (containers started → VS Code listening) takes 2 to 5 s, of which 1 to 3 s for the launcher (patches, `fonts.css`) and 1 to 2 s for the VS Code server. On the second boot, `project-clone` finds in under a second that the projects are already cloned: it opens each repository and checks its remotes, without network access. There is nothing to gain there.

### Clone time (outside the scope of this RFC)

The first boot spends 150 s in `project-clone`. What DevWorkspace Operator v0.43 (`project-clone/internal`) does:

- one full `git clone` per project, one after the other, with neither `--depth` nor `--filter`, then one `git fetch` per additional remote;
- the clone is done in `/projects/project-clone-*` then moved with `os.Rename`, without copying;
- the container is limited by default to **1 CPU** and 1Gi.

The same clones, run the same day from a pod on the same node without a CPU limit (6.5 CPU):

| Repository | Size | Full clone | `--filter=blob:none` | `--depth 1` |
|---|---|---|---|---|
| `weebo-si/che-code` | 688 MB | 66 s | 30 s | 13 s |
| remote `batleforc/che-code` (fetch) | 686 MB | 0 s (objects already there) | | |
| `che-incubator/jetbrains-ide-dev-server` | 170 MB | 7 s | | 5 s |
| `weebo-si/che-dashboard` | 27 MB | 3 s | | |
| `batleforc/eclipse-che-gateway-plugin`, `batleforc/weebo-che-project` | < 2 MB | 1 s | | |

That is about 77 s without a CPU limit, versus 150 s in `project-clone`. The 1 CPU limit seems to explain half of the time: `git` delta resolution is CPU-hungry. The `che-code` repository alone accounts for 85% of the clone time.

Leads, to be measured in a dedicated RFC:

1. **Raise the `project-clone` CPU**: `spec.devEnvironments.projectCloneContainer.resources.limits.cpu` in the CheCluster (che-operator carries it over to `devworkspace-config`). It is a cluster setting, no code. Estimated gain: up to half of the clone, not measured.
2. **Move the large repositories out of the devfile `projects`** and clone them in the background (`postStart` command, `git clone --filter=blob:none`): the IDE is available in under a minute on the first boot, and the code arrives while the developer settles in. In return, DevWorkspace Operator no longer manages these repositories (remotes, `checkoutFrom`, recloning on restart).
3. **Partial or shallow clone in DevWorkspace Operator**: `project-clone` offers neither `--depth` nor `--filter` (only `sparseCheckout`, which reduces the checked-out files but not the downloaded history). A `depth` or `filter` option would require a contribution to `devfile/devworkspace-operator`.

Reference at the same place, measured the same day on an existing workspace (`weebo-dev-setup`, volume already filled) with the production image `che-code:7.121.0` at 256Mi: `che-code-injector` 60 s, VS Code listening at 73 s.

Findings:

- **Second boot: from 40-48 s down to 9-10 s.** The init container goes from 31-38 s to 0 s (its logs show `already on the volume, restoring patched files`). The 40 s target is reached up to the VS Code server, whatever the memory limit above 256Mi.
- **First boot: unchanged, about 3 min 15.** It is dominated by the project clone (150-163 s, including the `che-code` repo). The injector copy takes 21-28 s, as before: this RFC does not slow it down.
- **256Mi: the first boot fails, before and after.** See [Risks](#risks).
- **The memory limit slows the copy down.** Upstream, the injector takes 60 s at 256Mi (existing volume), 31-38 s at 512Mi and above. Above 512Mi, no measurable gain.
- **URL / VS Code gap.** In both 2Gi runs, the URL only answered 15-17 s after VS Code, when the DevWorkspace becomes `Ready`. In the other runs, both are simultaneous. The gap comes from DevWorkspace Operator reconciliation, not from che-code.

### IDE update

Measured on October 14, 2026, same cluster and devfile, 1Gi limit, with `UPDATE_IMAGE` (see below): first boot, second boot, then the workspace is stopped, the `che-code-injector` image of its DevWorkspaceTemplate is replaced, and it is started again on the volume filled by the previous image. This is what happens to existing workspaces when Che moves to a new che-code release. Images cached on the node (pulls < 1 s), so the pull of a new release is not counted. A single measurement per scenario.

- **Before**: `quay.io/che-incubator/che-code:7.121.0` → `7.123.0` (upstream).
- **After**: `ghcr.io/weebo-si/che-code:sha-55a18ad` → `sha-725f14b` (two `develop` builds with different version keys).

| Scenario | Boot | `project-clone` | `che-code-injector` | VS Code listening | URL reachable |
|---|---|---|---|---|---|
| Before | first | 157 | 68 | 248 | 248 |
| Before | second | 1 | 93 | 104 | 104 |
| Before | update | 1 | 88 | 98 | 98 |
| After | first | 157 | 40 | 216 | 240 |
| After | second | 0 | **0** | **9** | **10** |
| After | update | 0 | 64 | 77 | 77 |

Findings:

- **The update is the expensive boot of this RFC.** The injector logs show `Copying checode <new key>`: the key changed, the full copy is redone, as intended (goal 3). It costs about as much as an upstream boot (77 s against 98-104 s), once per workspace and per release.
- **The update copy is slower than the first copy (64 s against 40 s).** It first deletes the 2.7 GB of the previous version (`rm -rf /checode/checode-*`), then copies into a volume that is not empty. A lead, not measured: rename the old directories and delete them after the copy, or copy only the assembly used (non-goal above).
- **The cluster was slower than on October 7.** The upstream injector took 88-93 s at 1Gi, against 31-38 s a week earlier. Compare the scenarios of the same day with each other, not with the main table.
- A first attempt of the "after" scenario failed: `sha-55a18ad` was no longer on the node, its pull (79 s) plus the clone exceeded the 300 s progress timeout of DevWorkspace Operator. The second attempt, image cached, is the one above.

### Reproducing the measurements

`scripts/measure-che-code-boot.sh` does not depend on this cluster. Prerequisites:

- Linux with the GNU tools (`date -d`, `sort -s`), `kubectl`, `jq`, `yq` (mikefarah v4) and `curl`. The easiest is to run it from a Che workspace.
- A kubeconfig that can create `devworkspaces` and `devworkspacetemplates`, `exec`, and read logs and events in the user namespace.
- `curl` in the first container of the devfile (present in the UDI and in `che-min-mise`).
- The workspaces URL (`<mainUrl>healthz`) must be reachable from where the script runs.
- An editor definition whose image is reachable from this cluster: `deploy/develop/che-code-editor.yaml` by default, or a che-operator `editors-definitions/*.yaml` file.
- `CHE_NAMESPACE` if Che is not in `eclipse-che`. `STORAGE_TYPE` if the account cannot read the CheCluster, otherwise the script uses `per-user`, which does not necessarily match what the dashboard does.

Matrix of this document:

```sh
for image in ghcr.io/weebo-si/che-code:sha-55a18ad quay.io/che-incubator/che-code:7.123.0; do
  for mem in 256Mi 512Mi 1Gi 2Gi; do
    EDITOR_IMAGE=$image EDITOR_MEMORY=$mem TIMEOUT=900 \
      scripts/measure-che-code-boot.sh --fresh <namespace> devfile.yaml > "boot-${image##*:}-$mem.log" 2>&1
    grep RESULT "boot-${image##*:}-$mem.log"
  done
done
```

Update scenarios (`UPDATE_IMAGE` adds a third boot on the new image):

```sh
EDITOR_IMAGE=quay.io/che-incubator/che-code:7.121.0 UPDATE_IMAGE=quay.io/che-incubator/che-code:7.123.0 \
  EDITOR_MEMORY=1Gi TIMEOUT=900 scripts/measure-che-code-boot.sh --fresh <namespace> devfile.yaml
EDITOR_IMAGE=ghcr.io/weebo-si/che-code:sha-55a18ad UPDATE_IMAGE=ghcr.io/weebo-si/che-code:sha-725f14b \
  EDITOR_MEMORY=1Gi TIMEOUT=900 scripts/measure-che-code-boot.sh --fresh <namespace> devfile.yaml
```

Each run creates then deletes its own workspace. The measurements are sequential: run in parallel on the same node, they would slow each other down.

## Risks

- **Injector OOM on first boot with the upstream 256Mi limit.** On this cluster, copying the 2.7 GB of the three assemblies into an empty volume is killed (`OOMKilled`) at 256Mi with `che-code:7.123.0`, `che-code:next` and our images, but not with `che-code:7.121.0`, which has been on the node for weeks. The content (size, number of files), the script and `cp` are the same. The memory consumed is page cache (files read and written), not process memory. Hypothesis, unproven for lack of a second node: the file cache of an image already read is charged to another cgroup. This problem is upstream and independent of this RFC, but it will block VS Code workspace creation when moving to Che 7.123. Mitigation: 512Mi is enough in our measurements, 1Gi leaves headroom. Copying a single assembly (non-goal above) would also divide the amount copied by three. To reproduce on a multi-node cluster, then to report to `che-incubator/che-code`.
- **UID change between two boots.** If the pod UID changes (namespace recreated, `securityContext` modified), `rm` and `cp` on existing files may fail. With `set -e`, the init container fails visibly instead of starting on half-copied content. The problem already exists today with `cp` on existing files. To check on OpenShift and on vanilla Kubernetes.
- **Shared volume.** The design assumes a `checode` volume specific to each workspace (one subpath per workspace with `per-user`). To confirm in DevWorkspace Operator. If two workspaces shared the same path, two simultaneous copies could interleave.
- **Forgotten patched file.** Covered by the check at assembly build time, provided future patches go through `files.ts`.

## Delivery plan

1. Create the `weebo-si/che-code` fork. It is already declared in `forks.yaml`, with `feat/init-copy-cache` merged into `develop`.
2. ~~Take the missing measurements from the Context section on the current image.~~ Done, see [Measurements](#measurements).
3. Implement on `feat/init-copy-cache` (Dockerfile, script, test), with `Signed-off-by` on every commit.
4. Build the image from `develop` pushed to the public fork, deploy on the weebo-si cluster, run the manual tests and measure the full second boot again against the 40 s target.
5. Open the upstream PR to `che-incubator/che-code` with the before/after measurements.
6. Once the PR is merged upstream, remove `feat/init-copy-cache` from `develop.merge`.

## Licenses

- `che-code` is under EPL-2.0. The modified files keep their license and their Red Hat header, with no weebo-si line added.
- No new dependency: `find`, `sha256sum` and `sed` come from the existing builder image.
- A che-code image given to a customer or published must be built from a commit pushed to the public `weebo-si/che-code` fork (EPL-2.0 §3.2). The image also ships VS Code (MIT): its notices stay in the image.
- The upstream contribution requires a signed ECA with the commit author's email.

## Alternatives considered

- **Key = `commit` from `product.json` (VS Code commit).** Already in the image, but it does not change when only the che-code code moves (launcher, che-* extensions). The volume would then keep stale content. Rejected.
- **Key = image digest passed through the editor definition.** Exact, but the container does not know its own digest. It would require touching `che-operator` and the editor definitions. Rejected to stay within a single repo.
- **Patching from reference copies in the launcher (`workbench.js.orig`).** More robust in the long run, since there is no list left to keep in sync. But it modifies six launcher files, the diff is bigger to get accepted upstream, and the restore by the init container gives the same result. An option to reconsider if the list of patched files becomes hard to maintain.
- **`rsync --delete`.** Incremental copy, but a new dependency in the injector image. Rejected.

## Open questions

- Is the `checode` volume really specific to each workspace with every storage strategy?
- How long does the workbench take to load in the browser after the URL's 200? It is the only second-boot step the script does not measure.
- Does the 256Mi OOM reproduce on a fresh node with `che-code:7.121.0` (see [Risks](#risks))?
