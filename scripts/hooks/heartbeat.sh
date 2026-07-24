#!/usr/bin/env bash
# shellcheck shell=bash
#
# Background liveness loop, launched by runner-run.sh. Re-emits this runner's
# status gauge every RUNNER_METRICS_HEARTBEAT_INTERVAL seconds so that:
#   * an idle runner waiting for work is observable (the job hooks only fire at
#     job boundaries), and
#   * statsd_exporter's TTL keeps the series alive while the runner lives and
#     expires it shortly after the runner dies — self-healing for a container
#     killed mid-job.
#
# It exits when its process tree is torn down (container stop). Best effort;
# never fails.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${DIR}/lib.sh" 2>/dev/null || exit 0

metrics_enabled || exit 0

metrics_log_banner heartbeat

# Seed idle if the wrapper hasn't already written a state file.
[[ -r "${METRICS_STATE_FILE}" ]] || metrics_write_state idle ""

while true; do
  metrics_emit_status
  sleep "${METRICS_HEARTBEAT_INTERVAL}" 2>/dev/null || sleep 15
done
