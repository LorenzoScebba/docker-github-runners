#!/usr/bin/env bash
# shellcheck shell=bash
#
# CMD wrapper for docker-in-docker deployments (image built with
# INSTALL_DOCKER_DAEMON=true). Chained ahead of runner-run.sh in the
# Dockerfile CMD so it runs before the runner ever picks up a job.
#
# entrypoint.sh already starts the daemon itself when START_DOCKER_SERVICE=
# true (its "Start docker service" block runs `service docker start`) — but
# that call returns as soon as the init script forks the daemon, not once
# dockerd is actually accepting connections. On a cold `/var/lib/docker`
# (graph-driver init, especially overlay2) that gap is real, and a job's
# first `docker` step can race it. entrypoint.sh is copied verbatim from
# upstream and must not be patched (see CLAUDE.md), so this wrapper closes
# the gap from the outside instead — wait for readiness, then hand off.
#
# It also stops the daemon on container shutdown: `service docker start`
# detaches dockerd from the process it was forked from, so nothing else in
# the container's init tree would otherwise flush it cleanly on `docker stop`.
#
# Transparent (a plain exec of "$@") unless START_DOCKER_SERVICE=true, so
# non-DinD deployments (the documented host-socket-mount pattern) are
# byte-for-byte unaffected.

set -uo pipefail

_START_DOCKER_SERVICE="${START_DOCKER_SERVICE:-false}"

if [[ "${_START_DOCKER_SERVICE}" != "true" ]]; then
  exec "$@"
fi

_TIMEOUT="${DOCKER_READY_TIMEOUT:-30}"
_WAITED=0

echo "docker-ready: waiting up to ${_TIMEOUT}s for dockerd to accept connections"
while ! docker info >/dev/null 2>&1; do
  if [[ ${_WAITED} -ge ${_TIMEOUT} ]]; then
    echo "docker-ready: dockerd not ready after ${_TIMEOUT}s — continuing anyway (steps that need docker may fail)" >&2
    break
  fi
  sleep 1
  _WAITED=$((_WAITED + 1))
done
[[ ${_WAITED} -lt ${_TIMEOUT} ]] && echo "docker-ready: dockerd accepted connections after ${_WAITED}s"

# Best-effort clean shutdown once the real CMD exits. Forked before the exec
# below, same trick as runner-run.sh's metrics watcher: exec replaces THIS
# process's image, not the already-forked background one, so the watcher
# survives into whatever "$@" execs into (it tracks the PID, which exec never
# changes). Signals are ignored in the watcher itself so a TERM/INT sent to
# the whole container doesn't kill it before it can react to the PID exiting.
_WATCH_PID="$$"
(
  trap '' TERM INT QUIT
  while kill -0 "${_WATCH_PID}" 2>/dev/null; do
    sleep 2
  done
  echo "docker-ready: main process exited — stopping dockerd" >&2
  service docker stop >/dev/null 2>&1 || true
) >/dev/null 2>&1 &
disown 2>/dev/null || true

exec "$@"
