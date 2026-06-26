# Hardened self-hosted GitHub Actions runner

A drop-in replacement for [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner)
on the **Ubuntu 24.04 (noble)** line, rebuilt to remove the vulnerability
cluster that dominates the upstream image's scan results.

It keeps the same entrypoint and environment-variable contract, so existing
deployments work without changes — only the image reference changes.

## Result

Distinct CVE IDs (grype, amd64), this image vs. an image built like the
upstream:

| Severity | Before | After |
|----------|-------:|------:|
| Critical | 9      | **1** |
| High     | 73     | **23** |

The single remaining Critical is `CVE-2026-6100` (see [left unfixed](#cves-left-unfixed)).

## Why

The raw scan numbers (271 Critical / 1,772 High **matches**) are misleading —
they're a handful of distinct CVEs each repeated across hundreds of bundled
binaries. Tracking **distinct CVE IDs** and attributing each to the binary that
carries it (grype reports the embedded Go build info / package version), the
9 Criticals came from exactly four places — none of them the Ubuntu base, and
not where the original brief assumed:

| Source binary | Distinct Criticals | Note |
|---|---|---|
| `gosu` (Ubuntu apt, built `go1.22.2`) | 7 | stale Go stdlib — the dominant source |
| `containerd` / `ctr` / shim (`containerd.io`) | 1 | grpc `v1.78.0` — `GHSA-p77j-4mvh-x3m3` |
| `git-lfs` (upstream release, built `go1.25.3`) | 3 | newest 2026 stdlib CVEs (shared with `gosu`) |
| `python 3.14.5` bundled in aws-cli v2 | 1 | `CVE-2026-6100`, no upstream fix |

Zero Criticals (and only one `deb`-sourced High) came from Ubuntu packages —
`apt upgrade` already takes the base layer to clean, so the OS release version
is irrelevant to these findings.

## What this image changes

| Fix | Effect |
|-----|--------|
| **`gosu` → `setpriv` shim** | The apt `gosu` is a Go binary (`go1.22.2`) and the largest CVE source. Replaced by a tiny [`setpriv`](scripts/gosu) wrapper (util-linux, pure C) with identical "switch user + init groups + exec" behaviour. Kills `CVE-2024-24790`, `CVE-2025-22871`, `GO-2024-2887`, `GO-2025-3563`. |
| **Docker daemon / `containerd.io` not shipped** | `containerd`'s binaries embed the grpc CVE. A runner that mounts the host `/var/run/docker.sock` only needs the **CLI** — so we install `docker-ce-cli` + buildx + compose and gate the daemon behind `INSTALL_DOCKER_DAEMON=true` (for docker-in-docker). Kills `GHSA-p77j-4mvh-x3m3`. |
| **`git-lfs` compiled from source** | The upstream release binary is built with a Go that still carries the 2026 stdlib CVEs. We rebuild it in a throwaway `golang` stage with current Go (cross-compiled, no QEMU). Kills `CVE-2025-68121`, `CVE-2026-27143`, `GO-2026-4337`. |
| **`apt-get upgrade -y`** | Closes the OS-package CVE tail at near-zero risk. |
| **`snapd` purged** | Defensive — CI runners never need snap. |
| **Container tooling opt-in** | `podman`/`buildah`/`skopeo`/CNI only with `INSTALL_CONTAINER_TOOLS=true` (Ubuntu-universe stale-Go binaries). |
| **Runner pinned to `2.335.1`** | Latest; also the lever for the bundled `/actions-runner/externals` npm deps. |
| **`rm -rf /var/lib/apt/lists/*` + `/tmp`** | Smaller image and attack surface. |

### Why not just use a newer Ubuntu base (e.g. 25.10)?

It wouldn't move any of these CVEs — they're all in tooling layered on top
(`gosu` aside, which the shim handles), and `containerd.io`/`git-lfs` come from
Docker's repo and an upstream release, not Ubuntu. `apt upgrade` already makes
the base clean. A newer non-LTS base (25.10 reaches EOL ~July 2026) would only
shorten support and diverge from the noble LTS fleet.

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

## Build

```bash
docker build -t hardened-runner:noble .

# Docker-in-docker (adds dockerd + containerd.io — reintroduces the grpc CVE)
docker build --build-arg INSTALL_DOCKER_DAEMON=true -t hardened-runner:noble-dind .

# podman/buildah/skopeo (Ubuntu-universe stale-Go binaries)
docker build --build-arg INSTALL_CONTAINER_TOOLS=true -t hardened-runner:noble-containers .
```

Build args: `GH_RUNNER_VERSION`, `GIT_LFS_VERSION`, `INSTALL_DOCKER_DAEMON`
(default `false`), `INSTALL_CONTAINER_TOOLS` (default `false`),
`INSTALL_POWERSHELL` (default `true`), `RUNNER_UID`/`RUNNER_GID`/`DOCKER_GID`.

## CVEs left unfixed

The CI gate (`.github/workflows/build.yml`) fails if the eliminated cluster
reappears. The following are accepted residuals:

| CVE(s) | Component | Why |
|--------|-----------|-----|
| `CVE-2026-6100` (Critical), `CVE-2026-3298`, `CVE-2026-4786` (High) | python `3.14.5` bundled in **aws-cli v2** | grype reports no fixed version — no patched python ships upstream yet. aws-cli v2 always bundles its own interpreter. |
| `tar`, `minimatch`, `glob`, `undici`, `cross-spawn` (npm, High) | bundled in `/actions-runner/externals/node*` | Pinned by the `actions/runner` tarball (already on the latest, `2.335.1`). Clear when upstream refreshes its bundled deps. |
| `docker` / `containerd` vendored modules (High) | inside `docker-ce-cli` / buildx / compose | Module-level findings in the CLI we keep; clear on the next Docker package bump (`apt upgrade`). |
| `CVE-2024-52308` (High) | `gh` | Upstream `wont-fix`. |
| podman/buildah/skopeo Go-stdlib CVEs | container tooling | Only when `INSTALL_CONTAINER_TOOLS=true`; inherited from Ubuntu universe. Default builds don't ship these. |

## License

GPL-3.0, inherited from the upstream project. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE) for attribution of the reused runtime scripts.
