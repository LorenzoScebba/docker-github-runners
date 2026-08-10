#!/usr/bin/env bash
# shellcheck shell=bash
#
# ACTIONS_RUNNER_HOOK_JOB_STARTED — invoked by the runner right before a job's
# steps run. It is SYNCHRONOUS (blocks the job while running) and its exit code
# is load-bearing: a non-zero exit makes the runner mark the job failed and
# refuse to run it. So this must be fast and MUST always exit 0.
#
# All work is a local state-file write plus fire-and-forget UDP; the actual
# gauge liveness is driven by heartbeat.sh.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${DIR}/lib.sh" 2>/dev/null || exit 0

metrics_log_banner job-started

if metrics_enabled; then
  tags="$(metrics_context_busy_tags)"
  # Flip state -> busy so the heartbeat reports this runner as busy with the
  # workflow/job labels.
  metrics_write_state busy "${tags}"
  # Stamp the start time for the completion-hook duration calculation.
  date +%s > "${METRICS_JOBSTART_FILE}" 2>/dev/null || true
  # Immediate emit (don't wait up to a heartbeat interval for the transition).
  metrics_emit_status
  # The counter derives its own labels from the job context; don't pass tags.
  metrics_emit_counter jobs_started_total
fi

exit 0
