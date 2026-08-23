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
  # Pin a named channel so the EXEC seam is invoked on every platform.
  # `auto` is default-on only on macOS; on Linux it resolves to no OS
  # channel and would never reach the recorder (production: the durable
  # marker is then the only signal). osascript here is a channel name,
  # not a binary: EXEC replaces the real notifier.
  env "$@" \
    FM_HOME_OVERRIDE="$home" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_BEAT_ALARM_GRACE=$GRACE \
    FM_WEDGE_ALARM_CHANNEL=osascript \
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
  local dir agents fakebin
  dir=$(make_home consent)
  agents="$TMP_ROOT/launch-agents-consent"
  mkdir -p "$agents"
  # Consent is a Darwin-path gate (require_macos runs first). Fake Darwin so
  # Linux CI still reaches the consent refusal instead of the platform one.
  fakebin="$TMP_ROOT/fakebin-darwin"
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  chmod +x "$fakebin/uname"
  if PATH="$fakebin:$PATH" FM_HOME_OVERRIDE="$dir" LAUNCH_AGENTS_DIR="$agents" "$INSTALLER" install --yes-consent-only > "$dir/refuse.out" 2>&1; then
    fail "installer ran without a consent gate reachability check (invalid flag silently accepted)"
  fi
  # No tty + no --yes: the consent gate must refuse before touching launchd,
  # and the refuse path must leave no plist behind.
  if PATH="$fakebin:$PATH" FM_HOME_OVERRIDE="$dir" LAUNCH_AGENTS_DIR="$agents" "$INSTALLER" install < /dev/null > "$dir/noctty.out" 2>&1; then
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

# --- folded from the external-watchdog task ------------------------------------
#
# The grace this alert compares against must be the SAME value bin/fm-guard.sh
# uses. It previously hardcoded 300 with only a comment claiming alignment, so
# raising FM_GUARD_GRACE left this alert firing on the old threshold. These
# deliberately do NOT pin FM_BEAT_ALARM_GRACE, so the fallback chain is what
# decides.

# Like run_checker, but without the FM_BEAT_ALARM_GRACE pin.
run_checker_unpinned() {  # <home> [env...]
  local home=$1
  shift
  env "$@" \
    FM_HOME_OVERRIDE="$home" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$TMP_ROOT/rec" \
    FM_WEDGE_ALARM_LOG="$TMP_ROOT/rec.log" \
    "$CHECKER" --home "$home" 2>/dev/null
}

test_grace_follows_the_guard_knob() {
  local dir
  dir=$(make_home guard-grace)
  touch -t "$(backdate_ts 700)" "$dir/state/.last-watcher-beat"

  # 700s stale against grace 300 is past the 2x confirmation window: alerts.
  : > "$TMP_ROOT/rec.log"
  run_checker_unpinned "$dir" FM_GUARD_GRACE=300 || fail "guard-grace run failed"
  grep -F 'watcher beacon stale' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "700s stale under grace 300 did not alert"

  # The same beacon under a much larger guard grace is inside the window and
  # must stay silent. Before the fix this alerted anyway, on its own 300.
  rm -f "$dir/state/.beat-alarm-fired"
  : > "$TMP_ROOT/rec.log"
  run_checker_unpinned "$dir" FM_GUARD_GRACE=9999 || fail "wide-grace run failed"
  [ ! -s "$TMP_ROOT/rec.log" ] \
    || fail "FM_GUARD_GRACE=9999 still alerted, so the threshold has two owners: $(cat "$TMP_ROOT/rec.log")"
  pass "the alert threshold follows FM_GUARD_GRACE, so the guard and this alert cannot disagree"
}

test_grace_arrives_from_the_shared_knob_file() {
  local dir
  dir=$(make_home knob-file)
  touch -t "$(backdate_ts 700)" "$dir/state/.last-watcher-beat"

  # launchd and cron inherit no shell profile, so the file alone must decide.
  printf 'FM_GUARD_GRACE=9999\n' > "$dir/config/supervision.env"
  : > "$TMP_ROOT/rec.log"
  run_checker_unpinned "$dir" || fail "knob-file run failed"
  [ ! -s "$TMP_ROOT/rec.log" ] \
    || fail "config/supervision.env did not supply the grace: $(cat "$TMP_ROOT/rec.log")"

  # A real environment variable still outranks the file.
  rm -f "$dir/state/.beat-alarm-fired"
  : > "$TMP_ROOT/rec.log"
  run_checker_unpinned "$dir" FM_GUARD_GRACE=300 || fail "env-over-file run failed"
  grep -F 'watcher beacon stale' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "a real FM_GUARD_GRACE did not win over config/supervision.env"
  pass "grace resolves from config/supervision.env, and a real environment variable still wins"
}

test_rearm_is_opt_in_and_off_by_default() {
  local dir
  dir=$(make_home rearm-default)
  : > "$TMP_ROOT/rec.log"
  run_checker "$dir" || fail "default run failed"
  grep -F 'watcher beacon stale' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "the default run did not alert at all"
  grep -q 'rearm:' "$dir/state/.beat-alarm.log" 2>/dev/null \
    && fail "the default contract is alert-only, but it re-armed"
  grep -F 'did not start or stop anything' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "the default summary no longer states that nothing was started"
  pass "re-arming is off by default and the summary says nothing was started"
}

test_optin_rearm_runs_the_home_scoped_arm() {
  local dir arm_marker
  dir=$(make_home rearm-optin)
  arm_marker="$dir/arm-was-run"

  # Run the checker from a shim directory whose fm-watch-arm.sh records that it
  # was invoked and exits immediately. The real arm BLOCKS until its watcher
  # cycle closes, so invoking it here would leak a background watcher per run
  # and let those strays fight the singleton lock in other suites. The live
  # attach-not-double-arm proof belongs to docs/verification/supervision.md;
  # what this asserts is that opting in reaches the home-scoped arm at all and
  # that the captain-facing summary stops claiming nothing was started.
  local shim="$dir/shim"
  mkdir -p "$shim"
  cp "$CHECKER" "$shim/fm-watcher-beat-alarm.sh"
  for dep in fm-wedge-alarm-lib.sh fm-supervision-lib.sh fm-supervision-env-lib.sh \
    fm-classify-lib.sh fm-line-cap-lib.sh fm-timeout-lib.sh; do
    [ -f "$ROOT/bin/$dep" ] && cp "$ROOT/bin/$dep" "$shim/$dep"
  done
  cat > "$shim/fm-watch-arm.sh" <<ARM
#!/usr/bin/env bash
printf 'stub-arm invoked\n'
: > "$arm_marker"
exit 0
ARM
  chmod +x "$shim/fm-watch-arm.sh"

  : > "$TMP_ROOT/rec.log"
  env FM_BEAT_ALARM_REARM=1 \
    FM_HOME_OVERRIDE="$dir" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    FM_BEAT_ALARM_GRACE=$GRACE \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$TMP_ROOT/rec" \
    FM_WEDGE_ALARM_LOG="$TMP_ROOT/rec.log" \
    "$shim/fm-watcher-beat-alarm.sh" --home "$dir" 2>/dev/null \
    || fail "opt-in re-arm run failed"

  grep -q 'rearm:' "$dir/state/.beat-alarm.log" \
    || fail "FM_BEAT_ALARM_REARM=1 did not reach the re-arm path"
  # The arm is backgrounded, so give it a moment to record its own invocation.
  local i=0
  while [ "$i" -lt 50 ] && [ ! -e "$arm_marker" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$arm_marker" ] || fail "the opt-in did not actually invoke the home-scoped arm"
  grep -F 'did not start or stop anything' "$TMP_ROOT/rec.log" >/dev/null \
    && fail "the opt-in summary still claims nothing was started"
  grep -F 're-armed the watcher' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "the opt-in summary does not say the watcher was re-armed"
  pass "opting in invokes the home-scoped arm and the summary reflects it honestly"
}

test_optin_rearm_survives_caller_process_group_teardown() {
  local dir keep arm_pid_file checker_pgid_file shim arm_pid arm_pgid checker_pgid i
  dir=$(make_home rearm-detach)
  keep="$dir/keep-arm"
  arm_pid_file="$dir/arm.pid"
  checker_pgid_file="$dir/checker.pgid"
  touch "$keep"

  # Same shim as the opt-in reachability test: a stub arm, never the real
  # blocking watcher. This stub stays up while $keep exists so the caller can
  # tear down the checker's process group and observe whether the arm survived.
  shim="$dir/shim"
  mkdir -p "$shim"
  cp "$CHECKER" "$shim/fm-watcher-beat-alarm.sh"
  for dep in fm-wedge-alarm-lib.sh fm-supervision-lib.sh fm-supervision-env-lib.sh \
    fm-classify-lib.sh fm-line-cap-lib.sh fm-timeout-lib.sh; do
    [ -f "$ROOT/bin/$dep" ] && cp "$ROOT/bin/$dep" "$shim/$dep"
  done
  cat > "$shim/fm-watch-arm.sh" <<ARM
#!/usr/bin/env bash
printf '%s\\n' "\$\$" > "$arm_pid_file"
ps -o pgid= -p "\$\$" 2>/dev/null | tr -d '[:space:]' > "$dir/arm.pgid"
while [ -e "$keep" ]; do
  sleep 0.1
done
exit 0
ARM
  chmod +x "$shim/fm-watch-arm.sh"

  : > "$TMP_ROOT/rec.log"
  # Quotes are deliberate: the body is Perl, not shell.
  # shellcheck disable=SC2016
  env FM_BEAT_ALARM_REARM=1 \
    FM_HOME_OVERRIDE="$dir" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    FM_BEAT_ALARM_GRACE=$GRACE \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$TMP_ROOT/rec" \
    FM_WEDGE_ALARM_LOG="$TMP_ROOT/rec.log" \
    CHECKER_PGID_FILE="$checker_pgid_file" \
    perl -e '
      setpgrp(0, 0) or exit 125;
      if (open my $fh, ">", $ENV{CHECKER_PGID_FILE}) {
        print $fh $$;
        close $fh;
      }
      exec @ARGV;
      exit 125;
    ' "$shim/fm-watcher-beat-alarm.sh" --home "$dir" \
    || fail "detached opt-in re-arm run failed"

  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$arm_pid_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$arm_pid_file" ] || fail "the detached opt-in did not start the home-scoped arm"
  arm_pid=$(cat "$arm_pid_file")
  arm_pgid=$(cat "$dir/arm.pgid" 2>/dev/null || true)
  checker_pgid=$(cat "$checker_pgid_file" 2>/dev/null || true)
  case "$arm_pid" in ''|*[!0-9]*) fail "stub arm wrote no pid" ;; esac
  case "$checker_pgid" in ''|*[!0-9]*) fail "checker wrote no process group" ;; esac
  [ "$arm_pgid" != "$checker_pgid" ] \
    || fail "the arm stayed in the checker's process group ($checker_pgid)"
  kill -0 "$arm_pid" 2>/dev/null \
    || fail "the arm exited before the caller's group was torn down"

  # launchd's default job teardown: signal leftover members of the job's group.
  kill -TERM -- "-$checker_pgid" 2>/dev/null || true
  sleep 0.2
  kill -0 "$arm_pid" 2>/dev/null \
    || fail "tearing down the checker's process group killed the recovery arm"
  grep -F 're-armed the watcher' "$TMP_ROOT/rec.log" >/dev/null \
    || fail "a successfully detached re-arm did not say the watcher was re-armed"

  rm -f "$keep"
  kill -TERM -- "$arm_pid" 2>/dev/null || true
  pass "opt-in re-arm survives teardown of the checker's process group"
}

test_installer_prints_a_linux_cron_line() {
  local out
  out=$(FM_HOME_OVERRIDE="$TMP_ROOT" "$INSTALLER" crontab 2>&1) \
    || fail "crontab action failed: $out"
  case $out in
    *"fm-watcher-beat-alarm.sh"*) : ;;
    *) fail "the cron line does not invoke the checker: $out" ;;
  esac
  case $out in
    *"* * * *"*) : ;;
    *) fail "no cron schedule field in: $out" ;;
  esac
  # Sub-minute intervals have no cron expression and must clamp to one minute.
  out=$(FM_HOME_OVERRIDE="$TMP_ROOT" FM_BEAT_ALARM_INTERVAL=30 "$INSTALLER" crontab 2>&1) \
    || fail "sub-minute crontab action failed: $out"
  case $out in
    *"*/1 * * * *"*) : ;;
    *) fail "a 30s interval did not clamp to every minute: $out" ;;
  esac
  pass "the installer prints a usable Linux cron line and clamps sub-minute intervals"
}

test_stale_beat_alerts_once_per_episode
test_fresh_beat_stays_silent_and_rearms_next_episode
test_unsupervised_home_stays_silent
test_away_mode_defers_to_the_daemon_escalation_contract
test_second_confirmation_window_required
test_installer_rejects_non_macos_platforms
test_installer_refuses_without_consent
test_beat_marker_carries_the_alerted_beacon_mtime
test_grace_follows_the_guard_knob
test_grace_arrives_from_the_shared_knob_file
test_rearm_is_opt_in_and_off_by_default
test_optin_rearm_runs_the_home_scoped_arm
test_optin_rearm_survives_caller_process_group_teardown
test_installer_prints_a_linux_cron_line
