#!/usr/bin/env bash
# Download and unpack the GitHub Actions runner release, then install its
# OS-level dependencies. Verifies the published SHA-256 when available.
set -euo pipefail

GH_RUNNER_VERSION="${1:?usage: install_actions.sh <version> <targetplatform>}"
TARGETPLATFORM="${2:-linux/amd64}"

TARGET_ARCH="x64"
if [[ "${TARGETPLATFORM}" == "linux/arm64" ]]; then
  TARGET_ARCH="arm64"
fi

TARBALL="actions-runner-linux-${TARGET_ARCH}-${GH_RUNNER_VERSION}.tar.gz"
BASE_URL="https://github.com/actions/runner/releases/download/v${GH_RUNNER_VERSION}"

curl -fsSL "${BASE_URL}/${TARBALL}" -o actions.tar.gz

# Verify against the checksum GitHub publishes in the release notes. Fall back
# gracefully if the format ever changes rather than failing the whole build.
EXPECTED_SHA="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/actions/runner/releases/tags/v${GH_RUNNER_VERSION}" \
  | jq -r --arg t "${TARBALL}" '.body | capture("(?<sha>[0-9a-f]{64})  " + $t) | .sha' 2>/dev/null || true)"

if [[ -n "${EXPECTED_SHA}" && "${EXPECTED_SHA}" != "null" ]]; then
  echo "${EXPECTED_SHA}  actions.tar.gz" | sha256sum -c -
else
  echo "WARNING: could not resolve published checksum for ${TARBALL}; skipping verification" >&2
fi

tar -zxf actions.tar.gz
rm -f actions.tar.gz
./bin/installdependencies.sh
mkdir -p /_work
