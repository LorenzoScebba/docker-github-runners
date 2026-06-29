# TODO / re-audit checklist

Tracking list for the hardening workarounds that are temporary or need periodic
verification. Most exist because an upstream fix has landed in source but not in
a shipped release. **Walk this list on every version bump and scheduled rebuild**
(see [`UPDATING.md`](UPDATING.md)); delete an item once its workaround is no
longer needed.

## Open — re-audit and remove when upstream catches up

- [ ] **kubectl `GO-2026-5026` (`x/net/idna`, Critical) — ignored in [`.grype.yaml`](.grype.yaml).**
  No kubernetes release ships `golang.org/x/net >= v0.55.0` yet (even `v1.36.2`
  pins `v0.49.0`). When a release bundles the fixed `x/net`: bump
  `KUBECTL_MINOR_VERSION` in the [`Dockerfile`](Dockerfile), delete the ignore
  rule in `.grype.yaml`, and drop the row from the README "CVEs left unfixed"
  table. **Check:** `curl -fsSL https://raw.githubusercontent.com/kubernetes/kubernetes/v<ver>/go.mod | grep 'golang.org/x/net'`

- [ ] **git-lfs forced `x/net`/`x/crypto` bump (`gitlfs` stage in [`Dockerfile`](Dockerfile)).**
  `GO_X_NET_VERSION` / `GO_X_CRYPTO_VERSION` are force-`go get`'d because the
  git-lfs source tag still pins the vulnerable versions. Once a git-lfs release
  pins `x/net >= v0.55.0` / `x/crypto >= v0.53.0` natively, the `go get` becomes
  a no-op and can be removed (revert to a plain build). Bump the pins instead if
  a newer advisory raises the fixed floor. **Check:** compare the pins against
  the git-lfs tag's `go.mod`.

- [ ] **helm release floor (`HELM_VERSION` in [`Dockerfile`](Dockerfile), default `3.21.2`).**
  Pulled from `get.helm.sh` because the buildkite apt repo lags. Staying on
  helm 3.x by choice (avoids helm 4 breaking changes). On bump, confirm the new
  version's `go.mod` still has `x/net >= v0.55.0` / `x/crypto >= v0.52.0`.

- [ ] **`CVE-2026-6100` (Critical) — python `3.14.5` bundled in aws-cli v2.**
  No patched python ships upstream yet; grype reports no fixed version so it
  does not fail the gate (`only-fixed: true`). Re-check on rebuild whether a
  fixed aws-cli/python is available.

## Verification still owed

- [ ] **Full image build + grype scan not yet run end-to-end.** Individual
  pieces were component-tested (git-lfs compiles with the bump; helm 3.21.2 and
  NodeSource node 24 binaries are clean), but a complete `docker build` +
  `grype` of the assembled image has not been executed. Run the `build`
  workflow (or `bash scan.sh` locally) and confirm zero fixable Criticals before
  relying on the fix.

## Notes

- The CI gate (`build.yml`) only blocks on **fixable Criticals**. High-severity
  residuals are tracked in the README "CVEs left unfixed" table, not here.
- Every `.grype.yaml` ignore must have a corresponding row in the README table
  and an open item above.
