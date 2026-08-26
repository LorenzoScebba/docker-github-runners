# Hardened self-hosted GitHub Actions runner

A drop-in replacement for [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner)
on the **Ubuntu 24.04 (noble)** line, rebuilt to remove the vulnerability cluster that dominates the upstream image's scan results.

It keeps the same entrypoint and environment-variable contract, so existing deployments work without changes — only the image reference changes.

The remaining Criticals have a fix but no remediation path yet — `CVE-2026-6100`
(python in aws-cli) and `GO-2026-5026` (`x/net` in kubectl); see
[left unfixed](#cves-left-unfixed).

## What this image changes

| Fix                                                        | Effect                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`gosu` → `setpriv` shim**                                | The apt `gosu` is a Go binary (`go1.22.2`) and the largest CVE source. Replaced by a tiny [`setpriv`](scripts/gosu) wrapper (util-linux, pure C) with identical "switch user + init groups + exec" behaviour. Kills `CVE-2024-24790`, `CVE-2025-22871`, `GO-2024-2887`, `GO-2025-3563`.                                                                                                                                                                                                                                |
| **Docker daemon / `containerd.io` not shipped by default** | `containerd`'s binaries embed a grpc CVE and, together with `runc`, carry their own Go-stdlib-adjacent CVE surface (currently a handful of High-severity `x/net`/`x/mod`/grpc findings — see the CVE table below). A runner that mounts the host `/var/run/docker.sock` only needs the **CLI** — so we install `docker-ce-cli` + buildx + compose by default and gate the daemon behind `INSTALL_DOCKER_DAEMON=true`. See [Docker-in-Docker](#docker-in-docker) for when you'd want it and the runtime flags it needs. |
| **`git-lfs` compiled from source**                         | The upstream release binary is built with a Go that still carries the 2026 stdlib CVEs. We rebuild it in a throwaway `golang` stage with current Go (cross-compiled, no QEMU), and force-upgrade `golang.org/x/net`→`v0.55.0` / `golang.org/x/crypto`→`v0.53.0` (the source tag still pins the vulnerable versions). Kills `CVE-2025-68121`, `CVE-2026-27143`, `GO-2026-4337`, and the `x/net`/`x/crypto` 2026 batch (`GO-2026-5005..5026`).                                                                           |
| **`helm` from the official release, not apt**              | The buildkite apt repo lags and ships a helm built against the vulnerable `x/net`/`x/crypto`. We pull the `get.helm.sh` binary instead (`HELM_VERSION`, default `3.21.2` — the first 3.x with the fixed deps). Kills the `helm` `GO-2026-5005..5026` critical batch.                                                                                                                                                                                                                                                   |
| **Node.js + npm from NodeSource, not apt**                 | Ubuntu's apt `npm` drags in a stale Debian node-* tree — `handlebars` `4.7.7` (`CVE-2026-33937`) and `node-babel7` `7.20.x` (`CVE-2023-45133`), both critical. NodeSource's self-contained npm (`NODE_MAJOR`, default `24` LTS) avoids the whole tree.                                                                                                                                                                                                                                                                 |
| **`apt-get upgrade -y`**                                   | Closes the OS-package CVE tail at near-zero risk.                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **`snapd` purged**                                         | Not just defensive: `snapd` is a Go binary that carries ~165 distinct CVEs (16 Critical — the same stale-Go stdlib + vendored `x/crypto` cluster the `gosu` shim removes). Purging it is the single biggest CVE reduction after `gosu`.                                                                                                                                                                                                                                                                                |
| **Google Chrome from Google's apt repo, not snap**         | Ubuntu's apt `chromium` is a snap stub that pulls in `snapd` (see above) and won't even run once snap is stripped. We install `google-chrome-stable` from Google's own apt repo instead — a C++ binary grype finds nothing in, so it adds **zero** distinct CVEs. Symlinked to `chrome` on `PATH` for Cypress/Playwright/Selenium auto-detection. Installed on both amd64 and arm64 (Google now publishes arm64 packages).                                                                                             |
| **Container tooling opt-in**                               | `podman`/`buildah`/`skopeo`/CNI only with `INSTALL_CONTAINER_TOOLS=true` (Ubuntu-universe stale-Go binaries).                                                                                                                                                                                                                                                                                                                                                                                                          |
| **`ffmpeg` from apt**                                      | Needed by Playwright/Cypress to record video of failed test runs. A native C binary (not Go), so it adds no stale-Go CVEs over the base.                                                                                                                                                                                                                                                                                                                                                                               |
| **Runner pinned to `2.335.1`**                             | Latest; also the lever for the bundled `/actions-runner/externals` npm deps.                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **`rm -rf /var/lib/apt/lists/*` + `/tmp`**                 | Smaller image and attack surface.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

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

An ephemeral runner processes exactly one job, then removes its own registration from GitHub and exits. By the time the container's exit trap fires, the runner
is already gone — so the automatic deregistration path (`entrypoint.sh` → `token.sh` → `config.sh remove`) mints a **second**
runner-registration token purely to run a no-op removal. With `ACCESS_TOKEN`
auth that doubles the calls to GitHub's `registration-token` endpoint per runner (worse with `APP_ID`/`APP_PRIVATE_KEY`, which also re-lists app installations);
at churn this trips the PAT's 5,000/hr primary limit and GitHub's secondary burst limit. Disabling deregistration for ephemeral runners removes the redundant
call.

This is safe for ephemeral runners:

- The startup registration is unchanged — the runner still registers normally.
- A runner killed *before* it picks up a job won't self-deregister and will leave an offline entry, but GitHub automatically removes an ephemeral runner that
  hasn't connected for more than **1 day** (vs. 14 days for non-ephemeral), so ghosts self-expire. With the default
  `RANDOM_RUNNER_SUFFIX=true` + `--replace`, they never block new registrations.

**Do not** set this on non-ephemeral runners — those never self-deregister, so disabling it genuinely leaks registrations (lingering the full 14 days).

#### Prefer a pre-minted `RUNNER_TOKEN` over `APP_ID`/`APP_PRIVATE_KEY` at scale

The auth method determines how many *token-minting* REST calls each runner makes before it can register — these are the calls that scale per-runner and consume
the org/App rate budget:

| Passed to the container      | Token-minting REST calls per runner | Endpoint(s) hit                                                                   |
|------------------------------|-------------------------------------|-----------------------------------------------------------------------------------|
| `APP_ID` + `APP_PRIVATE_KEY` | **3**                               | `GET /app/installations`, `POST .../access_tokens`, `POST .../registration-token` |
| `ACCESS_TOKEN` (PAT)         | **1**                               | `POST .../registration-token`                                                     |
| `RUNNER_TOKEN` (pre-minted)  | **0**                               | none — the token is used directly                                                 |

These counts are *on top of* the runner's own registration handshake:
`config.sh --token … --replace` always contacts GitHub once to register the runner, and that happens identically for every auth method — it's intrinsic to
registering a runner and can't be avoided. What the table above measures is the *extra* per-runner token minting that a pre-supplied `RUNNER_TOKEN` removes.

With App auth, every single runner re-lists the app's installations and mints a fresh installation token *and* a registration token — so a burst of runners
hammers the App with three of these calls each, which is what trips the secondary rate limit fastest. `POST .../registration-token` counts against the core REST
rate limit (see [actions/runner#1386](https://github.com/actions/runner/issues/1386)).

A runner-registration token is **valid for 1 hour and can register many runners**, so the leanest pattern is to mint one centrally and reuse it:

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

Pass **only** `RUNNER_TOKEN` — do not also set `ACCESS_TOKEN` or `APP_ID`, or the entrypoint will discard your token and mint a new one via the API anyway
(`entrypoint.sh` regenerates whenever `ACCESS_TOKEN`/`APP_ID` is present). This takes the per-runner *token-minting* calls to zero and hits the App/PAT roughly
once per hour regardless of how many runners you churn. Each runner still performs its own one-time `config.sh` registration handshake — that's unavoidable and
the same under any auth method.

## Docker-in-Docker

The default deployment mounts the host's `/var/run/docker.sock` (see
[Usage](#usage) above) — the runner only needs the Docker **CLI** for that, which is always installed. If you can't mount the host socket (e.g. the host doesn't
run Docker, or you want job containers fully isolated from it), build the `-dind` image instead so the runner brings its own `dockerd`:

```bash
docker build --build-arg INSTALL_DOCKER_DAEMON=true -t hardened-runner:noble-dind .
```

or pull the image CI already builds and scans for you:
`ghcr.io/lorenzoscebba/docker-github-runners:<ver>-ubuntu-noble-dind`.

Running it needs different `docker run` flags than the socket-mount pattern:

```bash
docker run -d --restart=always \
  --privileged \
  --tmpfs /var/lib/docker \
  -e RUNNER_NAME=my-runner \
  -e RUNNER_SCOPE=org \
  -e ORG_NAME=org-name \
  -e RUNNER_LABELS=docker,amd64 \
  -e APP_ID=123456 \
  -e APP_PRIVATE_KEY="$(cat key.pem)" \
  -e EPHEMERAL=1 \
  -e START_DOCKER_SERVICE=true \
  ghcr.io/lorenzoscebba/docker-github-runners:2.336.0-ubuntu-noble-dind
```

| Requirement                                       | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
|---------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--privileged`                                    | Running a nested `dockerd` needs kernel-level access (mounts, cgroups, networking) that an unprivileged container doesn't have. A curated `--cap-add`/`--device` set can work instead if your orchestrator forbids `--privileged`, but that is untested here.                                                                                                                                                                                                 |
| `--tmpfs /var/lib/docker` (or a dedicated volume) | **Required**, not just a performance tweak: this image's own root filesystem is itself an overlay mount, and Docker's default `overlay2` storage driver cannot layer on top of another overlay filesystem — confirmed locally, it fails with `mount ... fstype: overlay ... invalid argument`. Giving `dockerd` a non-overlay backing filesystem (`tmpfs` for ephemeral runners, or a named volume if you want the image cache to survive restarts) fixes it. |
| `-e START_DOCKER_SERVICE=true`                    | Tells `entrypoint.sh` to run `service docker start`. The image also chains a `docker-ready.sh` CMD wrapper (see [`CLAUDE.md`](CLAUDE.md)) that waits for `dockerd` to actually accept connections before the runner picks up a job, and stops it cleanly on shutdown — both gated on this same variable, so non-DinD deployments are unaffected.                                                                                                              |

Everything else (env vars, ephemeral/rate-limiting guidance, metrics) is identical to the socket-mount deployment above.

## Runner metrics

Fleet observability normally means polling GitHub's REST API to enumerate runners and their state (e.g. `github-org-runner-exporter`) — **N calls that compete
for the very rate-limit budget** the ephemeral-runner path above is trying to conserve. Instead, each runner **pushes** its own metrics, so the GitHub API is
never touched for observability.

The runner reports **whether it is idle or busy, and which workflow/job it is running when busy**, plus job throughput and duration. It is **off by default**:
with `RUNNER_METRICS_STATSD_ADDR` unset the hooks are no-ops and the image behaves exactly like upstream — enabling it adds **no new package** to the image
(emission is statsd-over-UDP via bash's built-in `/dev/udp`, so the grype scan is unchanged).

### How it works

Ephemeral runners live for one job (often <1 min), so Prometheus can't scrape them directly — they push instead. A container reports its state via a set of
in-image scripts under `/actions-runner/hooks/`:

- a **CMD wrapper** launches a background **heartbeat** that re-emits this runner's `idle`/`busy` gauge every `RUNNER_METRICS_HEARTBEAT_INTERVAL`;
- the runner's **job-started / job-completed hooks** flip that state (and emit the job counters + duration);
- a **config wrapper** reports the GitHub API budget left at registration (see
  [below](#github-api-budget)).

All runners across all hosts send UDP to **one central `statsd_exporter`**, which Prometheus scrapes as a single target. Because `runner` is a label, N runners
land as N distinct series in one place — that fan-in is what replaces the N GitHub API calls.

```
runners (all hosts) ──UDP:9125──▶ statsd_exporter ──scrape:9102──▶ Prometheus
```

The heartbeat re-emitting on an interval is also the **self-heal**: a runner killed mid-job stops refreshing, and `statsd_exporter`'s per-metric TTL expires its
series a few missed heartbeats later — so a `SIGKILL`'d container drops out of the counts instead of showing "busy" forever.

A graceful stop doesn't have to wait for that TTL, though: the CMD wrapper forks a small watcher alongside `exec`-ing into `Runner.Listener` (same PID, so the
watcher just polls for it to disappear) and, the instant it exits, sends one last `idle:0`/`busy:0` pair — clearing the runner out of `sum by
(state)` immediately instead of lingering for up to the TTL. This is what catches an **idle** runner being stopped (`docker stop` / scale-down with no job
running), which no job hook ever sees. A `SIGKILL` of the whole container still takes the watcher out with everything else — that case has no code path left to
run and continues to rely on the TTL.

### Enable it

Point every runner at the shared exporter:

```bash
docker run -d \
  -e RUNNER_SCOPE=org -e ORG_NAME=org-name -e EPHEMERAL=1 \
  -e RUNNER_METRICS_STATSD_ADDR=statsd.metrics.internal:9125 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/lorenzoscebba/docker-github-runners:2.335.1-ubuntu-noble
```

| Env var                             | Default         | Purpose                                                                                                                                              |
|-------------------------------------|-----------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `RUNNER_METRICS_STATSD_ADDR`        | *(unset)*       | `host:port` of the central `statsd_exporter`. **Master switch** — unset ⇒ metrics off. Same value for every runner.                                  |
| `RUNNER_METRICS_HEARTBEAT_INTERVAL` | `15`            | Seconds between gauge refreshes. Keep the exporter's gauge TTL ≥ 2×.                                                                                 |
| `RUNNER_METRICS_PREFIX`             | `github_runner` | Metric name prefix.                                                                                                                                  |
| `RUNNER_METRICS_EXTRA_LABELS`       | *(none)*        | Static dogstatsd tags added to every metric, e.g. `cluster:prod,env:ci`.                                                                             |
| `RUNNER_METRICS_DEBUG`              | *(off)*         | `1` logs every emit and every send failure to stderr (`docker logs`) and `/tmp/runner-metrics.log`. See [Troubleshooting](#troubleshooting-metrics). |

### Metrics exposed

| Metric                                   | Type          | Labels                                                                          |
|------------------------------------------|---------------|---------------------------------------------------------------------------------|
| `github_runner_status`                   | gauge (TTL'd) | `labels`, `state` (`idle`\|`busy`); + `repo`,`workflow`,`job`,`event` when busy |
| `github_runner_jobs_started_total`       | counter       | `labels`, `repo`, `workflow`, `job`, `event`                                    |
| `github_runner_jobs_completed_total`     | counter       | `labels`, `repo`, `workflow`, `job`, `event`                                    |
| `github_runner_job_duration_seconds`     | histogram     | `labels`, `repo`, `workflow`, `job`, `event`                                    |
| `github_runner_api_rate_limit_remaining` | gauge (TTL'd) | `labels`                                                                        |

```promql
# Live free vs busy across the whole fleet, broken down by runner pool
sum by (labels, state) (github_runner_status)

# Which workflow/job is running per busy pool
github_runner_status{state="busy"} == 1

# Throughput and p95 job duration
sum by (workflow) (rate(github_runner_jobs_started_total[5m]))
histogram_quantile(0.95, sum by (le, workflow) (rate(github_runner_job_duration_seconds_bucket[15m])))

# GitHub REST budget left, and how fast registrations are burning it
min(github_runner_api_rate_limit_remaining)
```

Cardinality is kept bounded on purpose: unbounded fields (`run_id`, `sha`,
`actor`) are **never** used as labels, and neither `runner` nor `org` appear on any metric — pools are told apart by `labels` (from `RUNNER_LABELS`/
`LABELS`) alone. This means `github_runner_status` is per-pool, not per-runner: when several runners share the same `labels` value, each writes the same `idle`/
`busy` series, and — being a gauge — the last write wins rather than summing. Use `sum by (state) (...)` for "is at least one runner in this pool busy", not for
a per-runner count.

### GitHub API budget

Registering a runner costs one request against GitHub's **`actions_runner_registration`** rate-limit resource, and at churn that budget is the thing most likely
to break a fleet — so
`github_runner_api_rate_limit_remaining` reports how much of it is left.

Note this is its **own bucket**, not the core REST budget: GitHub answers the registration call with `x-ratelimit-resource: actions_runner_registration`, so
this number moves independently of the 5,000/hr PAT (or 15,000/hr App) core limit that [token minting](#rate-limiting--ephemeral-runners) draws on. It is the
one that scales with how fast you churn runners.

Getting that number is less obvious than it looks. It lives on the
`X-RateLimit-Remaining` response header of the registration call the runner makes **itself** (`POST .../actions/runner-registration`), which happens inside
`Runner.Listener` over TLS — no runtime script ever sees it. Asking GitHub afterwards isn't an option either: at scale the recommended setup passes
a [pre-minted `RUNNER_TOKEN`](#prefer-a-pre-minted-runner_token-over-app_idapp_private_key-at-scale), so there is no PAT or App key in the container to call
`/rate_limit` with — and spending an API request to measure the API budget is self-defeating.

Instead we read the response the runner already received. The runner has a built-in `GITHUB_ACTIONS_RUNNER_HTTPTRACE` mode that dumps its HTTP traffic — headers
included — into its own diag log. The image installs a wrapper as
`/actions-runner/config.sh` (the runner's own script is moved to
`config.real.sh`) which turns that trace on **for the registration invocation only**, pulls `X-RateLimit-Remaining` off the registration response, emits it, and
returns the real script's exit code untouched. **Zero extra API calls.**

Worth knowing:

- **The trace is scoped to registration.** `Runner.Listener` runs as a separate process without the variable set, so no job traffic is ever dumped.
- **No secrets land in the log.** .NET redacts the auth header (`Authorization: RemoteAuth ***`) and never dumps request/response bodies — verified against a
  mock: the registration token appears zero times. The cost is a few KB of extra headers in `_diag` (~24 KB total for a config run).
- **It is emitted on failed registrations too** — a 403 from an exhausted budget is exactly when the number matters most.
- **Fleet-scoped, not per-runner.** The value describes the shared PAT/App budget, so there is deliberately no `runner` label; `labels`
  (from `RUNNER_LABELS`/`LABELS`) separates distinct runner pools.
- **It's a snapshot, not a poll** — the reading is from whichever runner registered most recently, so read it as "this much was left as of the last
  registration". With metrics disabled the wrapper is a plain `exec` of the real script and none of this happens.
- **Long-lived runners only:** if the runner auto-updates itself in place (not the case for ephemeral containers, which are recreated from the image)
  it restores its own `config.sh` and the metric silently stops. Registration is unaffected.

### Deploying the collector

Example artifacts live in [`metrics/`](metrics/): a
[`statsd_mapping.yml`](metrics/statsd_mapping.yml) (per-metric TTLs + duration histogram buckets) and a [
`docker-compose.example.yml`](metrics/docker-compose.example.yml)
running a single `statsd_exporter` + Prometheus. For a quick local look:

```bash
docker compose -f metrics/docker-compose.example.yml up
```

In production, front the exporter with a stable address (private DNS or an internal NLB), open its **UDP/9125** to the runner instances' security group, and set
the gauge TTL in `statsd_mapping.yml` to a bit above your longest job. Cross-host UDP can drop under load, but that's harmless here — the heartbeat re-sends
every interval, so a lost packet self-corrects on the next tick.

> **Known limitation:** the job-completed hook doesn't receive a documented
> job-conclusion variable, so job counters carry no success/failure label yet.

### Troubleshooting metrics

If Prometheus shows no data, work the pipeline **runner → statsd_exporter → Prometheus** from the middle out.

**Is anything reaching the exporter?** Its own metrics tell you — a non-zero
`statsd_exporter_udp_packets_total` means datagrams are arriving:

```bash
curl -s <exporter>:9102/metrics | grep -E 'udp_packets_total|github_runner'
```

**Is the runner even trying to send?** Run it with `-e RUNNER_METRICS_DEBUG=1`. Each hook then logs the resolved config and every emit; a `SEND FAILED` line
means the target host couldn't be resolved/opened (wrong address, or the runner can't reach it):

```bash
docker logs <runner> | grep runner-metrics
docker exec <runner> cat /tmp/runner-metrics.log
```

**Inspect a live runner** without rebuilding:

```bash
docker exec <runner> env | grep RUNNER_METRICS                       # env reached the container?
docker exec <runner> cat /tmp/runner-metrics.state                   # idle / busy as expected?
docker exec <runner> bash -c 'echo -n test:1\|c > /dev/udp/<host>/<port> && echo OK || echo FAIL'  # can it reach the target?
```

**Docker Desktop (macOS/Windows) note:** published **UDP** ports are unreliable there, so a host `-p 9125:9125/udp` may silently drop packets. For local
testing, attach the runner to the exporter's compose network and address it by service name
(`--network <project>_default -e RUNNER_METRICS_STATSD_ADDR=statsd-exporter:9125`)
instead of `host.docker.internal`. Linux hosts don't have this limitation.

## Build

```bash
docker build -t hardened-runner:noble .

# Docker-in-docker (adds dockerd + containerd.io + runc — see "Docker-in-Docker" above)
docker build --build-arg INSTALL_DOCKER_DAEMON=true -t hardened-runner:noble-dind .

# podman/buildah/skopeo (Ubuntu-universe stale-Go binaries)
docker build --build-arg INSTALL_CONTAINER_TOOLS=true -t hardened-runner:noble-containers .
```

Build args: `GH_RUNNER_VERSION`, `GIT_LFS_VERSION`, `HELM_VERSION`,
`KUBECTL_MINOR_VERSION`, `NODE_MAJOR`, `INSTALL_DOCKER_DAEMON` (default `false`),
`INSTALL_CONTAINER_TOOLS` (default `false`), `INSTALL_POWERSHELL` (default
`true`), `RUNNER_UID`/`RUNNER_GID`/`DOCKER_GID`.

## CVEs left unfixed

The CI gate (`.github/workflows/build.yml`) fails on any fixable Critical, so the eliminated cluster cannot silently reappear. The following are accepted
residuals — those with a fix but no remediation path are ignored in
[`.grype.yaml`](.grype.yaml), re-audited on every version bump:

| CVE(s)                                                                                                                         | Component                                                                         | Why                                                                                                                                                                                                                                                                                                                                                                                                                       |
|--------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `CVE-2026-6100` (Critical), `CVE-2026-3298`, `CVE-2026-4786` (High)                                                            | python `3.14.5` bundled in **aws-cli v2**                                         | grype reports no fixed version — no patched python ships upstream yet. aws-cli v2 always bundles its own interpreter.                                                                                                                                                                                                                                                                                                     |
| `GO-2026-5026` (Critical, `x/net/idna`)                                                                                        | `golang.org/x/net` `v0.49.0` in **kubectl**                                       | Fixed in `x/net` `v0.55.0`, but no kubernetes release ships the bump yet (even `v1.36.2` pins `v0.49.0`), and building kubectl from source with a forced bump is impractical. Ignored in [`.grype.yaml`](.grype.yaml); clears when k8s bumps `x/net`.                                                                                                                                                                     |
| `GHSA-23hp-3jrh-7fpw` / `CVE-2026-59873` (Critical, node-tar Gzip Bomb DoS)                                                    | `tar` bundled in npm (system + actions-runner node20/node24 externals)            | Fixed in `tar@7.5.19`, but DoS-only (disk exhaustion) and only triggerable via an already-malicious npm dependency — accepted risk for a trusted-user-only fleet, not patched. node20's bundled npm 10.8.2 has no in-range fix available anyway (`tar ^6.2.1`, no patched 6.x release exists). Ignored in [`.grype.yaml`](.grype.yaml).                                                                                   |
| `GO-2026-4337`, `CVE-2025-68121`, `CVE-2026-27143` (Critical, stdlib)                                                          | Go stdlib embedded in `crane` (`v0.22.0`, released 2026-08-25)                    | `install_crane()` always fetches upstream's `releases/latest`; no `go-containerregistry` release yet embeds a patched Go. Same cluster the `gitlfs` stage rebuilds git-lfs from source to dodge — crane ships a prebuilt binary instead, so that option isn't available. Ignored in [`.grype.yaml`](.grype.yaml), scoped to the crane binary's path; clears once upstream cuts a release built with a fixed Go toolchain. |
| `tar`, `minimatch`, `glob`, `undici`, `cross-spawn` (npm, High)                                                                | bundled in `/actions-runner/externals/node*`                                      | Pinned by the `actions/runner` tarball (already on the latest, `2.335.1`). Clear when upstream refreshes its bundled deps.                                                                                                                                                                                                                                                                                                |
| `docker` / `containerd` vendored modules (High)                                                                                | inside `docker-ce-cli` / buildx / compose                                         | Module-level findings in the CLI we keep; clear on the next Docker package bump (`apt upgrade`).                                                                                                                                                                                                                                                                                                                          |
| `GO-2026-5942` (`x/net`), `GO-2026-6179`/`GO-2026-6180` (`x/mod`), `GHSA-hrxh-6v49-42gf` (grpc) — all High, all fixed upstream | `dockerd`, `containerd`, `ctr`, `containerd-shim-runc-v2`, `docker-proxy`, `runc` | Only present when `INSTALL_DOCKER_DAEMON=true` (see [Docker-in-Docker](#docker-in-docker)). Confirmed via a local `grype` scan of the `-dind` variant to add **zero** new fixable Criticals over the default image — these High findings are the residual. Clear on the next `apt upgrade` that picks up a `docker-ce`/`containerd.io` build against fixed deps.                                                          |
| `CVE-2024-52308` (High)                                                                                                        | `gh`                                                                              | Upstream `wont-fix`.                                                                                                                                                                                                                                                                                                                                                                                                      |
| podman/buildah/skopeo Go-stdlib CVEs                                                                                           | container tooling                                                                 | Only when `INSTALL_CONTAINER_TOOLS=true`; inherited from Ubuntu universe. Default builds don't ship these.                                                                                                                                                                                                                                                                                                                |

## License

GPL-3.0, inherited from the upstream project. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE) for attribution of the reused runtime scripts.
