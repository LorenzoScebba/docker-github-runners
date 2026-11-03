# TODO / re-audit checklist

Tracking list for the hardening workarounds that are temporary or need periodic
verification. Most exist because an upstream fix has landed in source but not in
a shipped release. **Walk this list on every version bump and scheduled rebuild**
(see [`UPDATING.md`](UPDATING.md)); delete an item once its workaround is no
longer needed.

## Open — re-audit and remove when upstream catches up

- [ ] **git-lfs forced `x/net`/`x/crypto` bump (`gitlfs` stage in [`Dockerfile`](Dockerfile)).**
  `GO_X_NET_VERSION` / `GO_X_CRYPTO_VERSION` are force-`go get`'d because the
  git-lfs source tag still pins the vulnerable versions. Once a git-lfs release
  pins `x/net >= v0.60.0` / `x/crypto >= v0.57.0` natively (pins raised
  2026-11-03 for `GO-2026-6612`; git-lfs `v3.8.1` itself pins `x/net v0.57.0`), the `go get` becomes
  a no-op and can be removed (revert to a plain build). Bump the pins instead if
  a newer advisory raises the fixed floor. **Check:** compare the pins against
  the git-lfs tag's `go.mod`.

- [ ] **helm release floor (`HELM_VERSION` in [`Dockerfile`](Dockerfile), default `3.22.1`).**
  Pulled from `get.helm.sh` because the buildkite apt repo lags. Staying on
  helm 3.x by choice (avoids helm 4 breaking changes). On bump, confirm the new
  version's `go.mod` still has `x/net >= v0.60.0` (`GO-2026-6612`) /
  `x/crypto >= v0.57.0`.

- [ ] **`GHSA-23hp-3jrh-7fpw` (Critical, node-tar Gzip Bomb DoS) — ignored in
  [`.grype.yaml`](.grype.yaml) as an accepted risk, not a remediation gap.**
  Re-audit if this fleet's runners are ever exposed to untrusted
  contributors/forks, or drop the ignore once `actions/runner`'s node20
  externals move past npm 10.8.2 (pinned to `tar ^6.2.1`, no patched 6.x
  release exists).

- [ ] **Prebuilt-binary Criticals with no upstream fix yet (2026-11-03) — all
  ignored in [`.grype.yaml`](.grype.yaml), location-scoped per binary.** Every
  affected tool was already on its latest release when checked. Drop each rule
  (and its README row) once the named upstream ships the fix:
  - `GO-2026-6612` (`x/net` < `v0.60.0`): **kubectl** (1.35.10 → `v0.56.0`; no
    k8s release incl. `v1.37.2` pins `>= v0.60.0` — bump `KUBECTL_MINOR_VERSION`
    once one does), **docker-buildx** 0.38.1 and **yq** v4.54.1 (`v0.59.0`),
    and in the `-dind` image **containerd/ctr/containerd-shim-runc-v2** 2.4.2
    (`v0.58.0`) and **runc** 1.5.2 (`v0.55.0`).
    **Check:** `curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/<tag>/go.mod | grep 'golang.org/x/net '`
  - Go stdlib `CVE-2026-78663` / `GO-2026-6604` / `GO-2026-6612` (fixed in
    go`1.26.9`/`1.27.2`): **crane** v0.22.1 (go1.26.6) and **yq** v4.54.1
    (go1.27.1). (Replaces the earlier crane-only `GO-2026-4337` /
    `CVE-2025-68121` / `CVE-2026-27143` ignores, cleared by crane v0.22.1.)
    **Check:** `grype <img> -o json | jq -r '.matches[] | select(.artifact.name=="stdlib") | .artifact.version + " " + .artifact.locations[0].path' | sort -u`
  - `CVE-2026-111497`: node 20.20.2 in the **actions/runner** tarball's
    `externals/node20` (runner 2.338.2). Clears on a runner release that bumps it.
  - `CVE-2026-115557`: python 3.14.8 bundled in **aws-cli** 2.39.3 (fixed in
    3.14.10). Clears once aws-cli rebundles.

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

- [x] **`e2e.yaml`'s `dind: [false, true]` + `include:` matrix silently
  collapsed to 2 jobs instead of 4, and never built/scanned amd64.** Caught
  from a real PR run (#14): the API showed only `e2e (false)`/`e2e (true)`,
  and both sticky PR comments read `arch=arm64`. Root cause: neither
  `include` entry set `dind`, so per GitHub's matrix-merge rules each entry
  (with no overlapping key) applied to *every* `dind` combo — the second
  entry (arm64) silently overwrote the first (amd64) for both dind states.
  Fixed 2026-08-26 by making the matrix a single fully-explicit 4-item
  `include:` list (no separate top-level `dind` key). Re-audit if the matrix
  is ever restructured again — this class of bug produces no error, just
  silently-missing coverage.

- [x] **`crane`'s prebuilt release binary carries the 2026 stdlib CVE
  cluster; `pull: true` was added but does NOT fix this (initial diagnosis
  was wrong — kept here corrected, not deleted).** PR #14's run flagged
  `GO-2026-4337`/`CVE-2025-68121`/`CVE-2026-27143` in `stdlib go1.25.0` —
  first assumed to be the `gitlfs` stage's `golang:1` base going stale on
  the runner, so `pull: true` was added to every `docker/build-push-action`
  step (still worth keeping, general hardening against base-image
  staleness). But a full local build + `grype` scan of the actual image
  showed the finding's location is `/usr/local/bin/crane`, not `git-lfs` —
  `git-lfs version` confirms `go 1.27.0` embedded, so the gitlfs stage is
  fine. `install_crane()` (`scripts/install-tools.sh`) always fetches
  upstream's `releases/latest`; as of `v0.22.0` (2026-08-25, confirmed via
  the GitHub API to be the actual latest tag), no `go-containerregistry`
  release yet embeds a patched Go — this is a genuine upstream gap, not a
  CI staleness bug. Fixed 2026-08-26 by adding a location-scoped
  (`/usr/local/bin/crane`) ignore for all three IDs in
  [`.grype.yaml`](.grype.yaml) + a README "CVEs left unfixed" row; verified
  the CI-equivalent `grype` invocation (`--fail-on critical --only-fixed`)
  exits 0 against a real build with the ignore in place, and that the ignore
  only matches the crane path (confirmed via `ignoredMatches` in JSON
  output), so a future stdlib regression elsewhere (e.g. git-lfs) won't be
  silently masked. Re-audit and drop the ignore once go-containerregistry
  cuts a release built with a fixed Go toolchain.

- [x] **kubectl `GO-2026-5026` and aws-cli `CVE-2026-6100` cleared
  2026-11-03.** kubectl 1.35.10 now ships `x/net v0.56.0` (>= the `v0.55.0`
  fix) and aws-cli 2.39.3 bundles python 3.14.8 (past `CVE-2026-6100`,
  `CVE-2026-3298`, `CVE-2026-4786`). The kubectl `.grype.yaml` ignore and both
  README rows were removed; confirmed absent from a fresh local scan of both
  image variants.

## Notes

- The CI gate (`build.yml`) only blocks on **fixable Criticals**. High-severity
  residuals are tracked in the README "CVEs left unfixed" table, not here.
- Every `.grype.yaml` ignore must have a corresponding row in the README table
  and an open item above.
