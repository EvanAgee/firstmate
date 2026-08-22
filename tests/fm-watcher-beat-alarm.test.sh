#!/usr/bin/env bash
# Behavior tests for the session-independent watcher-beat alert
# (bin/fm-watcher-beat-alarm.sh, installed via the consent-guarded
# bin/fm-watcher-beat-alarm-install.sh; item 4 of fm-anti-drift-hardening).
#
# The alert face runs outside the agent session, so a completely dead session,
# a dead watcher, or a wedged supervision chain still alerts the captain. These
# tests drive the REAL checker and installer over crafted homes and assert
# their observable behavior (notifier seam recordings, marker state, refusals,
# exit statuses), never their source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Portable "N seconds ago" timestamp for touch -t (macOS date -v vs GNU -d).
backdate_ts() {  # <seconds>
  date -v-"$1"S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "$1 seconds ago" '+%Y%m%d%H%M.%S'
}

CHECKER="$ROOT/bin/fm-watcher-beat-alarm.sh"
INSTALLER="$ROOT/bin/fm-watcher-beat-alarm-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-beat-alarm-tests)
GRACE=8

make_home() {  # <name> -> dir; gives supervision need + a backdated beacon
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:t" "kind=ship"
  printf 'working: x\n' > "$dir/state/task.status"
  touch -t "$(backdate_ts 30)" "$dir/state/.last-watcher-beat"
  mkdir -p "$dir/rec"
  printf '%s' "$dir"
}

run_checker() {  # <home> [env...]
  local home=$1
  shift
  env "$@" \
    FM_HOME_OVERRIDE="$home" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_BEAT_ALARM_GRACE=$GRACE \
    FM_WEDGE_ALARM_EXEC="$TMP_ROOT/rec" \
    FM_WEDGE_ALARM_LOG="$TMP_ROOT/rec.log" \
    "$CHECKER" --home "$home" 2>/dev/null
}

# Notifier recorder (the wake-helpers recorder lives under wake-helpers.sh;
# these suites deliberately do not pull the whole wake stack, so a local seam
# keeps this assertion standalone).
cat > "$TMP_ROOT/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
exit 0
REC
chmod +x "$TMP_ROOT/rec"

test_stale_beat_alerts_once_per_episode() {
  local dir
  dir=$(make_home alert)
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir" || fail "checker refuses to run in a supervised home"
  grep -F 'watcher beacon stale' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "a 30s-stale beacon (grace 8) produced no alert"

  # Single-fire per episode: a second run of the same episode is silent.
  kill_wedge() { :; }
  run_checker "$dir" || fail "second checker run failed"
  [ "$(wc -l < "$TMP_ROOT/rec.log" | tr -d ' ')" = "1" ] \
    || fail "the same outage episode alerted more than once: $(cat "$TMP_ROOT/rec.log")"
  pass "a stale beacon alerts exactly once per outage episode"
}

test_fresh_beat_stays_silent_and_rearms_next_episode() {
  local dir
  dir=$(make_home fresh)
  touch "$dir/state/.last-watcher-beat"
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir" || fail "fresh-beat run failed"
  [ ! -s "$TMP_ROOT/rec.log" ] || fail "a fresh beacon still alerted: $(cat "$TMP_ROOT/rec.log")"

  # Recovery re-arms: episode 2 (a newly stale beat under a new mtime) alerts.
  : > "$TMP_ROOT/rec.log"
  touch -t "$(backdate_ts 30)" "$dir/state/.last-watcher-beat"
  run_checker "$dir"
  [ "$(wc -l < "$TMP_ROOT/rec.log" | tr -d ' ')" = "1" ] || fail "the first episode alerted"
  : > "$dir/state/.beat-alarm-fired"
  touch "$dir/state/.last-watcher-beat"
  run_checker "$dir"
  touch -t "$(backdate_ts 30)" "$dir/state/.last-watcher-beat"
  run_checker "$dir"
  [ "$(wc -l < "$TMP_ROOT/rec.log" | tr -d ' ')" = "2" ] \
    || fail "the re-armed next episode stayed silent: $(cat "$TMP_ROOT/rec.log")"
  pass "a fresh beacon stays silent, and recovery re-arms the next episode's single alert"
}

test_unsupervised_home_stays_silent() {
  local dir
  dir=$(make_home idle)
  rm -f "$dir/state/task.meta" "$dir/state/task.status"
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir" || fail "idle-home run failed"
  [ ! -s "$TMP_ROOT/rec.log" ] || fail "a home with no supervision need alerted"
  pass "a stale beacon with no supervision need stays silent"
}

test_away_mode_defers_to_the_daemon_escalation_contract() {
  local dir
  dir=$(make_home afk)
  touch "$dir/state/.afk"
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir"
  [ ! -s "$TMP_ROOT/rec.log" ] || fail "away mode still alerted through this face: $(cat "$TMP_ROOT/rec.log")"
  pass "the alert defers to away mode's own wedge alarm"
}

test_second_confirmation_window_required() {
  local dir
  dir=$(make_home window)
  # Between grace and 2*grace: the beacon is stale past one grace but the
  # second confirmation window has NOT elapsed, so this is a legitimate gap.
  touch -t "$(backdate_ts 12)" "$dir/state/.last-watcher-beat"
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir"
  [ ! -s "$TMP_ROOT/rec.log" ] || fail "a beacon inside the second confirmation window alerted: $(cat "$TMP_ROOT/rec.log")"
  pass "staleness inside the second confirmation window stays silent"
}

test_installer_rejects_non_macos_platforms() {
  local fakebin dir
  dir=$(make_home platform)
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  chmod +x "$fakebin/uname"
  if PATH="$fakebin:$PATH" FM_HOME_OVERRIDE="$dir" "$INSTALLER" install --yes > "$dir/platform.out" 2>&1; then
    fail "installer accepted a non-macOS platform"
  fi
  grep -iF 'macOS-only' "$dir/platform.out" >/dev/null \
    || fail "non-macOS refusal is missing its guidance: $(cat "$dir/platform.out")"
  pass "the installer refuses non-macOS platforms with guidance toward the documented contract"
}

test_installer_refuses_without_consent() {
  local dir agents
  dir=$(make_home consent)
  agents="$TMP_ROOT/launch-agents-consent"
  mkdir -p "$agents"
  if FM_HOME_OVERRIDE="$dir" LAUNCH_AGENTS_DIR="$agents" "$INSTALLER" install --yes-consent-only > "$dir/refuse.out" 2>&1; then
    fail "installer ran without a consent gate reachability check (invalid flag silently accepted)"
  fi
  # No tty + no --yes: the consent gate must refuse before touching launchd,
  # and the refuse path must leave no plist behind.
  if FM_HOME_OVERRIDE="$dir" LAUNCH_AGENTS_DIR="$agents" "$INSTALLER" install < /dev/null > "$dir/noctty.out" 2>&1; then
    fail "installer ran without consent on a non-tty and succeeded"
  fi
  grep -iF 'consent not given' "$dir/noctty.out" >/dev/null \
    || fail "non-tty install refused without naming the consent boundary: $(cat "$dir/noctty.out")"
  [ -z "$(find "$agents" -name 'com.firstmate.watcher-beat-alarm*' 2>/dev/null)" ] \
    || fail "a refused install still wrote a launch agent"
  pass "the installer refuses before touching launchd without explicit consent and leaves no plist"
}

beacon_mtime() {  # <file> -> epoch seconds; same Darwin/GNU split as fm_sup_stat_mtime
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

test_beat_marker_carries_the_alerted_beacon_mtime() {
  local dir
  dir=$(make_home marker)
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir"
  [ "$(cat "$dir/state/.beat-alarm-fired")" = "$(beacon_mtime "$dir/state/.last-watcher-beat")" ] \
    || fail "the fired marker does not carry its episode's beacon mtime"
  pass "the fired marker records the alerted episode's beacon mtime"
}

test_stale_beat_alerts_once_per_episode
test_fresh_beat_stays_silent_and_rearms_next_episode
test_unsupervised_home_stays_silent
test_away_mode_defers_to_the_daemon_escalation_contract
test_second_confirmation_window_required
test_installer_rejects_non_macos_platforms
test_installer_refuses_without_consent
test_beat_marker_carries_the_alerted_beacon_mtime
