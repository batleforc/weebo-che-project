# CheCluster on the `develop` images

Runs che-server, che-dashboard and che-operator from the `develop` branches of the weebo-si forks,
built by [weebo-si/che-images](https://github.com/weebo-si/che-images):

| Component | Image | Content |
|---|---|---|
| che-operator | `ghcr.io/weebo-si/che-operator:develop` | `spec.gitServices.forgejo`, OAuth secret mounting |
| che-server | `ghcr.io/weebo-si/che-server:develop` | Forgejo factory, OAuth and PAT modules |
| che-dashboard | `ghcr.io/weebo-si/che-dashboard:develop` | Forgejo provider + workspace Storage tab |
| che-code | `ghcr.io/weebo-si/che-code:sha-55a18ad` | Based on 7.123.x. Conditional copy in the init container (RFC che-code-01), container fonts in the browser (RFC che-code-02) |

## Apply order

1. **Images reachable**: GHCR packages start private. Make them public, or add a pull secret
   to the `eclipse-che` namespace and the `che-operator` service account.
2. **CRD** from the forked operator (adds `gitServices.forgejo`; without it the field is pruned):
   ```bash
   kubectl apply --server-side --force-conflicts -f \
     https://raw.githubusercontent.com/weebo-si/che-operator/develop/deploy/deployment/kubernetes/objects/checlusters.org.eclipse.che.CustomResourceDefinition.yaml
   ```
3. **Operator**:
   ```bash
   kubectl patch deployment che-operator -n eclipse-che --patch-file che-operator.patch.yaml
   ```
4. **Secrets** (`secrets.example.yaml`, values from Vault).
5. **CheCluster** (`checluster.yaml`), through the `che-app` ArgoCD application.

The operator reconciles the che and che-dashboard Deployments with the images set in the CheCluster.

## che-code editor

che-code is not part of the CheCluster: `che-code-editor.yaml` is an editor definition in a
ConfigMap, listed by the dashboard next to the built-in editors. It does not replace them.

```bash
kubectl apply -f che-code-editor.yaml
```

Pick **VS Code - Open Source (weebo-si develop)** in the dashboard editor selector, or start a
workspace with `https://cde.batleforc.fr/#<repo url>?che-editor=weebo-si/che-code/develop`.

The image is pinned to `sha-<short>` of the `develop` commit: the init container reuses the volume
when the image does not change, so a moving tag would hide a new build. Update the tag after each
rebuild of `develop`.

Testing the container fonts (RFC che-code-02), with the `che-min-mise` image (FiraCode Nerd Font):

1. On a machine without FiraCode Nerd Font, set
   `"terminal.integrated.fontFamily": "FiraCode Nerd Font"` and `"editor.fontFamily": "FiraCode Nerd Font"`.
2. The Nerd Font glyphs show in the terminal, ligatures, bold and italic in the editor, with no
   cursor or spacing offset.
3. The browser network tab only downloads the rendered weights; a reload gets `304`.
4. `cat /checode/fonts.css` in the dev container lists the fonts, and `/checode/entrypoint-logs.txt`
   shows `fonts declared`.

## Known limits of `develop`

- The dashboard service account can't read StorageClasses yet (che-operator RBAC follow-up), so the
  Storage tab shows expandability as `unknown` unless the user can read them; the API server still
  rejects the resize if the class does not allow expansion.
- Users can't read `resourcequotas`/`limitranges` with `eclipse-che-edit`: the resize modal shows
  "quota could not be read" and the cluster validates on submit.
- `develop` is a moving tag: pin `sha-<short>` tags for a reproducible rollout.

## Rollback

Restore `quay.io/eclipse/che-operator:7.121.0` on the operator Deployment, remove the image overrides
and `gitServices.forgejo` from the CheCluster. The upstream CRD can stay: the new field is optional.
