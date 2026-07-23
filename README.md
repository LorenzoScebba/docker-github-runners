# Hardened self-hosted GitHub Actions runner

A drop-in replacement for [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner)
on the **Ubuntu 24.04 (noble)** line, rebuilt to remove the vulnerability
cluster that dominates the upstream image's scan results.

It keeps the same entrypoint and environment-variable contract, so existing
deployments work without changes — only the image reference changes.

The remaining Criticals have a fix but no remediation path yet — `CVE-2026-6100`
(python in aws-cli) and `GO-2026-5026` (`x/net` in kubectl); see
[left unfixed](#cves-left-unfixed).

## What this image changes

| Fix                                                | Effect                                                                                                                                                                                                                                                                                                                                                                                                                                       |
|----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`gosu` → `setpriv` shim**                        | The apt `gosu` is a Go binary (`go1.22.2`) and the largest CVE source. Replaced by a tiny [`setpriv`](scripts/gosu) wrapper (util-linux, pure C) with identical "switch user + init groups + exec" behaviour. Kills `CVE-2024-24790`, `CVE-2025-22871`, `GO-2024-2887`, `GO-2025-3563`.                                                                                                                                                      |
| **Docker daemon / `containerd.io` not shipped**    | `containerd`'s binaries embed the grpc CVE. A runner that mounts the host `/var/run/docker.sock` only needs the **CLI** — so we install `docker-ce-cli` + buildx + compose and gate the daemon behind `INSTALL_DOCKER_DAEMON=true` (for docker-in-docker). Kills `GHSA-p77j-4mvh-x3m3`.                                                                                                                                                      |
| **`git-lfs` compiled from source**                 | The upstream release binary is built with a Go that still carries the 2026 stdlib CVEs. We rebuild it in a throwaway `golang` stage with current Go (cross-compiled, no QEMU), and force-upgrade `golang.org/x/net`→`v0.55.0` / `golang.org/x/crypto`→`v0.53.0` (the source tag still pins the vulnerable versions). Kills `CVE-2025-68121`, `CVE-2026-27143`, `GO-2026-4337`, and the `x/net`/`x/crypto` 2026 batch (`GO-2026-5005..5026`). |
| **`helm` from the official release, not apt**      | The buildkite apt repo lags and ships a helm built against the vulnerable `x/net`/`x/crypto`. We pull the `get.helm.sh` binary instead (`HELM_VERSION`, default `3.21.2` — the first 3.x with the fixed deps). Kills the `helm` `GO-2026-5005..5026` critical batch.                                                                                                                                                                         |
| **Node.js + npm from NodeSource, not apt**         | Ubuntu's apt `npm` drags in a stale Debian node-* tree — `handlebars` `4.7.7` (`CVE-2026-33937`) and `node-babel7` `7.20.x` (`CVE-2023-45133`), both critical. NodeSource's self-contained npm (`NODE_MAJOR`, default `24` LTS) avoids the whole tree.                                                                                                                                                                                       |
| **`apt-get upgrade -y`**                           | Closes the OS-package CVE tail at near-zero risk.                                                                                                                                                                                                                                                                                                                                                                                            |
| **`snapd` purged**                                 | Not just defensive: `snapd` is a Go binary that carries ~165 distinct CVEs (16 Critical — the same stale-Go stdlib + vendored `x/crypto` cluster the `gosu` shim removes). Purging it is the single biggest CVE reduction after `gosu`.                                                                                                                                                                                                      |
| **Google Chrome from Google's apt repo, not snap** | Ubuntu's apt `chromium` is a snap stub that pulls in `snapd` (see above) and won't even run once snap is stripped. We install `google-chrome-stable` from Google's own apt repo instead — a C++ binary grype finds nothing in, so it adds **zero** distinct CVEs. Symlinked to `chrome` on `PATH` for Cypress/Playwright/Selenium auto-detection. amd64 only (Google doesn't publish arm64 packages), so it's guarded to the amd64 image.    |
| **Container tooling opt-in**                       | `podman`/`buildah`/`skopeo`/CNI only with `INSTALL_CONTAINER_TOOLS=true` (Ubuntu-universe stale-Go binaries).                                                                                                                                                                                                                                                                                                                                |
| **`ffmpeg` from apt**                              | Needed by Playwright/Cypress to record video of failed test runs. A native C binary (not Go), so it adds no stale-Go CVEs over the base.                                                                                                                                                                                                                                                                                                     |
| **Runner pinned to `2.335.1`**                     | Latest; also the lever for the bundled `/actions-runner/externals` npm deps.                                                                                                                                                                                                                                                                                                                                                                 |
| **`rm -rf /var/lib/apt/lists/*` + `/tmp`**         | Smaller image and attack surface.                                                                                                                                                                                                                                                                                                                                                                                                            |

## Usage

Identical to `myoung34/github-runner`:

```bash
docker run -d --restart=always \
  -e RUNNER_NAME=my-runner \
  -e RUNNER_SCOPE=org \
  -e ORG_NAME=org-name \
  -e RUNNER_LABELS=docker,amd64 \
  -e APP_ID=123456 \
  -e APP_PRIVATE_KEY="$(cat key.pem)" \
  -e EPHEMERAL=1 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/lorenzoscebba/docker-github-runners:2.335.1-ubuntu-noble
```

Supported env vars match upstream: `ACCESS_TOKEN` or `APP_ID`/`APP_PRIVATE_KEY`
(+`APP_LOGIN`), `RUNNER_SCOPE` (`org`/`repo`/`enterprise`), `ORG_NAME`/
`REPO_URL`/`ENTERPRISE_NAME`, `RUNNER_NAME`, `RUNNER_WORKDIR`, `RUNNER_LABELS`,
`RUNNER_GROUP`, `EPHEMERAL`, `DISABLE_AUTO_UPDATE`, `RUN_AS_ROOT`,
`START_DOCKER_SERVICE`, `DEBUG_OUTPUT`, `DISABLE_AUTOMATIC_DEREGISTRATION`, etc.

### Rate limiting / ephemeral runners

For ephemeral deployments (`EPHEMERAL=1`), set **`DISABLE_AUTOMATIC_DEREGISTRATION=true`**.

An ephemeral runner processes exactly one job, then removes its own
registration from GitHub and exits. By the time the container's exit trap
fires, the runner is already gone — so the automatic deregistration path
(`entrypoint.sh` → `token.sh` → `config.sh remove`) mints a **second**
runner-registration token purely to run a no-op removal. With `ACCESS_TOKEN`
auth that doubles the calls to GitHub's `registration-token` endpoint per
runner (worse with `APP_ID`/`APP_PRIVATE_KEY`, which also re-lists app
installations); at churn this trips the PAT's 5,000/hr primary limit and
GitHub's secondary burst limit. Disabling deregistration for ephemeral runners
removes the redundant call.

This is safe for ephemeral runners:

- The startup registration is unchanged — the runner still registers normally.
- A runner killed *before* it picks up a job won't self-deregister and will
  leave an offline entry, but GitHub automatically removes an ephemeral runner
  that hasn't connected for more than **1 day** (vs. 14 days for
  non-ephemeral), so ghosts self-expire. With the default
  `RANDOM_RUNNER_SUFFIX=true` + `--replace`, they never block new
  registrations.

**Do not** set this on non-ephemeral runners — those never self-deregister, so
disabling it genuinely leaks registrations (lingering the full 14 days).

#### Prefer a pre-minted `RUNNER_TOKEN` over `APP_ID`/`APP_PRIVATE_KEY` at scale

The auth method determines how many *token-minting* REST calls each runner makes
before it can register — these are the calls that scale per-runner and consume
the org/App rate budget:

| Passed to the container      | Token-minting REST calls per runner | Endpoint(s) hit                                                                   |
|------------------------------|-------------------------------------|-----------------------------------------------------------------------------------|
| `APP_ID` + `APP_PRIVATE_KEY` | **3**                               | `GET /app/installations`, `POST .../access_tokens`, `POST .../registration-token` |
| `ACCESS_TOKEN` (PAT)         | **1**                               | `POST .../registration-token`                                                     |
| `RUNNER_TOKEN` (pre-minted)  | **0**                               | none — the token is used directly                                                 |

These counts are *on top of* the runner's own registration handshake:
`config.sh --token … --replace` always contacts GitHub once to register the
runner, and that happens identically for every auth method — it's intrinsic to
registering a runner and can't be avoided. What the table above measures is the
*extra* per-runner token minting that a pre-supplied `RUNNER_TOKEN` removes.

With App auth, every single runner re-lists the app's installations and mints a
fresh installation token *and* a registration token — so a burst of runners
hammers the App with three of these calls each, which is what trips the
secondary rate limit fastest. `POST .../registration-token` counts against the
core REST rate limit (see [actions/runner#1386](https://github.com/actions/runner/issues/1386)).

A runner-registration token is **valid for 1 hour and can register many
runners**, so the leanest pattern is to mint one centrally and reuse it:

```bash
# Mint once (e.g. in your scale-up controller), reuse for every runner
# started within the hour — one API call instead of one (or three) per runner.
RUNNER_TOKEN=$(gh api -X POST \
  /orgs/ORG_NAME/actions/runners/registration-token --jq .token)

docker run -d \
  -e RUNNER_SCOPE=org -e ORG_NAME=org-name \
  -e EPHEMERAL=1 -e DISABLE_AUTOMATIC_DEREGISTRATION=true \
  -e RUNNER_TOKEN="${RUNNER_TOKEN}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/lorenzoscebba/docker-github-runners:2.335.1-ubuntu-noble
```

Pass **only** `RUNNER_TOKEN` — do not also set `ACCESS_TOKEN` or `APP_ID`, or
the entrypoint will discard your token and mint a new one via the API anyway
(`entrypoint.sh` regenerates whenever `ACCESS_TOKEN`/`APP_ID` is present). This
takes the per-runner *token-minting* calls to zero and hits the App/PAT roughly
once per hour regardless of how many runners you churn. Each runner still
performs its own one-time `config.sh` registration handshake — that's
unavoidable and the same under any auth method.

## Build

```bash
docker build -t hardened-runner:noble .

# Docker-in-docker (adds dockerd + containerd.io — reintroduces the grpc CVE)
docker build --build-arg INSTALL_DOCKER_DAEMON=true -t hardened-runner:noble-dind .

# podman/buildah/skopeo (Ubuntu-universe stale-Go binaries)
docker build --build-arg INSTALL_CONTAINER_TOOLS=true -t hardened-runner:noble-containers .
```

Build args: `GH_RUNNER_VERSION`, `GIT_LFS_VERSION`, `HELM_VERSION`,
`KUBECTL_MINOR_VERSION`, `NODE_MAJOR`, `INSTALL_DOCKER_DAEMON` (default `false`),
`INSTALL_CONTAINER_TOOLS` (default `false`), `INSTALL_POWERSHELL` (default
`true`), `RUNNER_UID`/`RUNNER_GID`/`DOCKER_GID`.

## CVEs left unfixed

The CI gate (`.github/workflows/build.yml`) fails on any fixable Critical, so
the eliminated cluster cannot silently reappear. The following are accepted
residuals — those with a fix but no remediation path are ignored in
[`.grype.yaml`](.grype.yaml), re-audited on every version bump:

| CVE(s)                                                                      | Component                                                              | Why                                                                                                                                                                                                                                                                                                                                     |
|-----------------------------------------------------------------------------|------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `CVE-2026-6100` (Critical), `CVE-2026-3298`, `CVE-2026-4786` (High)         | python `3.14.5` bundled in **aws-cli v2**                              | grype reports no fixed version — no patched python ships upstream yet. aws-cli v2 always bundles its own interpreter.                                                                                                                                                                                                                   |
| `GO-2026-5026` (Critical, `x/net/idna`)                                     | `golang.org/x/net` `v0.49.0` in **kubectl**                            | Fixed in `x/net` `v0.55.0`, but no kubernetes release ships the bump yet (even `v1.36.2` pins `v0.49.0`), and building kubectl from source with a forced bump is impractical. Ignored in [`.grype.yaml`](.grype.yaml); clears when k8s bumps `x/net`.                                                                                   |
| `GHSA-23hp-3jrh-7fpw` / `CVE-2026-59873` (Critical, node-tar Gzip Bomb DoS) | `tar` bundled in npm (system + actions-runner node20/node24 externals) | Fixed in `tar@7.5.19`, but DoS-only (disk exhaustion) and only triggerable via an already-malicious npm dependency — accepted risk for a trusted-user-only fleet, not patched. node20's bundled npm 10.8.2 has no in-range fix available anyway (`tar ^6.2.1`, no patched 6.x release exists). Ignored in [`.grype.yaml`](.grype.yaml). |
| `tar`, `minimatch`, `glob`, `undici`, `cross-spawn` (npm, High)             | bundled in `/actions-runner/externals/node*`                           | Pinned by the `actions/runner` tarball (already on the latest, `2.335.1`). Clear when upstream refreshes its bundled deps.                                                                                                                                                                                                              |
| `docker` / `containerd` vendored modules (High)                             | inside `docker-ce-cli` / buildx / compose                              | Module-level findings in the CLI we keep; clear on the next Docker package bump (`apt upgrade`).                                                                                                                                                                                                                                        |
| `CVE-2024-52308` (High)                                                     | `gh`                                                                   | Upstream `wont-fix`.                                                                                                                                                                                                                                                                                                                    |
| podman/buildah/skopeo Go-stdlib CVEs                                        | container tooling                                                      | Only when `INSTALL_CONTAINER_TOOLS=true`; inherited from Ubuntu universe. Default builds don't ship these.                                                                                                                                                                                                                              |

## License

GPL-3.0, inherited from the upstream project. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE) for attribution of the reused runtime scripts.
