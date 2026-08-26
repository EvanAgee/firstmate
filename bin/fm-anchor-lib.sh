#!/usr/bin/env bash
# Session anchor and odometer for long-lived primary sessions.
#
# Problem (captain-reported, 2026-08-21): a long-running firstmate session
# degrades - conversation-context compaction silently drops standing steers and
# cadence habits, and nothing forces the session to re-read durable truth
# mid-session. This library is the ONE owner of the anti-drift anchors:
#
#   ANCHOR block (fm_anchor_on_heartbeat): bin/fm-wake-drain.sh prints it only
#   on drains that presented a heartbeat wake (never on ordinary signal/stale/
#   check drains, so routine handling stays tight). A successful print touches
#   state/.last-anchor; the attended watcher presents a no-change heartbeat when
#   that file is missing or older than FM_ANCHOR_INTERVAL (default HEARTBEAT_MAX)
#   so a live idle session still re-reads after compaction. The block re-reads durable
#   state and prints a bounded reminder a compacted session can no longer lose:
#   the standing-steers excerpt of data/captain.md, the fleet-wide
#   open-decision count, the in-flight task count, any stale-flag warnings
#   (GitHub-outage clone-staleness marker, an active watcher-down banner), and
#   the odometer advice line when the session age or handled-wake count passes
#   its configured threshold.
#
#   Odometer (fm_odometer_note_drain, fm_odometer_advice): private counters in
#   state/.session-odometer - the session-lock holder the counters belong to,
#   the session start epoch, and the number of wake records its drains have
#   handled. Thresholds come from the first line of config/session-odometer as
#   two whitespace-separated numbers (max-age-seconds max-wakes, default
#   "21600 200"); missing or unparseable values fall back to the defaults. When
#   a threshold is exceeded the ANCHOR block gains one advice line: tell the
#   captain a fresh session is recommended. There is no forced restart - per
#   AGENTS.md a restart is a designed non-event and the decision stays human.
#
#   FM_ODOMETER_MAX_AGE / FM_ODOMETER_MAX_WAKES override the file for tests.
#   The standing-steers excerpt defaults to a 16 KiB output budget so short
#   one-line rules stay cheap without an accidental rule-count cutoff.
#   FM_ANCHOR_STEERS_MAX_BYTES overrides that byte budget.
#   FM_ANCHOR_STEERS_MAX_LINES remains an optional additional line cap for
#   config/supervision.env compatibility; unset means no separate line cap.

FM_ANCHOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervision-lib.sh
. "$FM_ANCHOR_LIB_DIR/fm-supervision-lib.sh"

FM_ANCHOR_STEERS_MAX_BYTES=${FM_ANCHOR_STEERS_MAX_BYTES:-16384}
case "$FM_ANCHOR_STEERS_MAX_BYTES" in ''|*[!0-9]*) FM_ANCHOR_STEERS_MAX_BYTES=16384 ;; esac
[ "$FM_ANCHOR_STEERS_MAX_BYTES" -gt 0 ] || FM_ANCHOR_STEERS_MAX_BYTES=16384
FM_ANCHOR_STEERS_MAX_LINES=${FM_ANCHOR_STEERS_MAX_LINES:-0}
case "$FM_ANCHOR_STEERS_MAX_LINES" in ''|*[!0-9]*) FM_ANCHOR_STEERS_MAX_LINES=0 ;; esac

fm_odometer_file() {
  printf '%s/.session-odometer\n' "$STATE"
}

# Read the age/wake thresholds: config/session-odometer first (two whitespace-
# separated numbers: max-age-seconds max-wakes), then env overrides for tests.
fm_odometer_thresholds() { # -> FM_ODOMETER_MAX_AGE_EFF FM_ODOMETER_MAX_WAKES_EFF
  local cfg a='' w=''
  FM_ODOMETER_MAX_AGE_EFF=21600
  FM_ODOMETER_MAX_WAKES_EFF=200
  cfg="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_ROOT}/config}/session-odometer"
  if [ -f "$cfg" ]; then
    read -r a w < "$cfg" 2>/dev/null || true
    case "$a" in ''|*[!0-9]*) ;; *) FM_ODOMETER_MAX_AGE_EFF=$a ;; esac
    case "$w" in ''|*[!0-9]*) ;; *) [ "$w" -gt 0 ] && FM_ODOMETER_MAX_WAKES_EFF=$w ;; esac
  fi
  case "${FM_ODOMETER_MAX_AGE:-}" in ''|*[!0-9]*) ;; *) FM_ODOMETER_MAX_AGE_EFF=$FM_ODOMETER_MAX_AGE ;; esac
  case "${FM_ODOMETER_MAX_WAKES:-}" in ''|*[!0-9]*) ;; *) FM_ODOMETER_MAX_WAKES_EFF=$FM_ODOMETER_MAX_WAKES ;; esac
}

# The harness pid recorded by the session lock identifies the holder whose
# counters these are; any holder switch starts a fresh odometer.
fm_odometer_holder() {
  local lock="${FM_SESSION_LOCK_FILE:-$STATE/.lock}"
  if [ -f "$lock" ]; then
    head -n 1 "$lock" 2>/dev/null | LC_ALL=C tr -d '\r\n'
  else
    printf 'unknown\n'
  fi
}

# Note <n> handled wake records against the current session-lock holder.
# Resets the counters whenever the holder differs so a restarted session never
# inherits its predecessor's odometer.
fm_odometer_note_drain() { # <handled-count>
  local n=${1:-0} holder started wakes opid ostarted owakes
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || return 0
  holder=$(fm_odometer_holder)
  started=$(date +%s)
  wakes=0
  FM_ODOMETER_FILE=$(fm_odometer_file)
  if [ -f "$FM_ODOMETER_FILE" ]; then
    opid=$(sed -n '1s/^pid=//p' "$FM_ODOMETER_FILE" 2>/dev/null)
    ostarted=$(sed -n '2s/^started_epoch=//p' "$FM_ODOMETER_FILE" 2>/dev/null)
    owakes=$(sed -n '3s/^wakes=//p' "$FM_ODOMETER_FILE" 2>/dev/null)
    case "$ostarted" in ''|*[!0-9]*) ostarted=$started ;; esac
    case "$owakes" in ''|*[!0-9]*) owakes=0 ;; esac
    if [ "$opid" = "$holder" ] && [ -n "$opid" ]; then
      started=$ostarted
      wakes=$owakes
    fi
  fi
  wakes=$((wakes + n))
  {
    printf 'pid=%s\n' "$holder"
    printf 'started_epoch=%s\n' "$started"
    printf 'wakes=%s\n' "$wakes"
  } > "$FM_ODOMETER_FILE" 2>/dev/null || true
}

# Print the one-line restart advice exactly when a configured threshold is
# exceeded. Advice only; nothing restarts anything here.
fm_odometer_advice() {
  local file holder started wakes age
  file=$(fm_odometer_file)
  [ -f "$file" ] || return 0
  holder=$(fm_odometer_holder)
  [ "$(sed -n '1s/^pid=//p' "$file" 2>/dev/null)" = "$holder" ] || return 0
  started=$(sed -n '2s/^started_epoch=//p' "$file" 2>/dev/null)
  wakes=$(sed -n '3s/^wakes=//p' "$file" 2>/dev/null)
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  case "$wakes" in ''|*[!0-9]*) wakes=0 ;; esac
  age=$(( $(date +%s) - started ))
  fm_odometer_thresholds
  if [ "$age" -ge "$FM_ODOMETER_MAX_AGE_EFF" ] || [ "$wakes" -ge "$FM_ODOMETER_MAX_WAKES_EFF" ]; then
    printf 'odometer: session over threshold (%ss elapsed, %s wakes handled; thresholds %ss/%s) - tell the captain a fresh session is recommended; a restart is a designed non-event.\n' \
      "$age" "$wakes" "$FM_ODOMETER_MAX_AGE_EFF" "$FM_ODOMETER_MAX_WAKES_EFF"
  fi
}

# Print the bounded ANCHOR body on heartbeat wake presentations.
fm_anchor_on_heartbeat() {
  local home=${FM_HOME:-$FM_ROOT} captain steers total_lines=0 line excerpt_lines=0
  local excerpt_bytes=0 line_bytes=0 excerpt_bound=''
  local open_lines open_count=0 flags=''
  printf '%s\n' 'ANCHOR (durable truth re-read on this heartbeat; survives context compaction):'

  captain="$home/data/captain.md"
  if [ -f "$captain" ]; then
    steers=$(awk '
      /^## / { in_steer = ($0 == "## Working style") ? 1 : 0; next }
      in_steer { print }
    ' "$captain" 2>/dev/null)
    if [ -n "$steers" ]; then
      total_lines=$(printf '%s\n' "$steers" | awk 'NF{c++} END{print c+0}')
      printf 'standing steers (data/captain.md ## Working style):\n'
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$FM_ANCHOR_STEERS_MAX_LINES" -gt 0 ] \
          && [ "$excerpt_lines" -ge "$FM_ANCHOR_STEERS_MAX_LINES" ]; then
          excerpt_bound="$FM_ANCHOR_STEERS_MAX_LINES-line override"
          break
        fi
        line_bytes=$(LC_ALL=C printf '  %s\n' "$line" | wc -c | tr -d '[:space:]')
        if [ "$((excerpt_bytes + line_bytes))" -gt "$FM_ANCHOR_STEERS_MAX_BYTES" ]; then
          excerpt_bound="$FM_ANCHOR_STEERS_MAX_BYTES-byte budget"
          break
        fi
        printf '  %s\n' "$line"
        excerpt_lines=$((excerpt_lines + 1))
        excerpt_bytes=$((excerpt_bytes + line_bytes))
      done <<< "$steers"
      if [ "$excerpt_lines" -lt "$total_lines" ]; then
        printf '  WARNING: %s standing-steer lines omitted at explicit %s; full file at %s\n' \
          "$((total_lines - excerpt_lines))" "$excerpt_bound" "$captain"
      fi
    fi
  fi

  open_lines=$(scan_open_decisions "$STATE" 2>/dev/null || true)
  if [ -n "$open_lines" ]; then
    open_count=$(printf '%s\n' "$open_lines" | awk 'NF{c++} END{print c+0}')
  fi
  fm_supervision_status "$STATE" "${FM_GUARD_GRACE:-300}"
  printf 'open decisions: %s | in-flight tasks: %s\n' "$open_count" "${FM_SUP_IN_FLIGHT:-0}"

  if [ -f "$STATE/.github-down" ]; then
    flags="${flags}github-down (clones may be stale; first seen: $(head -n 1 "$STATE/.github-down" 2>/dev/null)); "
  fi
  if [ -f "$STATE/.guard-watcher-stale-banner" ]; then
    flags="${flags}watcher-down banner active ($(head -n 1 "$STATE/.guard-watcher-stale-banner" 2>/dev/null)); "
  fi
  [ -n "$flags" ] && printf 'flags: %s\n' "${flags%; }"

  fm_odometer_advice
  touch "$STATE/.last-anchor" 2>/dev/null || true
  return 0
}
