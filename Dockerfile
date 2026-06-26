# syntax=docker/dockerfile:1
#
# Hardened, drop-in replacement for myoung34/github-runner:<ver>-ubuntu-noble.
# Same entrypoint/env-var contract; the difference is in what gets shipped and
# patched. See README "Security" for the CVE rationale behind each decision.
#
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

# Build knobs. Container tooling is OFF by default — see install-tools.sh.
ARG INSTALL_CONTAINER_TOOLS="false"
ARG INSTALL_POWERSHELL="true"

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
       build-essential \
       ca-certificates \
       curl \
       dirmngr \
       dumb-init \
       gettext \
       gnupg \
       gosu \
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
       wget \
       zip \
       zlib1g-dev \
       zstd \
  && locale-gen \
  && ( apt-get purge -y --auto-remove snapd 2>/dev/null || true ) \
  && rm -rf /var/lib/snapd /snap

# ---------------------------------------------------------------------------
# 3. Toolchain: Docker CE (current upstream Go), git, gh, yq, aws, powershell.
#    Container tooling (podman/buildah/skopeo/CNI) only when explicitly opted in.
# ---------------------------------------------------------------------------
COPY scripts/install-tools.sh /tmp/install-tools.sh
RUN INSTALL_CONTAINER_TOOLS="${INSTALL_CONTAINER_TOOLS}" \
    INSTALL_POWERSHELL="${INSTALL_POWERSHELL}" \
    /tmp/install-tools.sh \
  && rm -f /tmp/install-tools.sh

# ---------------------------------------------------------------------------
# 4. Users and sudoers
# ---------------------------------------------------------------------------
RUN sed -e 's/Defaults.*env_reset/Defaults env_keep = "HTTP_PROXY HTTPS_PROXY NO_PROXY FTP_PROXY http_proxy https_proxy no_proxy ftp_proxy"/' -i /etc/sudoers \
  && echo '%sudo ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers \
  && ( groupadd -g "${DOCKER_GID}" docker || groupadd docker ) \
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
