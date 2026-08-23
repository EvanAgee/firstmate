#!/usr/bin/env bash
# Captain-facing live demonstration of the watchdog-fold behaviors.
# Writes a transcript plus per-scenario recordings. Does not touch launchd,
# cron, or the real firstmate home.
set -u
ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0Q8AQDS86W3Z6DQ29C6WEF0"
EVID="/Users/evanagee/.no-mistakes/evidence/01M0Q8AQDS86W3Z6DQ29C6WEF0"
NEW="$ROOT/bin/fm-watcher-beat-alarm.sh"
INSTALLER="$ROOT/bin/fm-watcher-beat-alarm-install.sh"
LIB="$ROOT/bin/fm-supervision-env-lib.sh"
DEMO="$EVID/demo-home"
REC="$DEMO/rec"
LOG="$DEMO/rec.log"
OLD_SHIM="$DEMO/old-bin"
NEW_SHIM="$DEMO/new-bin"

rm -rf "$DEMO"
mkdir -p "$DEMO/state" "$DEMO/config" "$OLD_SHIM" "$NEW_SHIM"

backdate_ts() { date -v-"$1"S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "$1 seconds ago" '+%Y%m%d%H%M.%S'; }

# Supervised home + 700s-stale beacon (past 2x300, inside 2x9999).
printf 'window=firstmate:t\nkind=ship\n' > "$DEMO/state/task.meta"
printf 'working: x\n' > "$DEMO/state/task.status"
touch -t "$(backdate_ts 700)" "$DEMO/state/.last-watcher-beat"

cat > "$REC" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
exit 0
REC
chmod +x "$REC"

# Old checker from the pre-fold commit, with the then-current sibling libs.
git -C "$ROOT" show 8e4b9035e09757124275604ac26d03838c5949ac:bin/fm-watcher-beat-alarm.sh > "$OLD_SHIM/fm-watcher-beat-alarm.sh"
chmod +x "$OLD_SHIM/fm-watcher-beat-alarm.sh"
for dep in fm-wedge-alarm-lib.sh fm-supervision-lib.sh fm-classify-lib.sh fm-line-cap-lib.sh fm-timeout-lib.sh; do
  [ -f "$ROOT/bin/$dep" ] && cp "$ROOT/bin/$dep" "$OLD_SHIM/$dep"
done

# New checker + current libs, plus a stub arm that records invocation and exits.
cp "$NEW" "$NEW_SHIM/fm-watcher-beat-alarm.sh"
for dep in fm-wedge-alarm-lib.sh fm-supervision-lib.sh fm-supervision-env-lib.sh \
  fm-classify-lib.sh fm-line-cap-lib.sh fm-timeout-lib.sh; do
  [ -f "$ROOT/bin/$dep" ] && cp "$ROOT/bin/$dep" "$NEW_SHIM/$dep"
done
cat > "$NEW_SHIM/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf 'stub-arm invoked pid=%s\n' "$$"
exit 0
ARM
chmod +x "$NEW_SHIM/fm-watch-arm.sh"

run_old() {
  : > "$LOG"
  rm -f "$DEMO/state/.beat-alarm-fired"
  env "$@" \
    FM_HOME_OVERRIDE="$DEMO" \
    FM_CONFIG_OVERRIDE="$DEMO/config" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$REC" \
    FM_WEDGE_ALARM_LOG="$LOG" \
    "$OLD_SHIM/fm-watcher-beat-alarm.sh" --home "$DEMO" 2>/dev/null
}

run_new() {
  : > "$LOG"
  rm -f "$DEMO/state/.beat-alarm-fired" "$DEMO/state/.beat-alarm.log"
  env "$@" \
    FM_HOME_OVERRIDE="$DEMO" \
    FM_CONFIG_OVERRIDE="$DEMO/config" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$REC" \
    FM_WEDGE_ALARM_LOG="$LOG" \
    "$NEW_SHIM/fm-watcher-beat-alarm.sh" --home "$DEMO" 2>/dev/null
}

section() { printf '\n======== %s ========\n' "$1"; }
show_alert() {
  if [ -s "$LOG" ]; then
    printf 'ALERT FIRED:\n'
    cat "$LOG"
  else
    printf 'SILENT (no alert)\n'
  fi
}

section "1. Duplicate watchdog files are gone (only the five named paths)"
for p in bin/fm-watchdog.sh bin/fm-watchdog-install.sh docs/watchdog.md \
         docs/examples/watchdog-notify tests/fm-watchdog.test.sh; do
  if [ -e "$ROOT/$p" ]; then
    printf 'PRESENT  %s\n' "$p"
  else
    printf 'ABSENT   %s\n' "$p"
  fi
done
printf 'git diff vs base (deletions should be none; PR 14 never merged):\n'
git -C "$ROOT" diff --diff-filter=D --name-only 8e4b9035e09757124275604ac26d03838c5949ac HEAD

section "2. --help tracks the header through set -u (new knobs are visible)"
printf '--- checker --help (tail) ---\n'
"$NEW" --help | tail -n 20
printf '\n--- installer --help (tail) ---\n'
"$INSTALLER" --help | tail -n 12

section "3. Shared grace: 700s-stale beacon, file-only FM_GUARD_GRACE=9999"
printf 'FM_GUARD_GRACE=9999\n' > "$DEMO/config/supervision.env"
printf 'config/supervision.env:\n'
cat "$DEMO/config/supervision.env"
printf '\nPRE-CHANGE checker (GRACE=\${FM_BEAT_ALARM_GRACE:-300}, no file loader):\n'
run_old
show_alert
printf '\nCURRENT checker (defaults to FM_GUARD_GRACE from the parsed file):\n'
run_new
show_alert

section "4. Same beacon under FM_GUARD_GRACE=300 (env wins over file=9999)"
printf 'CURRENT checker with FM_GUARD_GRACE=300 in the environment:\n'
run_new FM_GUARD_GRACE=300
show_alert

section "5. Parse-not-source: malformed + executable-looking lines do not abort or run"
cat > "$DEMO/config/supervision.env" <<'ENV'
FM_GUARD_GRACE=9999
this line is garbage and would abort a sourced file
export FM_POLL=42
$(printf pwned > /Users/evanagee/.no-mistakes/evidence/01M0Q8AQDS86W3Z6DQ29C6WEF0/demo-home/pwned)
FM_HEARTBEAT=123
: ; touch /Users/evanagee/.no-mistakes/evidence/01M0Q8AQDS86W3Z6DQ29C6WEF0/demo-home/sourced
ENV
PWNED="$DEMO/pwned"
SOURCED="$DEMO/sourced"
rm -f "$PWNED" "$SOURCED"
# Load through the real public function.
unset FM_GUARD_GRACE FM_POLL FM_HEARTBEAT
# shellcheck disable=SC1091
. "$LIB"
fm_supervision_env_load "$DEMO/config"
printf 'resolved FM_GUARD_GRACE=%s (expect 9999; later knobs must still apply)\n' "${FM_GUARD_GRACE-}"
printf 'resolved FM_POLL=%s (expect 42; written AFTER the garbage line)\n' "${FM_POLL-}"
printf 'resolved FM_HEARTBEAT=%s (expect 123; written AFTER the command-looking lines)\n' "${FM_HEARTBEAT-}"
if [ -e "$PWNED" ] || [ -e "$SOURCED" ]; then
  printf 'FAIL: parser executed config file commands\n'
else
  printf 'OK: no pwned/sourced files created; config did not execute\n'
fi
printf 'CURRENT checker against that file (700s stale, grace 9999) must stay silent:\n'
unset FM_GUARD_GRACE FM_POLL FM_HEARTBEAT
run_new
show_alert

section "6. Default contract is alert-only; opt-in re-arm invokes the home-scoped arm"
printf 'FM_GUARD_GRACE=300\n' > "$DEMO/config/supervision.env"
printf 'DEFAULT (no FM_BEAT_ALARM_REARM):\n'
run_new
show_alert
if grep -q 'rearm:' "$DEMO/state/.beat-alarm.log" 2>/dev/null; then
  printf 'FAIL: default re-armed\n'
else
  printf 'OK: no rearm: line in the beat-alarm log\n'
fi
printf '\nOPT-IN FM_BEAT_ALARM_REARM=1:\n'
run_new FM_BEAT_ALARM_REARM=1
show_alert
# Arm is backgrounded; wait briefly.
i=0
while [ "$i" -lt 30 ] && ! grep -q 'rearm:' "$DEMO/state/.beat-alarm.log" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
printf 'beat-alarm.log:\n'
cat "$DEMO/state/.beat-alarm.log" 2>/dev/null || printf '(missing)\n'

section "7. Linux cron line + sub-minute clamp"
printf 'default interval:\n'
FM_HOME_OVERRIDE="$DEMO" "$INSTALLER" crontab
printf '\nFM_BEAT_ALARM_INTERVAL=30 (must clamp to */1):\n'
FM_HOME_OVERRIDE="$DEMO" FM_BEAT_ALARM_INTERVAL=30 "$INSTALLER" crontab
printf '\nFM_BEAT_ALARM_INTERVAL=180 (every 3 minutes):\n'
FM_HOME_OVERRIDE="$DEMO" FM_BEAT_ALARM_INTERVAL=180 "$INSTALLER" crontab

section "8. Installer still refuses to write launchd without consent"
LAUNCH_AGENTS_DIR="$DEMO/launch-agents"
mkdir -p "$LAUNCH_AGENTS_DIR"
if LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" FM_HOME_OVERRIDE="$DEMO" \
    "$INSTALLER" install < /dev/null > "$DEMO/noctty.out" 2>&1; then
  printf 'FAIL: install succeeded without consent\n'
else
  printf 'OK: install refused without consent\n'
fi
cat "$DEMO/noctty.out"
if [ -z "$(find "$LAUNCH_AGENTS_DIR" -name 'com.firstmate.watcher-beat-alarm*' 2>/dev/null)" ]; then
  printf 'OK: no plist written\n'
else
  printf 'FAIL: plist written despite refusal\n'
fi

section "9. config/supervision.env is gitignored via config/"
git -C "$ROOT" check-ignore -v config/supervision.env || printf 'NOT IGNORED\n'

printf '\n======== DEMO COMPLETE ========\n'
