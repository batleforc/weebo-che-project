# Weebo Che Project

Workspace for the weebo-si forks of Eclipse Che (`che-server`, `che-operator`, `che-dashboard`,
`che-docs`) and their image builds (`che-images`). Plans and specs live in `.rfc/`, cluster
manifests in `deploy/`.

## Licenses: always check and respect them

weebo-si plans to sell support for a dev environment built on Eclipse Che. Any license mistake in
the forks, the images or the deployment becomes a commercial liability. Treat license compliance
as a requirement, not a detail. When in doubt, stop and ask instead of guessing.

### What applies

| Code | License | Key obligations |
|---|---|---|
| Eclipse Che repos (forks) | EPL-2.0 | File-level copyleft: modified EPL files stay EPL-2.0. When binaries are distributed (public images, images given to a customer), say where the source is (§3.2) and keep every copyright and license notice (§3.3) |
| `che-images`, `weebo-base` template | Apache-2.0 | Keep `LICENSE.md` and notices |
| Third-party dependencies (npm, Maven, Go, base images) | Various | Keep their notices. Check the license before adding a new one |

### Rules

- **Never remove or alter** an existing copyright header, `LICENSE`, `NOTICE` or third-party notice.
- **New files in a fork** get the exact header of that repo's template (`che-server`: the
  license-maven-plugin template; `che-operator`: `hack/license-header.txt`; `che-dashboard`:
  `.config/copyright.js`). The checkers are strict: any extra line, including a weebo-si
  contributor line, fails `mvn validate` and ESLint `notice/notice`. Don't add attribution to
  headers until a decision is recorded here.
- **`che-code`** has no header checker. New files written by weebo-si use the launcher header
  with `Copyright (c) <year> Contributors to the Eclipse Foundation` (decided 2026-10-07), never
  `Red Hat, Inc.` (not their code) nor a weebo-si line.
- **Modified files** keep their license. Never relicense EPL code, and never move EPL code into a
  repo under another license (e.g. copying Che code into `che-images` or a closed-source product).
- **New dependencies**: check the license first. EPL-2.0, Apache-2.0, MIT, BSD and ISC are fine.
  Flag GPL, AGPL, SSPL, BUSL, "non-commercial" and unlicensed code to the user before adding them.
  In `che-dashboard`, run `yarn license:generate` and commit the regenerated `.deps/` files. Che
  upstream also requires Eclipse Foundation (ClearlyDefined/IP) approval for new dependencies.
- **Images**: keep the `org.opencontainers.image.source`, `.revision` and `.licenses` labels in
  `che-images` (they are how recipients find the source). Don't strip license files or notices
  from the images.
- **Source availability**: any image or binary that is public or given to a customer must be built
  from a commit pushed to a public weebo-si fork. Never ship a build from unpushed or private
  changes to EPL code.
- **Trademark**: "Eclipse Che" and "Eclipse" are Eclipse Foundation trademarks. Present weebo-si
  builds and offers as *based on* Eclipse Che, never as the official product. Don't use Eclipse
  logos or names in product names, domains or marketing without checking the
  [Eclipse trademark guidelines](https://www.eclipse.org/legal/logo_guidelines/).
- **Upstream contributions** need a signed Eclipse Contributor Agreement (ECA) matching the commit
  author email, plus `Signed-off-by` on every commit.
- **Commercial offer**: selling support and services around EPL software is allowed. Any change
  that would make weebo-si distribute modified Che to customers (private registry, air-gapped
  bundle, appliance), or combine Che code with proprietary code in the same module, needs a
  license review with the user first.

Point out license issues as you notice them, even when they are outside the current task.

<!-- rtk-instructions v2 -->
# Command output

Command output here is condensed to save tokens, keeping every signal and
dropping costly noise. Treat it as the complete result: run commands
normally, and batch related commands into one call to avoid extra turns.
Truncated results state their recovery path in their own output. Re-run a
command as `rtk proxy <cmd>` only when its result is unusable: empty when
output was clearly expected, contradicting its exit code, or garbled.
<!-- /rtk-instructions -->