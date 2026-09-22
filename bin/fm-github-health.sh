#!/usr/bin/env bash
# fm-github-health.sh - the fleet's single GitHub reachability probe.
#
# It answers one question - "can we reach GitHub right now?" - and records the
# answer in one durable flag, state/.github-down, so the rest of firstmate has a
# single source of truth to tell "GitHub is down" apart from "this one task
# failed". The watcher calls it on its slow-check cadence (bin/fm-watch.sh) and
# reports the down->up / up->down transition to the captain exactly once; the
# outage local-merge path reads the flag to decide whether an outage landing is
# even allowed (bin/fm-merge-local.sh, bin/fm-outage-sync.sh).
#
# Discipline, modelled on bin/fm-pr-poll.sh and fetch_with_packed_refs_lock_guard
# in bin/fm-fleet-sync.sh:
#   - Bounded. Every reachability attempt is time-limited (curl --max-time /
#     --connect-timeout) so the probe can never hang the watcher. There is no
#     dependency on a `timeout` binary, which is absent on stock macOS.
#   - Confirmed before parking. A single failed request is NOT an outage - it
#     could be one bad response. The probe makes up to FM_GH_HEALTH_ATTEMPTS
#     (default 3) attempts and declares GitHub DOWN only when a majority fail;
#     the first attempt that succeeds is a confirming reachability check that
#     immediately settles the verdict as UP and stops. So one transient failure
#     can never park the fleet.
#   - Idempotent. Setting the flag when it already exists is a no-op that keeps
#     the original first-seen timestamp; clearing it when already clear is a
#     no-op. Two runs in a row leave identical state.
#   - Quiet. The default probe prints nothing about the reachable case; it only
#     writes/removes the flag. `status` prints the current verdict for callers
#     and tests.
#
# The reachability endpoint is api.github.com, reached unauthenticated. A
# successful TCP+TLS+HTTP round-trip to it is what "GitHub is reachable" means
# here; the exact HTTP status does not matter (even a 401/403/404 proves the
# service answered), only that the request completed rather than failing to
# connect or timing out. `gh` is deliberately not used for the reachability
# decision: `gh` conflates "logged out" with "offline" (see
# .agents/skills/bootstrap-diagnostics), which is the exact ambiguity this probe
# exists to remove.
#
# Usage:
#   fm-github-health.sh            probe once, update the flag, stay silent on reachable
#   fm-github-health.sh probe      same as the default
#   fm-github-health.sh status     print "up" or "down" for the current flag state
#   fm-github-health.sh transition probe, then print the new verdict ("up"/"down")
#                                  ONLY when it CHANGED since the last transition
#                                  call, and nothing otherwise. This is the single
#                                  owner of the "report the outage once" dedup: the
#                                  prior verdict lives in state/.github-health-last,
#                                  so a caller (the watcher) wakes exactly once per
#                                  real down<->up transition, never once per poll,
#                                  and the dedup survives a caller restart. The
#                                  first-ever observation reports only when it is
#                                  "down" (an outage in progress at startup is worth
#                                  one report); a first-ever "up" is the normal
#                                  baseline and stays silent.
#   fm-github-health.sh -h|--help  print this header
#
# Environment overrides (all optional):
#   FM_GH_HEALTH_URL         reachability URL (default https://api.github.com)
#   FM_GH_HEALTH_ATTEMPTS    attempts per probe (default 3; majority-fail = down)
#   FM_GH_HEALTH_MAX_TIME    per-attempt total timeout seconds (default 5)
#   FM_GH_HEALTH_CONNECT_TIMEOUT  per-attempt connect timeout seconds (default 3)
#   FM_GH_HEALTH_PROBE_CMD   test seam: a command run per attempt instead of
#                            curl; exit 0 = reachable, non-zero = unreachable.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FLAG="$STATE/.github-down"

URL=${FM_GH_HEALTH_URL:-https://api.github.com}
ATTEMPTS=${FM_GH_HEALTH_ATTEMPTS:-3}
MAX_TIME=${FM_GH_HEALTH_MAX_TIME:-5}
CONNECT_TIMEOUT=${FM_GH_HEALTH_CONNECT_TIMEOUT:-3}

case "${ATTEMPTS}" in
  ''|*[!0-9]*) ATTEMPTS=3 ;;
esac
[ "$ATTEMPTS" -ge 1 ] || ATTEMPTS=3

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# One bounded reachability attempt. Returns 0 when GitHub answered, non-zero
# when the request could not complete (connect failure or timeout). A test seam
# replaces the real network call so the probe's decision logic can be exercised
# offline and deterministically.
probe_once() {
  if [ -n "${FM_GH_HEALTH_PROBE_CMD:-}" ]; then
    sh -c "$FM_GH_HEALTH_PROBE_CMD" >/dev/null 2>&1
    return $?
  fi
  # -o /dev/null discards the body; --max-time is the hard per-attempt ceiling so
  # the probe cannot hang even if the connection stalls after connecting. Any
  # completed HTTP round-trip (including 4xx) means the service answered, so we
  # only care about curl's own success at completing the transfer.
  curl -sS -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    "$URL" >/dev/null 2>&1
}

# Decide reachability: reachable as soon as one attempt succeeds (a confirming
# reachability check), unreachable only when a majority of ATTEMPTS fail. This
# is the 2-of-3 guard generalized to any odd or even attempt count: a single bad
# response never flips the verdict to down.
github_is_reachable() {
  local i=0 failures=0 majority
  majority=$(( ATTEMPTS / 2 + 1 ))
  while [ "$i" -lt "$ATTEMPTS" ]; do
    i=$(( i + 1 ))
    if probe_once; then
      return 0
    fi
    failures=$(( failures + 1 ))
    if [ "$failures" -ge "$majority" ]; then
      return 1
    fi
  done
  # Every attempt failed but the majority test above already returns as soon as
  # it is reached, so this line is defensive: fewer than a majority of failures
  # means at least one success would have returned 0 already.
  return 1
}

set_down_flag() {
  mkdir -p "$STATE" 2>/dev/null || true
  # Idempotent: keep the original first-seen timestamp if the flag already
  # exists, so repeated down probes do not reset "when did this outage start".
  if [ ! -e "$FLAG" ]; then
    printf 'first_seen=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FLAG" 2>/dev/null || \
      : > "$FLAG" 2>/dev/null || true
  fi
}

clear_down_flag() {
  [ -e "$FLAG" ] && rm -f "$FLAG" 2>/dev/null || true
}

# Probe once, update the durable flag, and echo the resulting verdict ("up" or
# "down"). The single place reachability is turned into flag state, shared by the
# probe and transition commands.
run_probe_and_update_flag() {
  if github_is_reachable; then
    clear_down_flag
    printf '%s\n' up
  else
    set_down_flag
    printf '%s\n' down
  fi
}

LAST="$STATE/.github-health-last"

cmd=${1:-probe}
case "$cmd" in
  -h|--help)
    usage
    exit 0
    ;;
  status)
    if [ -e "$FLAG" ]; then
      echo down
    else
      echo up
    fi
    exit 0
    ;;
  probe)
    run_probe_and_update_flag >/dev/null
    exit 0
    ;;
  transition)
    now=$(run_probe_and_update_flag)
    last=$(cat "$LAST" 2>/dev/null || echo "")
    if [ "$now" != "$last" ]; then
      mkdir -p "$STATE" 2>/dev/null || true
      printf '%s' "$now" > "$LAST" 2>/dev/null || true
      # Report a real transition, plus the first-ever observation only when it is
      # an outage in progress; a first-ever "up" is the silent normal baseline.
      if [ -n "$last" ] || [ "$now" = down ]; then
        printf '%s\n' "$now"
      fi
    fi
    exit 0
    ;;
  *)
    echo "error: unknown command '$cmd' (expected probe, status, transition, -h, or --help)" >&2
    exit 2
    ;;
esac
