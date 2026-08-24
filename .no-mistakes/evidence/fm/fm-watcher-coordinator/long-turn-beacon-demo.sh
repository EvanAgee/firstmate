#!/usr/bin/env bash
# Evidence-only harness (not a repo test): drive the REAL Claude coordinator
# + REAL fm-watch-arm.sh / fm-watch.sh against a temp home, then sample the
# live watcher and fm-guard.sh across a handling turn longer than grace.
# This is the operator-visible contract: no "WATCHER DOWN" while the turn
# is still running past the 6s grace window.
set -u
ROOT=${1:?usage: long-turn-beacon-demo.sh <repo-root> <out-dir>}
OUT=${2:?usage: long-turn-beacon-demo.sh <repo-root> <out-dir>}
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"
COORDINATOR="$ROOT/bin/fm-claude-watch-coordinator.sh"
GRACE=6
TURN_SECS=10
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=$GRACE

TMP_ROOT=$(fm_test_tmproot fm-claude-coord-evidence)
fm_git_identity fmtest fmtest@example.invalid
mkdir -p "$OUT"

dir="$TMP_ROOT/long-turn-evidence"
fakebin="$dir/fakebin"
mkdir -p "$dir/state" "$fakebin"
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

# Session-owning fake Claude so identity gates pass.
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
wait_file "$dir/state/.lock" 50 || { kill "$HOLDER_PID" 2>/dev/null; echo "FAIL: session lock never written" >&2; exit 1; }

printf 'window=x\n' > "$dir/state/task.meta"
printf 'working: handling a long turn\n' > "$dir/state/task.status"
# Prime the seen marker so the watcher stays quiet and beats steadily.
FM_STATE_OVERRIDE="$dir/state" bash -c '
  . "$1"
  sig=$(fm_wake_signal_sig "$3") || exit 1
  printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state" "$dir/state/task.status"

printf '%s\n' '
  exec env FM_GUARD_GRACE=6 FM_CLAUDE_COORD_READY_TIMEOUT=15 \
    bash "'"$COORDINATOR"'" </dev/null >"'"$dir"'/coord.out" 2>&1
' > "$dir/state/session-jobs/run-coord.sh.tmp"
mv "$dir/state/session-jobs/run-coord.sh.tmp" "$dir/state/session-jobs/run-coord.sh"
wait_file "$dir/state/session-jobs/coord.pid" 50 || { kill "$HOLDER_PID" 2>/dev/null; echo "FAIL: coordinator never started" >&2; exit 1; }
COORD_PID=$(cat "$dir/state/session-jobs/coord.pid")

wait_file "$dir/state/.watch.lock/pid" 400 || {
  kill "$COORD_PID" "$HOLDER_PID" 2>/dev/null
  echo "FAIL: no live watcher" >&2
  cat "$dir/coord.out" >&2 || true
  exit 1
}
sleep 2
first=$(cat "$dir/state/.watch.lock/pid")

TIMELINE="$OUT/long-turn-beacon-timeline.log"
{
  echo "# Claude coordinator long-turn evidence"
  echo "# grace=${GRACE}s  sampled_turn=${TURN_SECS}s  first_watcher=$first"
  echo "# columns: t_s watcher_pid watcher_alive beacon_age_s age_lt_grace ready_seq successor_pid guard_watcher_down"
} > "$TIMELINE"

alarms=0
stale=0
dead=0
t=0
while [ "$t" -le "$TURN_SECS" ]; do
  wp=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  alive=no
  kill -0 "$wp" 2>/dev/null && alive=yes
  age=$(beacon_age)
  age_ok=no
  [ "$age" -lt "$GRACE" ] && age_ok=yes
  rs=$(sed -n 's/^ready_seq=//p' "$dir/state/.claude-ready-to-notify" 2>/dev/null | head -1)
  sp=$(sed -n 's/^successor_watch_pid=//p' "$dir/state/.claude-ready-to-notify" 2>/dev/null | head -1)
  # Sample fm-guard the way a Claude Stop/tool child would see it: CLAUDECODE=1
  # plus autoarm. This agent harness is Pi, and without the override fm-guard
  # would apply Pi's extension identity rules to a Claude watcher.
  guard_out=$(
    env $(home_env) PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      CLAUDECODE=1 PI_CODING_AGENT= FM_SUPERVISION_MODEL=autoarm FM_GUARD_GRACE="$GRACE" \
      bash "$dir/bin/fm-guard.sh" 2>&1 || true
  )
  down=no
  printf '%s' "$guard_out" | grep -q 'WATCHER DOWN' && down=yes
  printf 't=%02ds pid=%s alive=%s beacon_age=%ss under_grace=%s ready_seq=%s successor=%s watcher_down=%s\n' \
    "$t" "${wp:-none}" "$alive" "$age" "$age_ok" "${rs:-none}" "${sp:-none}" "$down" >> "$TIMELINE"
  [ "$alive" = yes ] || dead=$((dead + 1))
  [ "$age_ok" = yes ] || stale=$((stale + 1))
  [ "$down" = no ] || alarms=$((alarms + 1))
  if [ "$t" -eq 0 ]; then
    printf '%s\n' "$guard_out" > "$OUT/fm-guard-at-t0.txt"
  fi
  if [ "$t" -eq "$TURN_SECS" ]; then
    printf '%s\n' "$guard_out" > "$OUT/fm-guard-at-t${TURN_SECS}.txt"
  fi
  t=$((t + 1))
  [ "$t" -le "$TURN_SECS" ] && sleep 1
done

last=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
{
  echo
  echo "# ready-to-notify record at end of turn"
  cat "$dir/state/.claude-ready-to-notify" 2>/dev/null || echo "(missing)"
  echo
  echo "# coordinator lock"
  echo "role=$(cat "$dir/state/.claude-coordinator.lock/role" 2>/dev/null || echo missing)"
  echo "coord_pid=$(cat "$dir/state/.claude-coordinator.lock/pid" 2>/dev/null || echo missing)"
  echo "session_owner=$(cat "$dir/state/.lock" 2>/dev/null || echo missing)"
  echo
  echo "# summary first_watcher=$first last_watcher=$last dead_samples=$dead stale_samples=$stale watcher_down_alarms=$alarms"
} >> "$TIMELINE"

cp "$dir/state/.claude-ready-to-notify" "$OUT/ready-to-notify.txt" 2>/dev/null || true
cp "$dir/coord.out" "$OUT/coordinator.out" 2>/dev/null || true

kill "$COORD_PID" "$HOLDER_PID" 2>/dev/null || true
wait "$COORD_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

if [ "$dead" -eq 0 ] && [ "$stale" -eq 0 ] && [ "$alarms" -eq 0 ] && [ "$first" = "$last" ]; then
  echo "PASS: one live watcher (pid $first) kept the beacon under ${GRACE}s for ${TURN_SECS}s; fm-guard never printed WATCHER DOWN"
  exit 0
fi
echo "FAIL: dead=$dead stale=$stale alarms=$alarms first=$first last=$last" >&2
exit 1
