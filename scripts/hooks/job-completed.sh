#!/usr/bin/env bash
# shellcheck shell=bash
#
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED — invoked by the runner after all of a job's
# steps have run, whether they succeeded or failed. It is NOT guaranteed to run
# if the container is killed first (autoscale down / SIGKILL) — that case is
# handled by the statsd_exporter TTL expiring this runner's series. Best effort;
# always exit 0.
#
# Note: the completion hook does not receive a documented job-conclusion
# variable, so no success/failure label is emitted here (tracked as a follow-up).

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${DIR}/lib.sh" 2>/dev/null || exit 0

metrics_log_banner job-completed

if metrics_enabled; then
  tags="$(metrics_context_busy_tags)"
  # Back to idle. Keep this job's tags in the state file so the heartbeat keeps
  # refreshing the busy series to 0 (self-corrects a dropped transition packet);
  # the series then TTL-expires. For an ephemeral runner the container exits
  # right after this, so the whole series set expires shortly.
  metrics_write_state idle "${tags}"
  metrics_emit_status
  # Counter/timer derive their own labels from the job context; don't pass tags.
  metrics_emit_counter jobs_completed_total

  # Job duration (emit milliseconds; statsd_exporter converts ms -> seconds).
  if [[ -r "${METRICS_JOBSTART_FILE}" ]]; then
    start="$(cat "${METRICS_JOBSTART_FILE}" 2>/dev/null || true)"
    if [[ "${start}" =~ ^[0-9]+$ ]]; then
      now="$(date +%s)"
      metrics_emit_timer job_duration_seconds "$(( (now - start) * 1000 ))"
    fi
    rm -f "${METRICS_JOBSTART_FILE}" 2>/dev/null || true
  fi
fi

exit 0
