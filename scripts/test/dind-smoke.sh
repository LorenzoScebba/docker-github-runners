#!/usr/bin/env bash
# shellcheck shell=bash
#
# Tests scripts/hooks/docker-ready.sh's own behavior specifically: readiness
# wait, fail-open timeout, passthrough, and the shutdown watcher. This does
# NOT re-test "does dockerd start and run a nested container at all" —
# e2e.yaml's dind leg already covers that (and more thoroughly, with real
# tool-availability checks) by booting the actual image. Run this from
# there rather than duplicating the boot/run checks here.
#
# What this does NOT cover: a real GitHub Actions job running through an
# actual runner registration — that needs live org/repo credentials that
# neither this script nor CI has. See TODO.md.
#
# Usage: scripts/test/dind-smoke.sh [image]
#   image defaults to $DIND_IMAGE or hardened-runner:noble-dind

set -euo pipefail

IMAGE="${1:-${DIND_IMAGE:-hardened-runner:noble-dind}}"
FAILED=0

_check() {
  local desc="$1"
  echo
  echo "=== ${desc} ==="
}

_pass() { echo "PASS: $1"; }
_fail() { echo "FAIL: $1" >&2; FAILED=1; }

_check "docker-ready.sh waits for readiness before handing off"
OUT="$(docker run --rm --privileged --tmpfs /var/lib/docker --entrypoint bash "${IMAGE}" -c '
  set -e
  export START_DOCKER_SERVICE=true DOCKER_READY_TIMEOUT=20
  /actions-runner/hooks/docker-ready.sh bash -c "echo HANDED-OFF" &
  WRAPPER_PID=$!
  sleep 3
  service docker start >/dev/null
  wait "${WRAPPER_PID}"
' 2>&1)" || true
if echo "${OUT}" | grep -q "dockerd accepted connections" && echo "${OUT}" | grep -q "HANDED-OFF"; then
  _pass "docker-ready.sh waited for dockerd, then handed off"
else
  _fail "docker-ready.sh readiness wait (output: ${OUT})"
fi

_check "docker-ready.sh fails open (still hands off) if dockerd never starts"
OUT="$(docker run --rm --entrypoint bash "${IMAGE}" -c '
  export START_DOCKER_SERVICE=true DOCKER_READY_TIMEOUT=3
  /actions-runner/hooks/docker-ready.sh bash -c "echo HANDED-OFF-ANYWAY"
' 2>&1)" || true
if echo "${OUT}" | grep -q "not ready after" && echo "${OUT}" | grep -q "HANDED-OFF-ANYWAY"; then
  _pass "docker-ready.sh fails open on timeout"
else
  _fail "docker-ready.sh timeout handling (output: ${OUT})"
fi

_check "docker-ready.sh is a zero-overhead passthrough when START_DOCKER_SERVICE is unset"
OUT="$(docker run --rm --entrypoint bash "${IMAGE}" -c '
  /actions-runner/hooks/docker-ready.sh echo PASSTHROUGH-OK
' 2>&1)" || true
if [[ "${OUT}" == "PASSTHROUGH-OK" ]]; then
  _pass "docker-ready.sh passthrough"
else
  _fail "docker-ready.sh passthrough (output: ${OUT})"
fi

_check "docker-ready.sh stops dockerd on shutdown"
# No `set -e` here: `service docker status` exits non-zero once stopped —
# that is the expected, successful outcome we are checking for, not a
# script error.
OUT="$(docker run --rm --privileged --tmpfs /var/lib/docker --entrypoint bash "${IMAGE}" -c '
  export START_DOCKER_SERVICE=true DOCKER_READY_TIMEOUT=20
  service docker start >/dev/null
  /actions-runner/hooks/docker-ready.sh bash -c "echo done"
  # The watcher polls every 2s; give it a generous margin past that before
  # concluding it never stopped the daemon.
  sleep 6
  service docker status
' 2>&1)" || true
if echo "${OUT}" | grep -qi "not running"; then
  _pass "docker-ready.sh stopped dockerd after the CMD exited"
else
  _fail "docker-ready.sh shutdown watcher (output: ${OUT})"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
  echo "All DinD smoke checks passed for ${IMAGE}"
  exit 0
else
  echo "One or more DinD smoke checks FAILED for ${IMAGE}" >&2
  exit 1
fi
