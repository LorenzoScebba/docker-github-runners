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
| All OS packages             | `apt-get upgrade -y`                      |

Because of these, **rebuilding on a schedule is itself an upgrade** — it picks
up new tool releases and security-patched OS packages. A monthly rebuild (or
whenever a CVE you care about gets a fix) is a reasonable cadence.

> If you ever need fully reproducible images, pin these too (replace the
> `releases/latest` lookups in [`scripts/install-tools.sh`](scripts/install-tools.sh)
> with explicit versions). The trade-off is you then own keeping them current.
