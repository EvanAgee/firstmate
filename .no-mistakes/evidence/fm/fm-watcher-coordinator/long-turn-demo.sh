#!/usr/bin/env bash
# Manual evidence demo of the Claude successor-first watcher fix.
# Uses the same real arm/watch/queue stack as tests/fm-claude-watch-coordinator.test.sh,
# but records the operator-visible surfaces: beacon age, live lock owner, ready
# record, fm-guard.sh, and fm-turnend-guard.sh --claude across a turn longer than grace.
set -eu
ROOT="${FM_DEMO_ROOT:-$(pwd)}"
EVID="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$EVID/long-turn-timeline.txt"
STATE_SNAP="$EVID/long-turn-state"
rm -rf "$STATE_SNAP"
mkdir -p "$STATE_SNAP"

. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-watch-long-turn-demo)
fm_git_identity fmtest fmtest@example.invalid
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=6

dir="$TMP_ROOT/long-turn-demo"
fakebin="$dir/fakebin"
mkdir -p "$dir/state" "$fakebin" "$dir/config"
git init -q "$dir"
git -C "$dir" commit -q --allow-empty -m init
: > "$dir/AGENTS.md"
cp -R "$ROOT/bin" "$dir/bin"
ln -s /bin/bash "$fakebin/claude"
cat > "$fakebin/fm-crew-state.sh" <<'CS'
#!/usr/bin/env bash
printf 'state: unknown · source: none · fake\n'
exit 0
CS
chmod +x "$fakebin/fm-crew-state.sh"

home_env() {
  printf 'FM_ROOT_OVERRIDE=%s FM_HOME=%s FM_STATE_OVERRIDE=%s FM_CONFIG_OVERRIDE=%s\n' \
    "$dir" "$dir" "$dir/state" "$dir/config"
}

wait_file() {
  local path=$1 limit=${2:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

beacon_age() {
  local m now
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$dir/state/.last-watcher-beat" 2>/dev/null || echo 0)
  else
    m=$(stat -c %Y "$dir/state/.last-watcher-beat" 2>/dev/null || echo 0)
  fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  now=$(date +%s)
  echo $(( now - m ))
}

mkdir -p "$dir/state/session-jobs"
# shellcheck disable=SC2046
env $(home_env) PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  "$fakebin/claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    while :; do
      for f in "$FM_HOME/state/session-jobs"/run-*.sh; do
        [ -f "$f" ] || continue
        id=${f##*/run-}
        id=${id%.sh}
        started="$FM_HOME/state/session-jobs/$id.started"
        mv "$f" "$started" || continue
        bash "$started" >"$FM_HOME/state/session-jobs/$id.out" 2>"$FM_HOME/state/session-jobs/$id.err" &
        printf "%s\n" "$!" > "$FM_HOME/state/session-jobs/$id.pid"
      done
      sleep 0.05
    done
  ' </dev/null &
HOLDER_PID=$!
wait_file "$dir/state/.lock" 50

printf 'window=x\n' > "$dir/state/task.meta"
printf 'working: go\n' > "$dir/state/task.status"
FM_STATE_OVERRIDE="$dir/state" bash -c '
  . "$1"
  sig=$(fm_wake_signal_sig "$3") || exit 1
  printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state" "$dir/state/task.status"

# Drive the COPIED coordinator so the armed watcher path matches this home's bin/.
printf '%s\n' "
  exec env FM_GUARD_GRACE=6 FM_CLAUDE_COORD_READY_TIMEOUT=15 \\
    bash \"$dir/bin/fm-claude-watch-coordinator.sh\" </dev/null >\"$dir/coord.out\" 2>&1
" > "$dir/state/session-jobs/run-coord.sh.tmp"
mv "$dir/state/session-jobs/run-coord.sh.tmp" "$dir/state/session-jobs/run-coord.sh"
wait_file "$dir/state/session-jobs/coord.pid" 50
coord=$(cat "$dir/state/session-jobs/coord.pid")

wait_file "$dir/state/.watch.lock/pid" 400
wait_file "$dir/state/.claude-ready-to-notify" 400
sleep 1

{
  echo "long-turn demo: grace=6s, sample window=10s"
  echo "real components: $dir/bin/fm-watch-arm.sh + fm-watch.sh + fm-guard.sh + fm-turnend-guard.sh --claude"
  echo "home=$dir"
  echo "session_owner=$(cat "$dir/state/.lock")"
  echo "coordinator_pid=$coord"
  echo "watch.lock.pid=$(cat "$dir/state/.watch.lock/pid")"
  echo "watch.lock.path=$(cat "$dir/state/.watch.lock/watcher-path" 2>/dev/null || true)"
  echo "watch.lock.home=$(cat "$dir/state/.watch.lock/fm-home" 2>/dev/null || true)"
  echo
  echo "=== ready-to-notify ==="
  cat "$dir/state/.claude-ready-to-notify"
  echo
  echo "t_s	watch_pid	watch_alive	beacon_age	ready_seq	successor_pid	guard	turnend"
} > "$OUT"

banner_hits=0
stale_hits=0
dead_hits=0
turnend_blocks=0
first_wp=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)

for t in 0 1 2 3 4 5 6 7 8 9 10; do
  wp=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  alive=no
  if [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null; then alive=yes; else dead_hits=$((dead_hits+1)); fi
  age=$(beacon_age)
  [ "$age" -lt 6 ] || stale_hits=$((stale_hits+1))
  rs=$(sed -n 's/^ready_seq=//p' "$dir/state/.claude-ready-to-notify" 2>/dev/null | head -1)
  sp=$(sed -n 's/^successor_watch_pid=//p' "$dir/state/.claude-ready-to-notify" 2>/dev/null | head -1)

  # Pull-guard as a child of the lock-holding Claude, matching mid-turn tool use.
  printf '%s\n' "
    env FM_GUARD_GRACE=6 FM_SUPERVISION_MODEL=autoarm \\
      bash \"$dir/bin/fm-guard.sh\" >\"$dir/state/guard-$t.out\" 2>\"$dir/state/guard-$t.err\"
    printf '%s\\n' \"\$?\" > \"$dir/state/guard-$t.rc\"
  " > "$dir/state/session-jobs/run-g$t.sh.tmp"
  mv "$dir/state/session-jobs/run-g$t.sh.tmp" "$dir/state/session-jobs/run-g$t.sh"
  wait_file "$dir/state/guard-$t.rc" 50 || true
  gerr=$(cat "$dir/state/guard-$t.err" 2>/dev/null || true)
  if printf '%s' "$gerr" | grep -q 'WATCHER DOWN'; then
    banner=WATCHER_DOWN
    banner_hits=$((banner_hits+1))
  elif printf '%s' "$gerr" | grep -q 'watcher still down'; then
    banner=STILL_DOWN
    banner_hits=$((banner_hits+1))
  elif [ -n "$gerr" ]; then
    banner=OTHER
    printf '%s\n' "$gerr" > "$STATE_SNAP/guard-$t.err"
  else
    banner=silent
  fi

  # Turn-end guard as a child of the same Claude session.
  printf '%s\n' "
    printf '%s\\n' '{\"session_id\":\"demo\",\"stop_hook_active\":false}' \\
      | env FM_GUARD_GRACE=6 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=300 \\
        bash \"$dir/bin/fm-turnend-guard.sh\" --claude >\"$dir/state/te-$t.out\" 2>\"$dir/state/te-$t.err\"
    printf '%s\\n' \"\$?\" > \"$dir/state/te-$t.rc\"
  " > "$dir/state/session-jobs/run-te$t.sh.tmp"
  mv "$dir/state/session-jobs/run-te$t.sh.tmp" "$dir/state/session-jobs/run-te$t.sh"
  wait_file "$dir/state/te-$t.rc" 50 || true
  terc=$(cat "$dir/state/te-$t.rc" 2>/dev/null || echo missing)
  teout=$(cat "$dir/state/te-$t.out" "$dir/state/te-$t.err" 2>/dev/null || true)
  if printf '%s' "$teout" | grep -q 'SUPERVISION IS OFF'; then
    te=BLOCK
    turnend_blocks=$((turnend_blocks+1))
    printf '%s\n' "$teout" > "$STATE_SNAP/turnend-$t.out"
  else
    te="allow:$terc"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$wp" "$alive" "$age" "$rs" "$sp" "$banner" "$te" >> "$OUT"
  [ "$t" -eq 10 ] || sleep 1
done

last_wp=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
cp "$dir/state/.claude-ready-to-notify" "$STATE_SNAP/ready-to-notify"
cp "$dir/state/.watch.lock/pid" "$STATE_SNAP/watch.lock.pid"
cp "$dir/state/.watch.lock/watcher-path" "$STATE_SNAP/watch.lock.path" 2>/dev/null || true
cp "$dir/state/.watch.lock/fm-home" "$STATE_SNAP/watch.lock.home" 2>/dev/null || true
cp "$dir/state/.watch.lock/role" "$STATE_SNAP/watch.lock.role" 2>/dev/null || true
cp "$dir/coord.out" "$STATE_SNAP/coordinator.log"
ls -la "$dir/state" > "$STATE_SNAP/state-listing.txt"
# Keep one representative silent guard + allow turnend sample.
cp "$dir/state/guard-5.err" "$STATE_SNAP/guard-t5.err" 2>/dev/null || true
cp "$dir/state/te-5.out" "$STATE_SNAP/turnend-t5.out" 2>/dev/null || true
cp "$dir/state/te-5.rc" "$STATE_SNAP/turnend-t5.rc" 2>/dev/null || true

{
  echo
  echo "summary: first_watch=$first_wp last_watch=$last_wp dead_samples=$dead_hits stale_samples=$stale_hits watcher_down_banners=$banner_hits turnend_blocks=$turnend_blocks"
  if [ "$first_wp" = "$last_wp" ] && [ "$dead_hits" -eq 0 ] && [ "$stale_hits" -eq 0 ] && [ "$banner_hits" -eq 0 ] && [ "$turnend_blocks" -eq 0 ]; then
    echo "RESULT: PASS — one live watcher kept the beacon fresh across 10s (> 6s grace); fm-guard.sh stayed silent; turn-end guard did not raise SUPERVISION IS OFF"
  else
    echo "RESULT: FAIL — supervision gap or false alarm observed during the long turn"
  fi
} >> "$OUT"

kill "$coord" "$HOLDER_PID" 2>/dev/null || true
wait "$coord" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
if [ -n "$last_wp" ]; then kill "$last_wp" 2>/dev/null || true; fi
cat "$OUT"
