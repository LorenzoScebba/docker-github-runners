# Updating

How to upgrade the components baked into this image. Two categories:

- **Pinned** — a version literal lives in the repo and must be edited to change.
- **Auto-refreshed** — fetched as "latest" at build time, so a plain rebuild
  picks up the newest version. Rebuild regularly (it also re-runs
  `apt upgrade`, closing the OS-package CVE tail).

---

## Pinned components

| Component                    | Where                                                                                                            | Default                    |
|------------------------------|------------------------------------------------------------------------------------------------------------------|----------------------------|
| GitHub Actions runner        | `GH_RUNNER_VERSION` in [`Dockerfile`](Dockerfile)                                                                | `2.335.1`                  |
| git-lfs                      | `GIT_LFS_VERSION` in [`Dockerfile`](Dockerfile) (`gitlfs` stage)                                                 | `3.7.1`                    |
| git-lfs `x/net` / `x/crypto` | `GO_X_NET_VERSION` / `GO_X_CRYPTO_VERSION` in [`Dockerfile`](Dockerfile) (`gitlfs` stage)                        | `v0.55.0` / `v0.53.0`      |
| helm                         | `HELM_VERSION` in [`Dockerfile`](Dockerfile)                                                                     | `3.21.2`                   |
| Node.js (major)              | `NODE_MAJOR` in [`Dockerfile`](Dockerfile) (NodeSource repo)                                                     | `24` (LTS)                 |
| kubectl (minor)              | `KUBECTL_MINOR_VERSION` in [`Dockerfile`](Dockerfile)                                                            | `1.35`                     |
| Ubuntu base                  | `FROM ubuntu:noble` in [`Dockerfile`](Dockerfile)                                                                | `noble` (24.04 LTS)        |
| Go toolchain (git-lfs build) | `FROM golang:1` in [`Dockerfile`](Dockerfile) (`gitlfs` stage)                                                   | `golang:1` (latest stable) |
| CI action versions           | `uses:` lines in [`.github/workflows/build.yml`](.github/workflows/build.yml)                                    | `@v4`/`@v7`                |
 
### GitHub Actions runner version

This is the one you'll bump most often. It also refreshes the npm deps bundled
under `/actions-runner/externals/node*` (a source of the residual High CVEs).

Find the latest release:

```bash
curl -fsSL -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name'
```

Update the single source of truth — `ARG GH_RUNNER_VERSION="…"` in
[`Dockerfile`](Dockerfile) — then run the `build` workflow (*Actions → build →
Run workflow*). The workflow reads the version straight out of the Dockerfile
ARG to compute the image tags, so there's nothing else to keep in sync.

The runner tarball's checksum is verified at build time (see
[`scripts/install_actions.sh`](scripts/install_actions.sh)); no checksum to
update by hand.

### git-lfs version

We compile git-lfs from source with a current Go (the upstream release binary
ships a stale Go stdlib). To bump:

```bash
curl -fsSL https://api.github.com/repos/git-lfs/git-lfs/releases/latest | jq -r '.tag_name'
```

Update `ARG GIT_LFS_VERSION="…"` in the `gitlfs` stage of [`Dockerfile`](Dockerfile).

The `gitlfs` stage also force-upgrades `golang.org/x/net` and
`golang.org/x/crypto` (`GO_X_NET_VERSION` / `GO_X_CRYPTO_VERSION`) because the
git-lfs source tag still pins versions carrying the 2026 `x/net`/`x/crypto`
critical batch (`GO-2026-5005..5026`). When a git-lfs release ships go.mod deps
at or above these, the `go get` is a harmless no-op; bump the pins if a newer
advisory raises the fixed floor.

### helm version

helm is pulled from the official `get.helm.sh` release binary, **not** the
buildkite apt repo (which lags and ships a helm built against the vulnerable
`x/net`/`x/crypto`). To bump, set `ARG HELM_VERSION="…"` in
[`Dockerfile`](Dockerfile). Find the latest 3.x:

```bash
curl -fsSL https://api.github.com/repos/helm/helm/releases \
  | jq -r '[.[].tag_name | select(startswith("v3."))][0]'
```

Staying on helm 3.x avoids the helm 4 breaking changes. The release floor for
the `GO-2026-5005..5026` fix is `3.21.2`.

### Node.js (NodeSource)

Node.js + npm come from the NodeSource apt repo, **not** Ubuntu's apt `npm`
(which drags in a stale Debian node-* tree — `handlebars` / `node-babel7` — that
carries critical CVEs). `NODE_MAJOR` in [`Dockerfile`](Dockerfile) selects the
Node major line (default `24` LTS); within that major a rebuild auto-refreshes
to the newest patch.

### kubectl and the `.grype.yaml` ignore

kubectl is installed from the kubernetes apt repo at the `KUBECTL_MINOR_VERSION`
minor line (auto-refreshed to the newest patch on rebuild). Its only Critical,
`GO-2026-5026` (`x/net/idna`), has no remediation path — no k8s release ships
`x/net` ≥ `v0.55.0` yet — so it is ignored in [`.grype.yaml`](.grype.yaml).
**Re-audit that ignore on every rebuild:** once a kubernetes release bundles the
fixed `x/net`, bump `KUBECTL_MINOR_VERSION` and delete the ignore rule.

### Go toolchain (for the git-lfs build)

`FROM golang:1` tracks the latest stable Go automatically, so a rebuild already
compiles git-lfs with the newest patched toolchain — this is what keeps the
git-lfs stdlib CVEs closed. Pin it (e.g. `golang:1.26`) only if you need
reproducible builds; if you do, make sure the pinned minor is recent enough to
include the latest stdlib fixes, then re-scan.

### Ubuntu base

Stay on `noble` (24.04 **LTS**, supported to 2029) — it matches the Konnect
fleet, and the base layer carries no CVEs after `apt upgrade`. Only move to the
next LTS (e.g. `26.04`) once it's released and the fleet migrates; a rebuild on
the new base is otherwise a one-line `FROM` change. Avoid interim
(non-LTS) releases.

### CI action versions

The `uses:` pins in [`.github/workflows/build.yml`](.github/workflows/build.yml)
(`actions/checkout`, `docker/*`, `anchore/scan-action`) are updated like any
other GitHub Action — bump the tag and confirm the workflow still runs.

---

## Auto-refreshed components (rebuild to update)

These pull the latest version at build time — no pin to edit, just rebuild:

| Component                   | Source                                    |
|-----------------------------|-------------------------------------------|
| Docker CLI, buildx, compose | Docker `apt` repo (`download.docker.com`) |
| GitHub CLI (`gh`)           | latest GitHub release                     |
| `yq`                        | latest GitHub release                     |
| AWS CLI v2                  | `awscli.amazonaws.com` (always latest)    |
| PowerShell                  | latest GitHub release                     |
| Chrome for Testing (amd64)  | `chrome-for-testing` Stable channel JSON  |
| All OS packages             | `apt-get upgrade -y`                      |

Because of these, **rebuilding on a schedule is itself an upgrade** — it picks
up new tool releases and security-patched OS packages. A monthly rebuild (or
whenever a CVE you care about gets a fix) is a reasonable cadence.

> If you ever need fully reproducible images, pin these too (replace the
> `releases/latest` lookups in [`scripts/install-tools.sh`](scripts/install-tools.sh)
> with explicit versions). The trade-off is you then own keeping them current.
