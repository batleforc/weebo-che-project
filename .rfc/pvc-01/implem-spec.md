# Spec: Workspace Storage tab (PVC status & resize) in Che Dashboard

- **Issue**: https://github.com/eclipse-che/che/issues/23934
- **Repos**: `eclipse-che/che-dashboard` (main work), `eclipse-che/che-operator` (RBAC only)
- **Author**: batleforc

## 1. Goal

Workspaces with a full PVC can fail to start (`project-clone` crashes with "no space left on device"). Users need to:

1. See the PVC capacity and current usage of a workspace.
2. Expand the PVC from the Dashboard, safely.

## 2. Locked decisions

1. **UI placement**: a new **Storage** tab in Workspace Details (`Overview | Devfile | Storage | Events | Logs`).
2. **StorageClass read** (`allowVolumeExpansion`): try with the **user token** first; on 403 fall back to the **dashboard service account** (if the operator grants it); if both fail, expansion capability is `unknown` and the resize is still allowed (the `PersistentVolumeClaimResize` admission controller rejects it server-side if not permitted).
3. **PVC patch**: performed with the **user token** only. Never with the service account.
4. **Usage**: `exec` of `df -Pk /projects` in the workspace container, **only when the workspace is running**. No Prometheus / kubelet stats dependency.
5. **Shared PVC** (`per-user` strategy): allowed, but always flagged with a `[Shared]` badge and a notice in the resize modal.
6. **Resize action**: a single `[+5 Gi]` button on the tab. It opens a modal pre-filled with `capacity + 5 Gi`; the modal has a number input to adjust.
7. **Irreversibility warning is mandatory**: Kubernetes cannot shrink volumes. The modal shows the warning and requires a confirmation checkbox before `[Resize]` is enabled.
8. **Quota pre-check**: if the namespace `ResourceQuota` / `LimitRange` are readable with the user token, validate the new size before submitting. If they are not readable (403), **skip the pre-check** and rely on the API server, mapping its error to a readable message.
9. **Tab stays minimal** (OpenShift console PVC view style): usage donut, name, capacity, one action. Quota, warnings and details live in the modal.

## 3. PVC resolution

| Storage strategy | PVC name | Shared |
|---|---|---|
| `per-user` (default) | `claim-devworkspace` | yes |
| `per-workspace` | `storage-<workspaceId>` (e.g. `storage-workspace1af2f1d9f3b745f6`) | no |
| `ephemeral` | none | n/a |

- Strategy source: DevWorkspace attribute `controller.devfile.io/storage-type`, else the CheCluster default from the server config.
- When the workspace pod exists, **prefer** the `claimName` from the pod's `spec.volumes[].persistentVolumeClaim`. Fall back to the naming convention above only when the workspace is stopped.

## 4. Backend (`packages/dashboard-backend`)

Follow existing conventions (route registration, `getDevWorkspaceClient(token)`-style factories, error helpers). Check the `@kubernetes/client-node` version in use and adapt call signatures (positional vs object args). Reuse the existing exec helper (the one used for `podman login`).

### 4.1 Routes

```
GET   /dashboard/api/namespace/:namespace/devworkspaces/:workspaceName/storage
GET   /dashboard/api/namespace/:namespace/devworkspaces/:workspaceName/storage/usage
GET   /dashboard/api/namespace/:namespace/devworkspaces/:workspaceName/storage/quota?size=15Gi
PATCH /dashboard/api/namespace/:namespace/devworkspaces/:workspaceName/storage   body: { "size": "15Gi" }
```

`usage` is separate because exec is slow and may fail; it must never block `storage`.

### 4.2 Shared types (`packages/common`)

```ts
export type StorageStrategy = 'per-user' | 'per-workspace' | 'ephemeral';
export type Expandability = 'allowed' | 'forbidden' | 'unknown';

export interface WorkspaceStorageInfo {
  strategy: StorageStrategy;
  pvcName?: string;
  shared: boolean;
  storageClassName?: string;
  requested?: string;        // spec.resources.requests.storage
  capacity?: string;         // status.capacity.storage
  expandability: Expandability;
  resizing: boolean;         // condition Resizing
  fsResizePending: boolean;  // condition FileSystemResizePending
}

export interface WorkspaceStorageUsage {
  totalBytes: number;
  usedBytes: number;
  availableBytes: number;
}

export type QuotaCheckStatus = 'ok' | 'exceeded' | 'unavailable';

export interface QuotaCheckEntry {
  source: 'ResourceQuota' | 'LimitRange';
  name: string;            // object name
  key: string;             // e.g. requests.storage
  used?: string;
  hard: string;
  projected: string;
  ok: boolean;
}

export interface WorkspaceStorageQuotaCheck {
  status: QuotaCheckStatus;
  entries: QuotaCheckEntry[];
  maxAllowedSize?: string; // largest size that fits all constraints
}
```

### 4.3 Services

**`StorageClassService`**
- `getExpandability(storageClassName)`: user token → on 403 service account → on failure `unknown`. Missing `storageClassName` → `unknown`.
- Cache results in memory (TTL ~5 min, keyed by class name).

**`PvcService`**
- `getInfo(namespace, workspace)`: resolve PVC (section 3), read it with the user token, compute `WorkspaceStorageInfo`.
- `resize(namespace, workspace, size)`:
  - Reject if strategy is `ephemeral` (400).
  - Reject if `size` is not a valid Kubernetes quantity (400).
  - Reject if `size <= current request` (400, "shrinking or no-op resize is not supported").
  - Reject if expandability is `forbidden` (400). Allow if `unknown`.
  - Patch with **merge patch** `{ spec: { resources: { requests: { storage: size } } } }` using the user token.
  - Map API errors: 403 containing `exceeded quota` → 422 with readable quota message; other 403 → 403; admission rejection on expansion → 400 "storage class does not allow expansion".

**`QuotaService`**
- `check(namespace, pvc, newSize)`:
  - `delta = newSize − currentRequest`.
  - For each `ResourceQuota` in the namespace, check keys `requests.storage` and `<storageClass>.storageclass.storage.k8s.io/requests.storage`: `used + delta <= hard`.
  - For each `LimitRange` item of `type: PersistentVolumeClaim`: `newSize <= max.storage`.
  - `maxAllowedSize` = min over all constraints (`hard − used + currentRequest`, `max.storage`).
  - Any 403 while listing → `{ status: 'unavailable', entries: [] }`. No error thrown.

**`StorageUsageService`**
- Only if the workspace is running; otherwise return 409 (frontend shows the "start the workspace" state).
- Exec `df -Pk /projects` (POSIX output, BusyBox-compatible) in the first container mounting `/projects`, with the user token.
- Parse 1024-byte blocks → bytes. Parsing failure → 500 with a clear message.
- In `per-user`, the result is the whole shared PVC filesystem usage (expected).

### 4.4 Quantity helper (`packages/common`)

`parseQuantity(q: string): number` (bytes) and `formatGi(bytes: number): string`. Support binary (`Ki Mi Gi Ti`), decimal (`k M G T`) suffixes and plain integers. Throw on invalid input.

## 5. Operator (`che-operator`)

Add to the dashboard ClusterRole (read-only, non-sensitive):

```yaml
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get"]
```

Check that the user role granted in Che namespaces includes `patch` on `persistentvolumeclaims`, and `get`/`list` on `resourcequotas` and `limitranges`. Add them if missing.

Status (che-operator `develop`):
- [ ] Dashboard ClusterRole: `get` on `storageclasses` is missing.
- [x] `eclipse-che-edit`: `patch` on `persistentvolumeclaims` and `create` on `pods/exec` are present.
- [ ] `eclipse-che-edit`: `get`/`list` on `resourcequotas` and `limitranges` are missing (quota check is `unavailable` for regular users).
- Alternative to the service account fallback: bind a `get storageclasses` ClusterRole to `system:authenticated`, so the user token read succeeds (the dashboard tries it first).

## 6. Frontend (`packages/dashboard-frontend`)

PatternFly components. Follow existing Workspace Details tab patterns.

### 6.1 Storage tab (running, per-workspace)

```
Workspace Details → Storage tab

  Overview   Devfile   [Storage]   Events   Logs
  ─────────────────────────────────────────────────

  Storage

          ░░░░░████
       ░░░         ███
      ░░    4.7 Gi    ██
      ░░   Available  ██
       ░░░         ███
          ░░░░░░░██

  Name
  storage-workspace1af2f1d9f3b745f6

  Capacity
  10 Gi                                  [+5 Gi]
```

- Donut: `ChartDonutUtilization` (or equivalent), dark = used, light = available, center label = available size.

### 6.2 Variants

Per-user (shared):
```
  Name
  claim-devworkspace  [Shared]
```

Workspace stopped (capacity known, usage not):
```
          ░░░░░░░░░
       ░░░         ░░░
      ░░      —      ░░
      ░░  Start the   ░░
       ░░ workspace ░░
          ░░░░░░░░░
```
Resize remains possible while stopped.

Expansion forbidden (tooltip on hover, not permanent text):
```
  Capacity
  10 Gi                                  [+5 Gi] (disabled)
                     ⓘ Storage class does not allow expansion
```

Resize in progress:
```
  Capacity
  10 Gi → 15 Gi  ◐ Resizing
```
With `fsResizePending`: add "Restart the workspace to apply the new size." Poll `/storage` every ~5 s while `resizing || fsResizePending`.

Ephemeral:
```
  ⓘ This workspace uses ephemeral storage. Data is lost when
    the workspace stops. There is no volume to manage.
```

### 6.3 Resize modal

```
┌──────────────────────────────────────────────────────┐
│  Resize storage                                      │
│                                                      │
│  PVC        claim-devworkspace  [Shared]             │
│  Current    10 Gi                                    │
│  New size   [ −   15   + ] Gi                        │
│                                                      │
│  ⚠  This action cannot be undone.                    │
│     Kubernetes does not support shrinking volumes:   │
│     once expanded, the size can never be reduced.    │
│                                                      │
│  ⓘ  Shared by all workspaces in this namespace.      │
│                                                      │
│  Quota check                                         │
│  ✔  requests.storage   20 + 5 = 25 Gi / 50 Gi        │
│                                                      │
│  ☐  I understand the storage cannot be reduced       │
│                                                      │
│                          [Cancel]  [Resize]          │
└──────────────────────────────────────────────────────┘
```

Quota exceeded:
```
│  Quota check                                         │
│  ✖  requests.storage   48 + 5 = 53 Gi / 50 Gi        │
│     Exceeds namespace quota by 3 Gi.                 │
│     Maximum new size: 12 Gi                          │
│                          [Cancel]  [Resize] (disabled)│
```

Quota unreadable:
```
│  Quota check                                         │
│  ⓘ  Namespace quota could not be read. The request   │
│     will be validated by the cluster on submit.      │
```

Rules:
- Number input min = current capacity + 1 Gi, step 1 Gi, default = capacity + 5 Gi.
- Quota check re-runs (debounced ~300 ms) when the size changes.
- The `Shared` notice is shown only for `per-user`.
- `[Resize]` enabled only if: checkbox checked **and** size > current **and** quota status ≠ `exceeded`.
- On submit error, show the backend message in an inline `Alert` inside the modal; keep the modal open.

## 7. Unit tests (mandatory)

**Every element in this spec must be covered by unit tests.** Do not open the PR without them. Use the existing frameworks (Jest for backend/common, Jest + React Testing Library for frontend) and existing mocking patterns for the Kubernetes client.

### 7.1 `common` — quantity helper
- Parses `Ki/Mi/Gi/Ti`, `k/M/G/T`, plain integers.
- Throws on invalid input (`"abc"`, `"-5Gi"`, `""`).
- `formatGi` round-trips typical values.

### 7.2 Backend — PVC resolution
- `per-user` → `claim-devworkspace`, `shared: true`.
- `per-workspace` → `storage-<workspaceId>`, `shared: false`.
- `ephemeral` → no PVC.
- Strategy from DevWorkspace attribute overrides the server default.
- Pod `claimName` takes precedence over the naming convention when running.

### 7.3 Backend — `StorageClassService`
- User token OK → `allowed` / `forbidden` from `allowVolumeExpansion`.
- User 403 → service account used.
- Both fail → `unknown`.
- No `storageClassName` → `unknown`.
- Cache hit avoids a second API call; cache expiry triggers a new one.

### 7.4 Backend — `PvcService.resize`
- Valid expansion → merge patch sent with the user token and the correct body.
- Same size → 400. Smaller size → 400.
- Invalid quantity → 400.
- Ephemeral → 400.
- Expandability `forbidden` → 400; `unknown` → patch attempted.
- API 403 `exceeded quota` → 422 with readable message.
- API admission rejection → 400.
- Other 403 → 403.
- Service account is **never** used for the patch.

### 7.5 Backend — `PvcService.getInfo`
- `capacity` vs `requested` mapped correctly.
- `Resizing` and `FileSystemResizePending` conditions mapped to flags.

### 7.6 Backend — `QuotaService`
- No quotas → `ok`, empty entries.
- `requests.storage` within limits → `ok`.
- Per-storage-class key exceeded → `exceeded`.
- LimitRange `max.storage` exceeded → `exceeded`.
- `maxAllowedSize` = the strictest constraint.
- 403 on list → `unavailable`, no throw.

### 7.7 Backend — `StorageUsageService`
- Parses `df -Pk` output (GNU and BusyBox samples) into bytes.
- Workspace stopped → 409.
- Unparseable output → 500.
- Picks the container mounting `/projects`.

### 7.8 Backend — routes
- Each route: happy path, validation errors, and auth token forwarding.

### 7.9 Frontend — Storage tab
- Renders donut, name, capacity, `[+5 Gi]`.
- `[Shared]` badge only for `per-user`.
- Stopped workspace → "Start the workspace" state; `[+5 Gi]` still enabled.
- Expandability `forbidden` → button disabled with tooltip.
- Ephemeral → notice only, no button.
- Resizing → `10 Gi → 15 Gi` + indicator; polling starts and stops.
- `fsResizePending` → restart message.
- Usage fetch failure does not break the tab.

### 7.10 Frontend — Resize modal
- Opens pre-filled with capacity + 5 Gi.
- Irreversibility warning is **always** rendered.
- `[Resize]` disabled until checkbox checked.
- Input cannot go below capacity + 1 Gi.
- Shared notice only for `per-user`.
- Quota `ok` → ✔ line; `exceeded` → ✖ line, max size shown, `[Resize]` disabled; `unavailable` → info line, `[Resize]` enabled.
- Quota check re-runs on size change (debounced).
- Submit error shown inline, modal stays open.
- Successful submit closes the modal and refreshes storage info.

## 8. Risks to verify before merging

- [x] **DevWorkspace Operator reconciliation**: confirm DWO does not reset `spec.resources.requests` of the common PVC to `defaultStorageSize`. If it does, stop and report: a DWO-side change is needed.
  - Checked: DWO does not reset a resized PVC. No DWO-side change needed.
- [x] **`per-workspace` PVC recreation**: a deleted/recreated PVC returns to the default size. Acceptable for v1; document it.
- [x] **CSI drivers without online expansion**: handled via `FileSystemResizePending` + restart message.
- [x] **Storage class without expansion** (found on the weebo cluster): the only class is `local-path` (no `allowVolumeExpansion`).
  - Expandability is `forbidden`: `[+5 Gi]` disabled with the "Storage class does not allow expansion" tooltip.
  - `local-path` volumes are node directories: `df` reports the node filesystem, not the claim size, so the donut shows node usage.
  - An end-to-end resize test needs an expandable class (e.g. Longhorn, OpenEBS LVM).

## 9. Out of scope (v1)

- Shrinking volumes (impossible).
- Configurable resize step in the CheCluster (fixed `+5 Gi`).
- Volume snapshots.
- Cleanup of editor artifacts in the home folder.

## 10. Definition of done

- All routes, services, UI states and modal rules from sections 4–6 implemented.
- All tests from section 7 present and passing; coverage not decreased.
- Operator RBAC change in a separate PR on `che-operator`, linked to the dashboard PR.
- Risks in section 8 checked and reported in the PR description.
- PR description references issue #23934 and includes screenshots of each tab state and the modal.

## 11. Status

- [x] Implemented on `batleforc/che-dashboard` branch `feat/workspace-storage` (`1826e4c`), based on upstream `main`.
- [x] Merged with the Forgejo work into `develop` on `weebo-si/che-dashboard`; images built by `weebo-si/che-images` (`:develop`).
- [ ] Manual validation on the cluster (batleforc).
- [ ] Upstream PR on `eclipse-che/che-dashboard` (batleforc), referencing issue #23934, with screenshots of each tab state and the modal.
- [ ] Operator RBAC PR on `eclipse-che/che-operator` (section 5), linked to the dashboard PR.
