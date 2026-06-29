# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

Hardened drop-in replacement for [`myoung34/docker-github-actions-runner`](https://github.com/myoung34/docker-github-actions-runner) on Ubuntu 24.04 noble.
Identical entrypoint/env-var contract; the difference is in what gets shipped and patched to eliminate the CVE cluster that dominates the upstream image's grype
scan.

Typically deployed as ephemeral containers with a mounted `/var/run/docker.sock`, using env vars `RUNNER_NAME`, `RUNNER_SCOPE`, `ORG_NAME`, `APP_ID`,
`APP_PRIVATE_KEY`, `EPHEMERAL` to register against a GitHub org via GitHub App auth.

## Build commands

```bash
# Standard local build (amd64)
docker build -t hardened-runner:noble .

# With docker daemon (adds containerd.io — reintroduces GHSA-p77j-4mvh-x3m3)
docker build --build-arg INSTALL_DOCKER_DAEMON=true -t hardened-runner:noble-dind .

# Scan the built image for distinct CVE IDs
grype docker:hardened-runner:noble -o json | jq '[.matches[].vulnerability.id] | unique | sort'

# Produce a before/after diff (requires scan.sh)
bash scan.sh
```

There are no unit tests — correctness is validated by `grype` scan and the CI gate in `build.yml`.

## Architecture

### Two-stage Dockerfile

The `gitlfs` stage (`--platform=$BUILDPLATFORM`) builds git-lfs from source against a current Go toolchain, cross-compiling with `GOOS`/`GOARCH` (CGO off, no
QEMU). The upstream release binary ships a stale Go that carries the 2026 stdlib CVE cluster; rebuilding from source eliminates them. The stage also clones the
git-lfs tag (rather than `go install`-ing it) so it can `go get` forced upgrades of `golang.org/x/net` and `golang.org/x/crypto` — the source tag still pins
versions carrying the 2026 `x/net`/`x/crypto` critical batch (`GO-2026-5005..5026`).

The `ubuntu:noble` final stage:

1. `apt-get upgrade -y` (runs **before** any tool install — closes OS CVE tail)
2. Copies `scripts/gosu` shim (replaces the stale-Go apt `gosu` package; uses `setpriv` from util-linux)
3. Runs `scripts/install-tools.sh` (Docker CLI, git, gh, yq, aws-cli, powershell, kubectl, helm, Node.js). helm comes from the official `get.helm.sh` release (
   not the lagging buildkite apt repo); Node.js + npm come from NodeSource (not Ubuntu apt, which drags in a stale Debian node-* tree).
4. Copies git-lfs from the builder stage
5. Installs the runner tarball via `scripts/install_actions.sh`
6. Copies `entrypoint.sh`, `token.sh`, `app_token.sh` verbatim from upstream

### Key security decisions (and why they're where they are)

| Decision                                                 | Location                          | CVE(s) eliminated                                                |
|----------------------------------------------------------|-----------------------------------|------------------------------------------------------------------|
| `gosu` → `setpriv` shim                                  | `scripts/gosu` + Dockerfile       | CVE-2024-24790, CVE-2025-22871, GO-2024-2887, GO-2025-3563       |
| Docker daemon opt-in (`INSTALL_DOCKER_DAEMON=false`)     | `scripts/install-tools.sh`        | GHSA-p77j-4mvh-x3m3 (grpc in containerd.io)                      |
| git-lfs source build + forced `x/net`/`x/crypto` bump    | `gitlfs` stage                    | CVE-2025-68121, CVE-2026-27143, GO-2026-4337, GO-2026-5005..5026 |
| helm from `get.helm.sh` release (not buildkite apt)      | `install-tools.sh` `install_helm` | GO-2026-5005..5026 (`x/net`/`x/crypto` in helm)                  |
| Node.js from NodeSource (not Ubuntu apt `npm`)           | `install-tools.sh` `install_node` | CVE-2026-33937 (handlebars), CVE-2023-45133 (@babel/traverse)    |
| kubectl `GO-2026-5026` ignored (no upstream fix yet)     | `.grype.yaml`                     | — (tracked residual; re-audit on kubectl bump)                   |
| Container tools opt-in (`INSTALL_CONTAINER_TOOLS=false`) | `scripts/install-tools.sh`        | stale-Go Ubuntu-universe binaries                                |

### gosu shim

`scripts/gosu` is a POSIX shell wrapper around `setpriv`. It preserves the `gosu user:group cmd` and `gosu user cmd` call signatures that `entrypoint.sh` relies
on. It lives at `/usr/sbin/gosu` in the image so `entrypoint.sh` (`/usr/sbin/gosu runner "$@"`) works with zero changes.

### Runtime scripts

`entrypoint.sh`, `token.sh`, and `app_token.sh` are copied verbatim from upstream and **must not be patched** unless syncing a new upstream version.
`entrypoint.sh` handles runner registration via GitHub App (`APP_ID`/`APP_PRIVATE_KEY`) or PAT (`ACCESS_TOKEN`), deregistration on SIGTERM/EXIT, optional
`RUN_AS_ROOT`, and docker GID reconciliation for socket mounts.

### CI workflow (`build.yml`)

Single `workflow_dispatch` trigger. Steps in order:

1. Compute version tags by grepping `ARG GH_RUNNER_VERSION` from the Dockerfile — the Dockerfile is the **single source of truth** for the runner version.
2. Build amd64 + load locally (scan requires a local image; `--load` is incompatible with multi-arch).
3. grype scan with `severity-cutoff: critical` and `only-fixed: true` — only fails the build for fixable Criticals. `anchore/scan-action` auto-reads
   `.grype.yaml` at the repo root for ignore rules (currently the kubectl `GO-2026-5026` residual); each ignore is tracked in the README "CVEs left unfixed"
   table and must be re-audited on version bumps.
4. Upload SARIF to GitHub Security tab.
5. Push multi-arch (`linux/amd64,linux/arm64`) with tags `<ver>-ubuntu-noble` and `ubuntu-noble`.

The CI gate does **not** block on High-severity findings — these are tracked in the README "CVEs left unfixed" table and are either unfixable upstream or will
auto-resolve on the next `apt upgrade` / tool release.

## Versioning

To bump the runner version, edit `ARG GH_RUNNER_VERSION` in `Dockerfile` only — the workflow reads it at build time. See `UPDATING.md` for all pinned vs.
auto-refreshed components.

## Tracking / re-audit

`TODO.md` is the checklist of temporary hardening workarounds and outstanding verification (e.g. the kubectl `GO-2026-5026` `.grype.yaml` ignore, the git-lfs
forced `x/net`/`x/crypto` bump, the unrun full build+scan). **Walk it on every version bump and scheduled rebuild**, and keep it in sync: every `.grype.yaml`
ignore must have both a README "CVEs left unfixed" row and an open `TODO.md` item; delete an item once its workaround is no longer needed.