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

- [ ] **`GHSA-23hp-3jrh-7fpw` (Critical, node-tar Gzip Bomb DoS) — ignored in
  [`.grype.yaml`](.grype.yaml) as an accepted risk, not a remediation gap.**
  Re-audit if this fleet's runners are ever exposed to untrusted
  contributors/forks, or drop the ignore once `actions/runner`'s node20
  externals move past npm 10.8.2 (pinned to `tar ^6.2.1`, no patched 6.x
  release exists).

## Verification still owed

- [ ] **Runner version bumps may move the HTTP trace format.** The wrapper
  parses `Runner_*.log` for the `HttpRequestOut.Stop` event emitted under
  `GITHUB_ACTIONS_RUNNER_HTTPTRACE=true`. That format is an implementation
  detail of the .NET `System.Net.Http` EventSource, not a documented contract —
  re-confirm the metric still appears after a `GH_RUNNER_VERSION` bump. Failure
  mode is fail-open (no metric, registration untouched).

- [x] **Full image build + grype scan not yet run end-to-end.** ~~Individual
  pieces were component-tested...~~ Done 2026-08-26 for both the default and
  `-dind` (`INSTALL_DOCKER_DAEMON=true`) images: local `docker build` +
  `grype` scan of both, plus a daemon-level smoke test of the `-dind` variant
  (see the item below). The default and `-dind` legs are now both built,
  scanned, and pushed by `build.yml`'s matrix on every run.

- [ ] **DinD (`INSTALL_DOCKER_DAEMON=true`) verified at the daemon level only,
  not through a real GitHub Actions job.** Locally confirmed: `dockerd` starts
  via `service docker start` in this systemd-less base, the new
  `docker-ready.sh` CMD wrapper (`scripts/hooks/`) correctly waits for
  readiness and stops the daemon cleanly on shutdown, and a nested
  `docker run` works **given `--tmpfs /var/lib/docker`** (this image's own
  rootfs is overlayfs, and `overlay2` cannot layer on overlayfs — confirmed
  by reproducing the `mount ... fstype: overlay ... invalid argument`
  failure without it). What's NOT verified: an actual GitHub Actions workflow
  job running `docker build`/`docker run` steps against a real runner
  registration — that needs live org/repo credentials this environment
  doesn't have. Re-audit once someone runs it against a real fleet.

- [ ] **`grype` results for "latest"-pulled tools are timing-sensitive, not
  just version-sensitive.** While scanning the `-dind` variant, two local
  builds taken minutes apart showed different Critical/High findings for
  `crane` and `gh` (both `install-tools.sh` pulls `releases/latest`) purely
  because each build happened to fetch a different point-in-time release.
  This is the risk `UPDATING.md` already flags for auto-refreshed components,
  but it means a **CI run can flip red/green between two runs with an
  otherwise-identical diff**, not just between version bumps. Consider
  whether `crane`/`gh` should move to pinned versions (like `HELM_VERSION`)
  if this causes flaky CI.

## Notes

- The CI gate (`build.yml`) only blocks on **fixable Criticals**. High-severity
  residuals are tracked in the README "CVEs left unfixed" table, not here.
- Every `.grype.yaml` ignore must have a corresponding row in the README table
  and an open item above.
