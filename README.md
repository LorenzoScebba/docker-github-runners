# Hardened self-hosted GitHub Actions runner

A drop-in replacement for [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner)
on the **Ubuntu 24.04 (noble)** line, rebuilt to remove the vulnerability
cluster that dominates the upstream image's scan results.

It keeps the same entrypoint and environment-variable contract, so existing
deployments work without changes — only the image reference changes.

## Why

A grype scan of an image derived from `myoung34/github-runner:*-ubuntu-noble`
surfaced 271 Critical + 1,772 High **matches**. Those raw counts are
misleading: they are ~12 distinct Critical CVEs each repeated across hundreds
of bundled Go binaries. The distinct CVEs come from two places:

1. **A stale-Go-stdlib cluster** in container/snap tooling — `snapd`, `podman`,
   `buildah`, `skopeo`, and the CNI plugins in `/usr/lib/cni/`, all compiled
   against Go 1.22.2 (`CVE-2024-24790`, `CVE-2025-22871`, the grpc
   `GHSA-p77j-4mvh-x3m3`, and friends). CNI alone is ~848 matches, snapd ~707,
   podman/buildah/skopeo ~265.
2. **An unpatched OS-package tail** (openssl, gnutls, perl, libxml2, libgcrypt)
   where fixes already exist in the Ubuntu repos — the upstream image
   `apt install`s but never `apt upgrade`s.

## What this image changes

| # | Fix                                            | Effect                                                                                                                                                          |
|---|------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | `apt-get upgrade -y` during build              | Closes the entire OS-package CVE tail (~53 CVEs incl. an openssl High) at near-zero risk.                                                                       |
| 2 | Container tooling is **opt-in**                | `podman`/`buildah`/`skopeo`/CNI are not installed unless `INSTALL_CONTAINER_TOOLS=true`. This removes ~1,100 of the stale-Go matches.                           |
| 2 | `snapd` purged                                 | Removes ~707 matches. CI runners never need snap.                                                                                                               |
| 3 | Docker from Docker's official repo             | `docker-ce`/`containerd.io`/`buildx`/`compose` are built against current Go upstream, unlike the Ubuntu-universe container stack. Docker-in-Docker still works. |
| 4 | Runner pinned to a current version (`2.335.1`) | Refreshes the npm deps bundled under `/actions-runner/externals`. Bump `GH_RUNNER_VERSION` to pull newer deps as they ship.                                     |
| 5 | `rm -rf /var/lib/apt/lists/*` + `/tmp`         | Smaller image, smaller attack surface.                                                                                                                          |

### Why not rebuild podman/buildah/skopeo with Go ≥ 1.24?

Those binaries are **apt-installed from Ubuntu's universe repo**, not built
here. Recompiling them with a newer Go would mean vendoring and maintaining the
whole container stack, which defeats the point of an apt-based image. The
correct lever is therefore #2 (don't ship them) — and when you do need them
(`INSTALL_CONTAINER_TOOLS=true`), the CVEs are inherited from Ubuntu and clear
themselves once Ubuntu ships patched packages, picked up automatically by #1.

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

# Opt into the container stack if a workflow genuinely needs podman/buildah/skopeo
docker build --build-arg INSTALL_CONTAINER_TOOLS=true -t hardened-runner:noble-containers .
```

Build args: `GH_RUNNER_VERSION`, `INSTALL_CONTAINER_TOOLS` (default `false`),
`INSTALL_POWERSHELL` (default `true`), `RUNNER_UID`/`RUNNER_GID`/`DOCKER_GID`.

## CVEs intentionally left unfixed

| CVE                                  | Component         | Why                                                                                                                                                              |
|--------------------------------------|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `CVE-2026-6100`                      | python `3.14.x`   | No upstream fix available yet. Picked up automatically by `apt upgrade` (#1) once Ubuntu ships it.                                                               |
| podman/buildah/skopeo Go-stdlib CVEs | container tooling | Only present when `INSTALL_CONTAINER_TOOLS=true`. Inherited from Ubuntu universe; clears when Ubuntu rebuilds with a newer Go. Default builds do not ship these. |

## License

GPL-3.0, inherited from the upstream project. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE) for attribution of the reused runtime scripts.
