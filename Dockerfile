# syntax=docker/dockerfile:1
#
# Hardened, drop-in replacement for myoung34/github-runner:<ver>-ubuntu-noble.
# Same entrypoint/env-var contract; the difference is in what gets shipped and
# patched. See README for the grype-verified CVE rationale behind each decision.
#
# ---------------------------------------------------------------------------
# git-lfs builder. The upstream git-lfs RELEASE binary is built against a Go
# (go1.25.3) that still carries the newest 2026 stdlib CVEs (CVE-2025-68121,
# CVE-2026-27143, GO-2026-4337) — fixes exist in Go but no rebuilt git-lfs
# release ships them yet. So we compile git-lfs ourselves with a current Go.
# Runs native on the build host and cross-compiles to the target arch (pure
# Go, CGO off) — no QEMU.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1 AS gitlfs
ARG GIT_LFS_VERSION="3.7.1"
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0
RUN GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
      go install "github.com/git-lfs/git-lfs/v3@v${GIT_LFS_VERSION}" \
  && mkdir -p /out \
  && cp "$(find /go/bin -name git-lfs -type f | head -1)" /out/git-lfs

# ---------------------------------------------------------------------------
FROM ubuntu:noble

LABEL org.opencontainers.image.title="hardened-github-runner" \
      org.opencontainers.image.description="Self-hosted GitHub Actions runner (drop-in for myoung34/github-runner) with the vulnerability cluster removed" \
      org.opencontainers.image.source="https://github.com/lorenzoscebba/docker-github-runners" \
      org.opencontainers.image.licenses="GPL-3.0"

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runner version and identity. Bumping GH_RUNNER_VERSION also refreshes the
# npm deps bundled under /actions-runner/externals (fix #4).
ARG GH_RUNNER_VERSION="2.335.1"
ARG TARGETPLATFORM

# Build knobs (CVE-driven defaults — see install-tools.sh and README).
#   INSTALL_DOCKER_DAEMON: adds dockerd + containerd.io for docker-in-docker.
#     OFF by default — containerd embeds the grpc CVE and host-socket runners
#     don't need it.
#   INSTALL_CONTAINER_TOOLS: podman/buildah/skopeo/CNI (stale-Go). OFF.
# git-lfs is always included, compiled from source in the `gitlfs` stage above.
ARG INSTALL_DOCKER_DAEMON="false"
ARG INSTALL_CONTAINER_TOOLS="false"
ARG INSTALL_POWERSHELL="true"
ARG KUBECTL_MINOR_VERSION="1.35"

ARG RUNNER_UID="1001"
ARG RUNNER_GID="121"
ARG DOCKER_GID="500"

# ---------------------------------------------------------------------------
# 1. Patch the OS-package CVE tail (apt upgrade) and 2. strip snapd.
#    Essentials + apt-sourced tools installed here; everything cleaned at the
#    end of the file so no apt lists are baked into the image (fix #5).
# ---------------------------------------------------------------------------
RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
  && apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
       apt-transport-https \
       bc \
       build-essential \
       ca-certificates \
       curl \
       default-jdk \
       dirmngr \
       dumb-init \
       gettext \
       gnupg \
       gpg-agent \
       inetutils-ping \
       jq \
       libc-bin \
       libcurl4-openssl-dev \
       libpq-dev \
       libyaml-dev \
       locales \
       lsb-release \
       nodejs \
       npm \
       openssh-client \
       pkg-config \
       python3 \
       python3-pip \
       python3-setuptools \
       python3-venv \
       rsync \
       sudo \
       tar \
       unzip \
       util-linux \
       wget \
       zip \
       zlib1g-dev \
       zstd \
       libgtk-3-0t64 \
       libgbm-dev \
       libnotify-dev \
       libnss3 \
       libxss1 \
       libasound2t64 \
       libxtst6 \
       xauth \
       xvfb \
       chromium \
  && locale-gen \
  && ( apt-get purge -y --auto-remove snapd 2>/dev/null || true ) \
  && rm -rf /var/lib/snapd /snap \
  && printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf

# Replace gosu (stale-Go binary, dominant CVE source) with a setpriv shim that
# preserves its "switch user + init groups + exec" behaviour. The apt gosu is
# intentionally never installed; this shim takes its canonical path so
# entrypoint.sh (`/usr/sbin/gosu runner ...`) works unchanged.
COPY --chmod=0755 scripts/gosu /usr/sbin/gosu
RUN apt-get purge -y gosu 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Toolchain: Docker CLI + buildx + compose, git, gh, yq, aws, powershell.
#    Docker daemon / container tooling / git-lfs gated — see install-tools.sh.
# ---------------------------------------------------------------------------
COPY scripts/install-tools.sh /tmp/install-tools.sh
RUN INSTALL_DOCKER_DAEMON="${INSTALL_DOCKER_DAEMON}" \
    INSTALL_CONTAINER_TOOLS="${INSTALL_CONTAINER_TOOLS}" \
    INSTALL_POWERSHELL="${INSTALL_POWERSHELL}" \
    KUBECTL_MINOR_VERSION="${KUBECTL_MINOR_VERSION}" \
    /tmp/install-tools.sh \
  && rm -f /tmp/install-tools.sh

# git-lfs compiled with a current Go (see the `gitlfs` stage). Configure the
# system-wide smudge/clean filters so `git clone` of LFS repos works.
COPY --from=gitlfs /out/git-lfs /usr/local/bin/git-lfs
RUN git-lfs install --system --skip-repo

# ---------------------------------------------------------------------------
# 4. Users and sudoers
# ---------------------------------------------------------------------------
RUN sed -e 's/Defaults.*env_reset/Defaults env_keep = "HTTP_PROXY HTTPS_PROXY NO_PROXY FTP_PROXY http_proxy https_proxy no_proxy ftp_proxy"/' -i /etc/sudoers \
  && echo '%sudo ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers \
  && ( groupadd -g "${DOCKER_GID}" docker 2>/dev/null || groupmod -g "${DOCKER_GID}" docker ) \
  && ( groupadd -g "${RUNNER_GID}" runner || groupadd runner ) \
  && ( userdel -r ubuntu 2>/dev/null || true ) \
  && useradd -mr -d /home/runner -u "${RUNNER_UID}" -g runner runner \
  && usermod -aG sudo runner \
  && usermod -aG docker runner

# ---------------------------------------------------------------------------
# 5. GitHub Actions runner
# ---------------------------------------------------------------------------
WORKDIR /actions-runner
COPY scripts/install_actions.sh /actions-runner/install_actions.sh
RUN mkdir -p /opt/hostedtoolcache \
  && chmod +x /actions-runner/install_actions.sh \
  && /actions-runner/install_actions.sh "${GH_RUNNER_VERSION}" "${TARGETPLATFORM}" \
  && rm /actions-runner/install_actions.sh \
  && chown -R runner /_work /actions-runner /opt/hostedtoolcache

# ---------------------------------------------------------------------------
# Runtime scripts + final cache cleanup (fix #5)
# ---------------------------------------------------------------------------
COPY scripts/token.sh scripts/entrypoint.sh scripts/app_token.sh /
RUN chmod +x /token.sh /entrypoint.sh /app_token.sh \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENTRYPOINT ["/entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
