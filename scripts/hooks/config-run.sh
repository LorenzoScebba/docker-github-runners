#!/usr/bin/env bash
# shellcheck shell=bash
#
# Wrapper installed as /actions-runner/config.sh; the runner's own script is
# moved aside to config.real.sh by the Dockerfile. entrypoint.sh calls
# `./config.sh` (register) and `./config.sh remove` (deregister) — both land
# here, and both must behave exactly as before.
#
# Why this exists: registering a runner costs one GitHub REST request, and
# operators want to see how much of the hourly budget is left. That number is
# only ever on the response headers of the registration call the runner makes
# itself (`POST .../actions/runner-registration`) — which no runtime script can
# see, because Runner.Listener performs it internally over TLS. There is no
# token available afterwards either (a pre-minted RUNNER_TOKEN deployment never
# has a PAT in the container at all), so a follow-up /rate_limit call is not an
# option.
#
# The runner has a built-in answer: GITHUB_ACTIONS_RUNNER_HTTPTRACE=true makes
# it dump every HTTP request/response — headers included — into its own diag
# log. We turn that on for the registration invocation ONLY, read the
# rate-limit header back out of the log, and emit it. Consequences worth
# knowing:
#   * The trace is scoped to this one short-lived process. Runner.Listener runs
#     as a separate process without the variable, so no job traffic is ever
#     dumped.
#   * .NET redacts the auth header (`Authorization: RemoteAuth ***`) and never
#     dumps bodies, so the trace carries no registration token. It does add a
#     few KB of request/response headers to _diag — see README.
#   * Zero extra API calls: this reads a response GitHub already sent.
#
# Best effort, like everything else under hooks/: any failure here leaves
# registration untouched, and config.sh's exit code is always preserved (it is
# load-bearing — entrypoint.sh aborts the container on a failed registration).

_REAL="/actions-runner/config.real.sh"
_HOOKS_DIR="/actions-runner/hooks"
_DIAG_DIR="/actions-runner/_diag"

# If the real script is gone we cannot do anything useful — fail loudly rather
# than silently "succeeding" at a registration that never happened.
if [[ ! -x "${_REAL}" ]]; then
  echo "config.sh wrapper: ${_REAL} is missing or not executable" >&2
  exit 1
fi

# Transparent passthrough when the metrics library is absent or metrics are
# off: exec means this wrapper leaves no trace in the process tree.
# shellcheck source=/dev/null
source "${_HOOKS_DIR}/lib.sh" 2>/dev/null || exec "${_REAL}" "$@"
metrics_enabled || exec "${_REAL}" "$@"

# Deregistration hits a different endpoint and is not what we measure; don't
# pay the trace cost for it.
[[ "${1:-}" == "remove" ]] && exec "${_REAL}" "$@"

metrics_log_banner config

# _config_rate_remaining <logfile>...
# Pull the remaining-request count off the registration response.
#
# The runner emits one `HttpRequestOut.Stop` event per completed request, and
# that single event carries BOTH the response headers and the request URI — so
# the value can be attributed to the registration call rather than to whichever
# request happened to be logged last. Layout:
#
#   Trace System.Net.Http.HttpRequestOut.Stop event:
#   { Response = StatusCode: 201, ..., Headers:
#   {
#     x-ratelimit-remaining: 14321
#   }, Request = Method: POST, RequestUri: '<url>', ... }
#
# Matching is case-INSENSITIVE and that is load-bearing, not defensive: real
# github.com answers over HTTP/2, where header names are lowercase on the wire
# and .NET dumps them as received (`x-ratelimit-remaining`). Only an HTTP/1.1
# peer sends the canonical `X-RateLimit-Remaining` spelling. Matching the
# canonical case alone silently finds nothing against real GitHub.
#
# Keeps the LAST match, so a retried registration reports the final reading.
_config_rate_remaining() {
  awk '
    /Trace System\.Net\.Http\.HttpRequestOut\.Stop event:/ { in_event = 1; remaining = ""; next }
    in_event && tolower($0) ~ /x-ratelimit-remaining:/ {
      value = tolower($0)
      sub(/^.*x-ratelimit-remaining:[[:space:]]*/, "", value)
      sub(/[^0-9].*$/, "", value)
      remaining = value
      next
    }
    in_event && /RequestUri:/ {
      if (remaining != "" && (tolower($0) ~ /runner-registration/ || tolower($0) ~ /\/actions\/runners\/register/)) {
        last = remaining
      }
      in_event = 0
    }
    END { if (last != "") print last }
  ' "$@" 2>/dev/null
}

# Reference point for "diag logs written by the run below". The runner names
# them Runner_<timestamp>-utc.log and Runner.Listener writes to the same
# directory later, so a plain newest-file match would be ambiguous.
_MARKER="$(mktemp 2>/dev/null || echo /tmp/.config-run-marker.$$)"
: > "${_MARKER}" 2>/dev/null || true

GITHUB_ACTIONS_RUNNER_HTTPTRACE=true "${_REAL}" "$@"
_RC=$?

# Parse and emit even when registration failed: a 403 from an exhausted budget
# is precisely when this number matters most.
#
# Deliberately NOT wrapped in a blanket `2>/dev/null`: _metrics_log writes to
# stderr, so silencing this block would silence exactly the diagnostics that
# explain a missing metric. Each command below guards itself instead.
_LOGS=()
while IFS= read -r _f; do
  [[ -n "${_f}" ]] && _LOGS+=("${_f}")
done < <(find "${_DIAG_DIR}" -maxdepth 1 -type f -name 'Runner_*.log' -newer "${_MARKER}" 2>/dev/null || true)
rm -f "${_MARKER}" 2>/dev/null || true

if [[ ${#_LOGS[@]} -eq 0 ]]; then
  _metrics_log "config: no diag log written by this run under ${_DIAG_DIR} — nothing to parse"
else
  _metrics_log "config: scanning ${#_LOGS[@]} diag log(s): ${_LOGS[*]}"
  if ! grep -q 'HttpTrace' "${_LOGS[@]}" 2>/dev/null; then
    _metrics_log "config: no HttpTrace lines in the diag log — GITHUB_ACTIONS_RUNNER_HTTPTRACE had no effect on runner $(cat /actions-runner/bin/.version 2>/dev/null || echo '?')"
  fi
  _REMAINING="$(_config_rate_remaining "${_LOGS[@]}")"
  if [[ "${_REMAINING}" =~ ^[0-9]+$ ]]; then
    metrics_emit_gauge api_rate_limit_remaining "${_REMAINING}" "$(metrics_registration_tags)"
  else
    # Say what WAS in the trace, so a missing metric is diagnosable from one
    # run: either GitHub sends no rate-limit header on this endpoint, or it
    # names it differently, or the request never matched our URI filter.
    _metrics_log "config: no rate-limit reading for the registration call. Rate-limit headers seen: [$(grep -ioh 'x-ratelimit-[a-z]*:[[:space:]]*[0-9]*' "${_LOGS[@]}" 2>/dev/null | sort -u | tr '\n' ' ')]"
    _metrics_log "config: request URIs traced: [$(grep -oh "RequestUri: '[^']*'" "${_LOGS[@]}" 2>/dev/null | sort -u | tr '\n' ' ')]"
  fi
fi

exit "${_RC}"
