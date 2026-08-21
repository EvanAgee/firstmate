#!/usr/bin/env bash
# Session-independent watcher-down alert face. Runs outside the agent session
# (bin/fm-watcher-beat-alarm-install.sh wires it to a macOS launchd interval
# agent) so a fully dead session, a dead watcher, or a wedged supervision chain
# still alerts the captain. Reads state/.last-watcher-beat and fires ONE
# desktop-or-channel notification per outage episode through the shared
# active-alert machinery (bin/fm-wedge-alarm-lib.sh; config/wedge-alarm).
#
# Contract:
#   - Alert-only. It never starts, stops, arms, or repairs the watcher or the
#     session: the emitted supervision protocol owns recovery. This script is
#     observability, never a second watcher and never an auto-restart path.
#   - Needs supervision: it alerts only when the home needs supervision
#     (in-flight tasks, registered event sources, or an X-mode relay poll, per
#     bin/fm-supervision-lib.sh) and quietens otherwise.
#   - Attended only: state/.afk suppresses the alert because the away-mode
#     daemon owns escalation while away mode is active.
#   - Confirmed staleness: the beacon must be stale past one grace AND stay
#     stale across a full additional grace window (age >= 2 * grace) before the
#     alert fires, so an ordinary between-wakes gap never alerts.
#   - Single-fire per outage episode: state/.beat-alarm-fired records the
#     alerted beacon mtime; reminders never re-fire while the same beacon age
#     drives the episode, a fresh beacon clears the marker, and the NEXT
#     episode alerts once again.
#
# Not installed by default. bin/fm-watcher-beat-alarm-install.sh installs and
# removes the launchd agent with an explicit consent prompt.
#
# Env knobs (tests and focused tuning):
#   FM_BEAT_ALARM_GRACE        grace seconds (default 300, aligned with
#                              FM_GUARD_GRACE); staleness >= 2 * grace alerts
#   FM_WEDGE_ALARM_EXEC        the shared test seam for the notifier
#   FM_BEAT_ALARM_LOG_LIMIT    keep the self-log under N lines (default 200)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME_OVERRIDE:-${FM_HOME:-$FM_ROOT}}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      FM_HOME=$2
      shift 2
      ;;
    --home=*)
      FM_HOME=${1#--home=}
      shift
      ;;
    -h|--help)
      sed -n 2,44p "$0"
      exit 0
      ;;
    *)
      echo "watcher-beat-alarm: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

STATE="$FM_HOME/state"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
export FM_CONFIG_OVERRIDE="$CONFIG"
GRACE=${FM_BEAT_ALARM_GRACE:-300}
case "$GRACE" in *[!0-9]*) GRACE=300 ;; esac
BEAT="$STATE/.last-watcher-beat"
FIRED="$STATE/.beat-alarm-fired"
BEAT_LOG="$STATE/.beat-alarm.log"
LOG_LIMIT=${FM_BEAT_ALARM_LOG_LIMIT:-200}

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"

LOG=${FM_BEAT_ALARM_LOG:-$BEAT_LOG}
log() {
  [ -n "$LOG" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"
}

trim_log() {
  [ -f "$LOG" ] || return 0
  local lines
  lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  [ "$lines" -gt "$LOG_LIMIT" ] || return 0
  tail -n "$LOG_LIMIT" "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
}

finish() {
  trim_log
  exit "${1:-0}"
}

# A home with no beacon at all has never run (or completed and removed) a
# watcher cycle; with no durable evidence of supervision-decay there is nothing
# to alert on, and an absent state dir means the home is not in use here.
[ -d "$STATE" ] || exit 0
if [ ! -e "$BEAT" ]; then
  log "silent: no watcher beacon at $BEAT"
  finish 0
fi

# Away mode owns escalation through its own daemon wedge alarm; the attended
# contract outranks this alert exactly as the in-session guard path does.
if [ -e "$STATE/.afk" ]; then
  log "silent: away mode active; the away-mode daemon owns escalation"
  finish 0
fi

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" != true ]; then
  log "silent: home needs no supervision"
  finish 0
fi

beat_mtime=$(fm_sup_stat_mtime "$BEAT")
case "$beat_mtime" in ''|*[!0-9]*)
  log "silent: unreadable beacon mtime at $BEAT"
  finish 0
  ;;
esac
now=$(date +%s)
age=$((now - beat_mtime))

# Fresh beacon: the watcher just voted live, so any alerted episode is over.
if [ "$age" -lt "$GRACE" ]; then
  rm -f "$FIRED" 2>/dev/null || true
  finish 0
fi

# Grace-plus-one-window confirmation: only once the beacon has been stale past
# one full grace AND stayed stale across a full additional grace window is a
# dead session distinguishable from an ordinary between-wakes gap.
if [ "$age" -lt "$((2 * GRACE))" ]; then
  log "silent: beacon stale ${age}s (inside the second confirmation window)"
  finish 0
fi

# Single-fire per episode: an already-alerted beacon never alerts again; when
# the watcher later votes live, the fresh-beacon branch above clears the marker
# so the NEXT outage episodes each alert exactly once.
if [ -f "$FIRED" ] && [ "$(cat "$FIRED" 2>/dev/null)" = "$beat_mtime" ]; then
  finish 0
fi

printf '%s\n' "$beat_mtime" > "$FIRED" 2>/dev/null || true
home_label=${FM_HOME##*/}
summary=$(printf \
  'watcher beacon stale %ss (>2x grace %ss) with supervision needed in %s; poll delivery may be stalled. A fresh session or the emitted repair line owns recovery; this alert did not start or stop anything.' \
  "$age" "$GRACE" "$home_label")
log "ALERT: $summary"
FM_WEDGE_ALARM_TITLE="firstmate: watcher stopped polling" \
  wedge_alarm_notify "$summary" "$FIRED"
finish 0
