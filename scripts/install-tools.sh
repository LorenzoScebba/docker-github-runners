#!/usr/bin/env bash
#
# Install the runner toolchain on top of an upgraded Ubuntu base.
#
# Security posture (see README "Security" section). Every CVE decision below is
# backed by grype attribution of the actual binaries, not assumptions:
#   * The caller is expected to have already run `apt-get upgrade -y` so the
#     OS-package CVE tail is closed.
#   * Docker CLI + buildx + compose are installed by default. The Docker DAEMON
#     and containerd.io are NOT, unless INSTALL_DOCKER_DAEMON=true: containerd's
#     binaries (containerd/ctr/shim) embed grpc v1.78.0 (GHSA-p77j-4mvh-x3m3).
#     Runners that mount the host /var/run/docker.sock only need the CLI.
#   * podman / buildah / skopeo / CNI plugins only when INSTALL_CONTAINER_TOOLS
#     =true (stale-Go Ubuntu-universe binaries).
#   * git-lfs is NOT installed here — it is compiled from source with a current
#     Go in the Dockerfile's `gitlfs` stage (the upstream release binary carries
#     stale-Go stdlib CVEs).
#   * helm is pulled from the official get.helm.sh release, NOT the buildkite apt
#     repo: that repo lags and ships a helm built against the vulnerable
#     x/net/x/crypto (the 2026 GO-2026-5005..5026 critical batch).
#   * Node.js + npm come from NodeSource, NOT Ubuntu apt: the apt npm drags in a
#     stale Debian node-* tree (handlebars 4.7.7 / node-babel7 7.20.x — both
#     critical). NodeSource's npm is self-contained and avoids it.
#   * snapd is purged; gosu is replaced by a setpriv shim (both stale Go) — see
#     the Dockerfile.
#
set -euo pipefail

INSTALL_CONTAINER_TOOLS="${INSTALL_CONTAINER_TOOLS:-false}"
INSTALL_DOCKER_DAEMON="${INSTALL_DOCKER_DAEMON:-false}"
INSTALL_POWERSHELL="${INSTALL_POWERSHELL:-true}"
KUBECTL_MINOR_VERSION="${KUBECTL_MINOR_VERSION:-1.35}"
HELM_VERSION="${HELM_VERSION:-3.21.2}"
NODE_MAJOR="${NODE_MAJOR:-24}"

DPKG_ARCH="$(dpkg --print-architecture)"

# ---------------------------------------------------------------------------
# APT repositories (Docker, git-core PPA) with keyrings
# ---------------------------------------------------------------------------
configure_sources() {
  # shellcheck source=/dev/null
  source /etc/os-release

  mkdir -p /etc/apt/keyrings

  # git-core PPA for an up-to-date git
  gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys A1715D88E1DF1F24
  gpg --export A1715D88E1DF1F24 | gpg --dearmor -o /usr/share/keyrings/git-core.gpg
  echo "deb [signed-by=/usr/share/keyrings/git-core.gpg] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu ${VERSION_CODENAME} main" \
    > /etc/apt/sources.list.d/git-core.list

  # Docker CE official repo
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${DPKG_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  # Kubernetes repo (kubectl)
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MINOR_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MINOR_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  # NodeSource (current Node.js + self-contained npm). Ubuntu's apt npm pulls in
  # a stale Debian node-* tooling tree — handlebars 4.7.7 (CVE-2026-33937) and
  # node-babel7 7.20.x (CVE-2023-45133), both critical. NodeSource avoids it.
  # (helm is NOT installed from apt — see install_helm; the buildkite repo lags.)
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list

  apt-get update
}

install_docker() {
  # CLI + buildx + compose are clean Go (no flagged stdlib/grpc) and are all a
  # host-socket runner needs.
  apt-get install -y --no-install-recommends \
    docker-ce-cli docker-buildx-plugin docker-compose-plugin

  # The daemon + containerd.io carry the grpc CVE; only add them for dind.
  if [[ "${INSTALL_DOCKER_DAEMON}" == "true" ]]; then
    echo "INSTALL_DOCKER_DAEMON=true -> adding dockerd + containerd.io (containerd embeds grpc; see README)"
    apt-get install -y --no-install-recommends docker-ce containerd.io
    # Avoid the hard ulimit bump that fails inside unprivileged containers.
    [[ -f /etc/init.d/docker ]] && sed -i 's/ulimit -Hn/# ulimit -Hn/g' /etc/init.d/docker
  fi

  # Provide the classic `docker-compose` shim expected by some workflows.
  printf '#!/bin/sh\ndocker compose --compatibility "$@"\n' > /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
}

install_git() {
  # git-lfs is built from source in the Dockerfile's `gitlfs` stage.
  apt-get install -y --no-install-recommends git
}

install_github_cli() {
  local ver url
  ver="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
  url="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/cli/cli/releases/latest \
    | jq -r --arg n "gh_${ver}_linux_${DPKG_ARCH}.deb" '.assets[] | select(.name == $n) | .browser_download_url')"
  curl -fsSL "${url}" -o /tmp/ghcli.deb
  apt-get install -y /tmp/ghcli.deb
  rm -f /tmp/ghcli.deb
}

install_yq() {
  local url
  url="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/mikefarah/yq/releases/latest \
    | jq -r --arg n "yq_linux_${DPKG_ARCH}.tar.gz" '.assets[] | select(.name == $n) | .browser_download_url')"
  curl -fsSL "${url}" -o /tmp/yq.tar.gz
  tar -xzf /tmp/yq.tar.gz -C /tmp
  mv "/tmp/yq_linux_${DPKG_ARCH}" /usr/local/bin/yq
  rm -f /tmp/yq.tar.gz
}

install_aws_cli() {
  local arch="x86_64"
  [[ "${DPKG_ARCH}" == "arm64" ]] && arch="aarch64"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
}

install_powershell() {
  local ver url tgt="${DPKG_ARCH/amd64/x64}"
  ver="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/PowerShell/PowerShell/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
  url="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
    | jq -r --arg n "powershell-${ver}-linux-${tgt}.tar.gz" '.assets[] | select(.name == $n) | .browser_download_url')"
  curl -fsSL "${url}" -o /tmp/powershell.tar.gz
  mkdir -p /opt/powershell
  tar zxf /tmp/powershell.tar.gz -C /opt/powershell
  chmod +x /opt/powershell/pwsh
  ln -sf /opt/powershell/pwsh /usr/bin/pwsh
  rm -f /tmp/powershell.tar.gz
}

install_kubectl() {
  apt-get install -y --no-install-recommends kubectl
}

install_helm() {
  # Official release binary. The buildkite apt repo lags and ships a helm built
  # against the vulnerable x/net/x/crypto; helm v3.21.2 is the first 3.x release
  # whose go.mod pins the fixed x/net v0.55.0 / x/crypto v0.53.0.
  local url="https://get.helm.sh/helm-v${HELM_VERSION}-linux-${DPKG_ARCH}.tar.gz"
  curl -fsSL "${url}" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mv "/tmp/linux-${DPKG_ARCH}/helm" /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz "/tmp/linux-${DPKG_ARCH}"
}

install_node() {
  # From the NodeSource repo configured in configure_sources (bundles npm).
  apt-get install -y --no-install-recommends nodejs
}

install_yarn() {
  npm install -g yarn
}

# OPT-IN ONLY: the Ubuntu-universe container stack. These carry the stale-Go
# CVE cluster the upstream image is flagged for. Documented in README.
install_container_tools() {
  echo "INSTALL_CONTAINER_TOOLS=true -> installing podman/buildah/skopeo (carries known Go-stdlib CVEs)"
  apt-get install -y --no-install-recommends podman buildah skopeo
}

# ---------------------------------------------------------------------------
main() {
  configure_sources
  install_docker
  install_git
  install_github_cli
  install_yq
  install_aws_cli
  install_kubectl
  install_helm
  install_node
  install_yarn
  [[ "${INSTALL_POWERSHELL}" == "true" ]] && install_powershell
  [[ "${INSTALL_CONTAINER_TOOLS}" == "true" ]] && install_container_tools

  # Repo lists are removed by the Dockerfile after this script, alongside the
  # final cache cleanup.
  rm -f /etc/apt/sources.list.d/git-core.list \
        /etc/apt/sources.list.d/kubernetes.list \
        /etc/apt/sources.list.d/nodesource.list
}

main "$@"
