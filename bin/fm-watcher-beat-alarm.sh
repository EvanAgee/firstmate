#!/usr/bin/env bash
# Session-independent watcher-down alert face. Runs outside the agent session
# (bin/fm-watcher-beat-alarm-install.sh wires it to a macOS launchd interval
# agent) so a fully dead session, a dead watcher, or a wedged supervision chain
# still alerts the captain. Reads state/.last-watcher-beat and fires ONE
# desktop-or-channel notification per outage episode through the shared
# active-alert machinery (bin/fm-wedge-alarm-lib.sh; config/wedge-alarm).
#
# Contract:
#   - Alert-only by default. It never starts, stops, arms, or repairs the
#     watcher or the session: the emitted supervision protocol owns recovery.
#     This script is observability, never a second watcher and never an
#     auto-restart path. FM_BEAT_ALARM_REARM=1 opts in to one extra step - it
#     backgrounds the home-scoped, self-verifying bin/fm-watch-arm.sh after the
#     alert, which attaches to a live watcher rather than starting a second one.
#     Even then the alert is the recovery path: an armed watcher queues wakes
#     durably but cannot wake the model.
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
#   FM_BEAT_ALARM_GRACE        grace seconds for this alert alone; defaults to
#                              FM_GUARD_GRACE (itself 300), which the shared
#                              config/supervision.env loader resolves through
#                              bin/fm-supervision-env-lib.sh so this alert and
#                              bin/fm-guard.sh cannot drift apart;
#                              staleness >= 2 * grace alerts
#   FM_WEDGE_ALARM_EXEC        the shared test seam for the notifier
#   FM_BEAT_ALARM_LOG_LIMIT    keep the self-log under N lines (default 200)
#   FM_BEAT_ALARM_REARM        1 opts in to also re-arming the watcher after an
#                              alert (default 0, alert-only). The alert is what
#                              restores supervision; a re-armed watcher only
#                              keeps queuing wakes durably until someone returns
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
      sed -n '2,/^set -u$/p' "$0" | sed '$d'
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

# Load this home's supervision knobs before the grace below is resolved. launchd
# inherits neither a harness setting nor an interactive shell profile, so without
# this the same home could answer "is the beacon stale?" with one number here and
# a different one in bin/fm-guard.sh.
# shellcheck source=bin/fm-supervision-env-lib.sh
. "$SCRIPT_DIR/fm-supervision-env-lib.sh"
fm_supervision_env_load "$CONFIG"

# FM_BEAT_ALARM_GRACE stays available for focused tuning of this alert alone, but
# the default is the guard's own value rather than a second hardcoded constant:
# raising FM_GUARD_GRACE used to leave this alert firing on the old threshold.
GRACE=${FM_BEAT_ALARM_GRACE:-${FM_GUARD_GRACE:-300}}
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
if [ "${FM_BEAT_ALARM_REARM:-0}" = 1 ]; then
  recovery_note='A fresh session owns recovery; this alert only re-armed the watcher to keep queuing wakes, which cannot wake the session by itself.'
else
  recovery_note='A fresh session or the emitted repair line owns recovery; this alert did not start or stop anything.'
fi
summary=$(printf \
  'watcher beacon stale %ss (>2x grace %ss) with supervision needed in %s; poll delivery may be stalled. %s' \
  "$age" "$GRACE" "$home_label" "$recovery_note")
log "ALERT: $summary"
FM_WEDGE_ALARM_TITLE="firstmate: watcher stopped polling" \
  wedge_alarm_notify "$summary" "$FIRED"

# Opt-in re-arm. Alert-only remains the default contract above: the alert is
# what restores supervision, because a re-armed watcher can queue wakes durably
# but has no channel to wake the model - that is the Stop hook, which needs the
# session that died. Re-arming only makes the wakes survive until someone
# returns.
#
# It is safe to schedule because bin/fm-watch-arm.sh is home-scoped and
# self-verifying: with a live watcher already holding this home's singleton it
# reports "attached" and follows that cycle instead of starting a second one.
# The arm blocks until its cycle closes, so it runs in the background with the
# episode marker already written, and a slow arm can never hold up the next
# scheduled alert check.
if [ "${FM_BEAT_ALARM_REARM:-0}" = 1 ]; then
  arm="$SCRIPT_DIR/fm-watch-arm.sh"
  if [ -x "$arm" ]; then
    log "rearm: starting $arm (opt-in FM_BEAT_ALARM_REARM=1)"
    FM_HOME="$FM_HOME" "$arm" >> "$BEAT_LOG" 2>&1 &
  else
    log "rearm: skipped, no executable arm at $arm"
  fi
fi
finish 0
