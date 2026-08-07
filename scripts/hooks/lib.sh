#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the runner metrics hooks. Sourced by job-started.sh,
# job-completed.sh, heartbeat.sh and runner-run.sh.
#
# Design contract:
#   * Everything here is BEST EFFORT. A metrics failure must never break a job:
#     the callers always `exit 0`, and every function below swallows its own
#     errors. Do NOT `set -e` in anything that sources this.
#   * Delivery is statsd over UDP via bash's built-in /dev/udp — no external
#     binary, so the hardened image gains no new package / CVE surface.
#   * Tags use the dogstatsd extension (`|#k:v,...`) which statsd_exporter maps
#     to Prometheus labels.
#
# All behaviour is gated on RUNNER_METRICS_STATSD_ADDR. When it is unset the
# whole feature is a no-op and the runner behaves exactly as upstream.

# --- configuration (all optional) -------------------------------------------
METRICS_ADDR="${RUNNER_METRICS_STATSD_ADDR:-}"
METRICS_PREFIX="${RUNNER_METRICS_PREFIX:-github_runner}"
METRICS_HEARTBEAT_INTERVAL="${RUNNER_METRICS_HEARTBEAT_INTERVAL:-15}"
METRICS_EXTRA_LABELS="${RUNNER_METRICS_EXTRA_LABELS:-}"
METRICS_STATE_FILE="${RUNNER_METRICS_STATE_FILE:-/tmp/runner-metrics.state}"
METRICS_JOBSTART_FILE="${RUNNER_METRICS_JOBSTART_FILE:-/tmp/runner-metrics.jobstart}"
METRICS_DEBUG="${RUNNER_METRICS_DEBUG:-}"
METRICS_LOG_FILE="${RUNNER_METRICS_LOG_FILE:-/tmp/runner-metrics.log}"

# Populated by metrics_read_state.
_METRICS_STATE="idle"
_METRICS_BUSY_TAGS=""

metrics_enabled() {
  [[ -n "${METRICS_ADDR}" ]]
}

# --- debug logging (opt-in via RUNNER_METRICS_DEBUG) -------------------------
# Off by default so the image stays a quiet drop-in. When on, every emit and
# every send failure is written to stderr (visible in `docker logs`) and
# appended to METRICS_LOG_FILE — inspect a live container with
# `docker exec <runner> cat /tmp/runner-metrics.log`.

_metrics_debug() {
  [[ -n "${METRICS_DEBUG}" && "${METRICS_DEBUG}" != "0" && "${METRICS_DEBUG}" != "false" ]]
}

_metrics_log() {
  _metrics_debug || return 0
  local ts; ts="$(date '+%H:%M:%S' 2>/dev/null || true)"
  printf '[runner-metrics %s] %s\n' "${ts}" "$1" >&2
  printf '[runner-metrics %s] %s\n' "${ts}" "$1" >> "${METRICS_LOG_FILE}" 2>/dev/null || true
}

# metrics_log_banner <where> — dump the resolved config once, to diagnose why
# nothing shows up. Cheap no-op unless RUNNER_METRICS_DEBUG is set.
metrics_log_banner() {
  _metrics_debug || return 0
  if metrics_enabled; then
    _metrics_log "[$1] ENABLED addr=${METRICS_ADDR} prefix=${METRICS_PREFIX} interval=${METRICS_HEARTBEAT_INTERVAL}s runner=$(_metrics_runner_name) org=$(_metrics_org)"
  else
    _metrics_log "[$1] DISABLED — RUNNER_METRICS_STATSD_ADDR is unset in this container"
  fi
}

# --- low level ---------------------------------------------------------------

# _metrics_send <statsd-line>
# Fire exactly one UDP packet. Synchronous but cheap; callers that must not
# block (the hooks) wrap the call in a backgrounded subshell. All errors —
# including a slow/failed DNS resolve or an unreachable host — are swallowed.
_metrics_send() {
  local line="$1"
  local host port
  host="${METRICS_ADDR%:*}"
  port="${METRICS_ADDR##*:}"
  [[ -n "${host}" && -n "${port}" ]] || return 0
  if ( exec 3<>"/dev/udp/${host}/${port}" && printf '%s' "${line}" >&3 ) 2>/dev/null; then
    _metrics_log "sent -> ${host}:${port}  ${line}"
  else
    # UDP is connectionless, so this only fails when the host can't be resolved
    # or the socket can't be opened — exactly the signal you want when nothing
    # arrives (e.g. an unresolvable statsd hostname).
    _metrics_log "SEND FAILED (resolve/open) -> ${host}:${port}  ${line}"
  fi
  return 0
}

# _metrics_sanitize <value>
# Reduce a label value to something safe for a dogstatsd tag: anything that
# would break tag parsing (comma, colon, pipe, hash, whitespace, ...) becomes
# an underscore. Workflow/job names are arbitrary user text, so this matters.
# Uses tr (not bash pattern substitution): the negated-class form is a silent
# no-op under bash 3.2, and LC_ALL=C keeps it byte-wise and deterministic.
_metrics_sanitize() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_./-' '_'
}

# _metrics_join <tag> [tag...]
# Comma-join non-empty tag fragments.
_metrics_join() {
  local out="" p
  for p in "$@"; do
    [[ -z "${p}" ]] && continue
    if [[ -z "${out}" ]]; then out="${p}"; else out="${out},${p}"; fi
  done
  printf '%s' "${out}"
}

# --- identity ----------------------------------------------------------------

# The runner's own name. Prefer RUNNER_NAME (set by the runner inside a job),
# fall back to the configured agent name in .runner (available to the pre-job
# heartbeat, which has no job context yet).
_metrics_runner_name() {
  local n="${RUNNER_NAME:-}"
  if [[ -z "${n}" && -r /actions-runner/.runner ]]; then
    n="$(jq -r '.agentName // empty' /actions-runner/.runner 2>/dev/null || true)"
  fi
  printf '%s' "${n:-unknown}"
}

# Best-effort org/owner. ORG_NAME is the container's own env; if unset (e.g.
# UNSET_CONFIG_VARS=true) fall back to GITHUB_REPOSITORY_OWNER (job context)
# then to the last path segment of the configured gitHubUrl.
_metrics_org() {
  local o="${ORG_NAME:-${GITHUB_REPOSITORY_OWNER:-}}"
  if [[ -z "${o}" && -r /actions-runner/.runner ]]; then
    local url
    url="$(jq -r '.gitHubUrl // empty' /actions-runner/.runner 2>/dev/null || true)"
    o="${url##*/}"
  fi
  printf '%s' "${o}"
}

# --- tag builders ------------------------------------------------------------

# Tags carried by the per-runner status gauge: runner + org + static extras.
metrics_gauge_base_tags() {
  local runner org
  runner="$(_metrics_sanitize "$(_metrics_runner_name)")"
  org="$(_metrics_sanitize "$(_metrics_org)")"
  _metrics_join "runner:${runner}" "${org:+org:${org}}" "${METRICS_EXTRA_LABELS}"
}

# Tags describing the job currently being run, derived from the GitHub job
# context available to the hooks. No runner label (kept off counters to bound
# cardinality) and no unbounded fields (run_id/sha/actor).
metrics_context_busy_tags() {
  local repo workflow job event
  repo="$(_metrics_sanitize "${GITHUB_REPOSITORY:-}")"
  workflow="$(_metrics_sanitize "${GITHUB_WORKFLOW:-}")"
  job="$(_metrics_sanitize "${GITHUB_JOB:-}")"
  event="$(_metrics_sanitize "${GITHUB_EVENT_NAME:-}")"
  _metrics_join \
    "${repo:+repo:${repo}}" \
    "${workflow:+workflow:${workflow}}" \
    "${job:+job:${job}}" \
    "${event:+event:${event}}"
}

# Tags for throughput counters/timers: org + job context + static extras
# (deliberately no runner label).
metrics_context_fleet_tags() {
  local org
  org="$(_metrics_sanitize "$(_metrics_org)")"
  _metrics_join "${org:+org:${org}}" "$(metrics_context_busy_tags)" "${METRICS_EXTRA_LABELS}"
}

# --- state file --------------------------------------------------------------
# Line 1: idle|busy    Line 2: busy tags (kept even while idle so the heartbeat
# keeps refreshing the busy series to 0 and a dropped transition packet
# self-corrects on the next tick).

metrics_write_state() {
  local state="$1" busy_tags="${2:-}"
  printf '%s\n%s\n' "${state}" "${busy_tags}" > "${METRICS_STATE_FILE}" 2>/dev/null || true
}

metrics_read_state() {
  _METRICS_STATE="idle"
  _METRICS_BUSY_TAGS=""
  [[ -r "${METRICS_STATE_FILE}" ]] || return 0
  local line1 line2
  { IFS= read -r line1; IFS= read -r line2; } < "${METRICS_STATE_FILE}" 2>/dev/null || true
  [[ "${line1}" == "busy" || "${line1}" == "idle" ]] && _METRICS_STATE="${line1}"
  _METRICS_BUSY_TAGS="${line2}"
}

# --- emitters ----------------------------------------------------------------

# Emit the per-runner status gauge for BOTH states every call — exactly one is
# 1, the other 0 — so `sum by (state) (github_runner_status)` is always
# correct and a lost packet self-corrects next tick. statsd_exporter's TTL
# expires the series shortly after the runner stops emitting (self-heal).
metrics_emit_status() {
  metrics_enabled || return 0
  local base idle_val busy_val busy_series
  base="$(metrics_gauge_base_tags)"
  metrics_read_state
  if [[ "${_METRICS_STATE}" == "busy" ]]; then idle_val=0; busy_val=1; else idle_val=1; busy_val=0; fi
  busy_series="state:busy"
  [[ -n "${_METRICS_BUSY_TAGS}" ]] && busy_series="state:busy,${_METRICS_BUSY_TAGS}"
  ( _metrics_send "${METRICS_PREFIX}_status:${idle_val}|g|#${base},state:idle" ) &
  ( _metrics_send "${METRICS_PREFIX}_status:${busy_val}|g|#${base},${busy_series}" ) &
  return 0
}

# metrics_emit_offline — one-shot "this runner is gone" signal: both idle and
# busy pinned to 0. Called by the watcher in runner-run.sh the instant
# Runner.Listener exits, so a graceful stop (docker stop / scale-down, with or
# without a job in flight) clears the runner out of `sum by (state)`
# immediately instead of waiting out the status gauge's TTL. Synchronous (not
# backgrounded): the caller is about to exit itself and needs this to land
# first. Does nothing for a SIGKILL'd container — there is no code path left
# to run at that point, which is exactly what the TTL exists to cover.
metrics_emit_offline() {
  metrics_enabled || return 0
  local base; base="$(metrics_gauge_base_tags)"
  _metrics_send "${METRICS_PREFIX}_status:0|g|#${base},state:idle"
  _metrics_send "${METRICS_PREFIX}_status:0|g|#${base},state:busy"
}

# metrics_emit_counter <name-without-prefix> [extra-tags]
metrics_emit_counter() {
  metrics_enabled || return 0
  local name="$1" extra="${2:-}"
  local tags; tags="$(_metrics_join "$(metrics_context_fleet_tags)" "${extra}")"
  ( _metrics_send "${METRICS_PREFIX}_${name}:1|c|#${tags}" ) &
  return 0
}

# metrics_emit_timer <name-without-prefix> <value-in-ms> [extra-tags]
# statsd_exporter converts `ms` observations to seconds, so a metric named
# *_seconds receives milliseconds on the wire.
metrics_emit_timer() {
  metrics_enabled || return 0
  local name="$1" value_ms="$2" extra="${3:-}"
  local tags; tags="$(_metrics_join "$(metrics_context_fleet_tags)" "${extra}")"
  ( _metrics_send "${METRICS_PREFIX}_${name}:${value_ms}|ms|#${tags}" ) &
  return 0
}

# metrics_emit_gauge <name-without-prefix> <value> [tags]
# Unlike the emitters above this does NOT derive its own tags: its caller
# (config-run.sh) runs at registration time, before any job context exists and
# before the runner has a name, so the usual tag builders don't apply. The
# caller passes a fully-formed tag string instead. Synchronous, because the
# caller exits immediately after.
metrics_emit_gauge() {
  metrics_enabled || return 0
  local name="$1" value="$2" tags="${3:-}"
  _metrics_send "${METRICS_PREFIX}_${name}:${value}|g|#${tags}"
  return 0
}

# metrics_registration_tags — labels for the registration-time gauge. There is
# no `runner` label on purpose: the value describes the shared PAT / App
# installation budget, not a property of whichever runner happened to observe
# it, and one series per ephemeral runner would be exactly the cardinality
# blow-up the counters avoid. `labels` mirrors entrypoint.sh's own _LABELS
# fallback so runner pools can be told apart; it is a comma-separated list, and
# _metrics_sanitize collapses the commas so it survives as ONE tag value.
metrics_registration_tags() {
  local org labels
  org="$(_metrics_sanitize "${ORG_NAME:-}")"
  labels="$(_metrics_sanitize "${RUNNER_LABELS:-${LABELS:-default}}")"
  _metrics_join "${org:+org:${org}}" "${labels:+labels:${labels}}" "${METRICS_EXTRA_LABELS}"
}
