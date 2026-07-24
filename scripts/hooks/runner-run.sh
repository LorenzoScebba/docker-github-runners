#!/usr/bin/env bash
# shellcheck shell=bash
#
# Container CMD wrapper. It is set as the image CMD in place of invoking
# Runner.Listener directly, so that idle runners can be observed: the job hooks
# only fire at job boundaries, but a runner spends its pre-job life idle and we
# want that reported.
#
# When runner metrics are DISABLED (RUNNER_METRICS_STATSD_ADDR unset) this is a
# transparent passthrough — it just execs the original command, so the image
# behaves byte-for-byte like upstream.
#
# When ENABLED it seeds idle state, launches the background heartbeat, then
# execs the original command. `exec` replaces this process with Runner.Listener
# so the entrypoint's signal handling, deregistration trap and cwd are all
# unchanged. The heartbeat is detached and survives the exec, dying only when
# the container is torn down.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${DIR}/lib.sh" 2>/dev/null || exec "$@"

metrics_log_banner wrapper

if metrics_enabled; then
  metrics_write_state idle ""
  metrics_emit_status
  if _metrics_debug; then
    # Let the heartbeat's debug output flow to the container's logs.
    "${DIR}/heartbeat.sh" &
  else
    nohup "${DIR}/heartbeat.sh" >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true

  # `exec` below replaces this process with Runner.Listener but keeps the same
  # PID, so a sibling watcher forked now can poll for that PID's death and
  # fire one last "offline" status the moment it happens — covering a
  # graceful stop with no job in flight, which no job hook ever sees. Ignore
  # the stop signal in the watcher itself so it outlives the signal long
  # enough to notice the exit; a SIGKILL of the whole container still takes
  # the watcher out too, and that case still relies on the status gauge's TTL.
  WATCH_PID="$$"
  (
    trap '' TERM INT QUIT
    while kill -0 "${WATCH_PID}" 2>/dev/null; do
      sleep 2
    done
    metrics_emit_offline
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

exec "$@"
