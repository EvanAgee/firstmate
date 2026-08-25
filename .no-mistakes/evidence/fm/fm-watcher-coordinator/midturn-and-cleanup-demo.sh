#!/usr/bin/env bash
# Evidence-only demo (not a repo test): prove a live watcher owns the lock with a
# fresh beacon across a handling turn longer than grace, then prove live-e2e
# cleanup signals the recorded watcher pid before the lab is deleted.
set -u
ROOT="$(cd "$(dirname "$0")/../../worktrees/b99440365b40/01M0V4KW7KS71DMYA2X9J7WNCX" && pwd)"
COORDINATOR="$ROOT/bin/fm-claude-watch-coordinator.sh"
OUT="$(cd "$(dirname "$0")" && pwd)/midturn-and-cleanup-transcript.txt"
: > "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT"; }

fail() {
  log "FAIL: $1"
  stop_bg "$COORD_PID" "$HOLDER_PID"
  kill "$CLEAN_WATCH" 2>/dev/null || true
  rm -rf "$TMP"
  exit 1
}

stop_bg() {
  local p
  for p in "$@"; do
    [ -n "${p:-}" ] || continue
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
}

beacon_age() {
  local m now
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$1/state/.last-watcher-beat" 2>/dev/null || echo 0)
  else
    m=$(stat -c %Y "$1/state/.last-watcher-beat" 2>/dev/null || echo 0)
  fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  now=$(date +%s)
  echo $(( now - m ))
}

watch_pid() { cat "$1/state/.watch.lock/pid" 2>/dev/null || true; }

wait_file() {
  local path=$1 limit=${2:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-coord-evidence.XXXXXX")
DIR="$TMP/long-turn"
FAKEBIN="$DIR/fakebin"
mkdir -p "$DIR/state" "$FAKEBIN"
git init -q "$DIR"
git -C "$DIR" commit -q --allow-empty -m init
: > "$DIR/AGENTS.md"
cp -R "$ROOT/bin" "$DIR/bin"
ln -s /bin/bash "$FAKEBIN/claude"
cat > "$FAKEBIN/fm-crew-state.sh" <<'CS'
#!/usr/bin/env bash
printf 'state: unknown · source: none · fake\n'
exit 0
CS
chmod +x "$FAKEBIN/fm-crew-state.sh"

export FM_ROOT_OVERRIDE="$DIR" FM_HOME="$DIR" FM_STATE_OVERRIDE="$DIR/state" FM_CONFIG_OVERRIDE="$DIR/config"
export PATH="$FAKEBIN:$PATH" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh"

HOLDER_PID= COORD_PID= CLEAN_WATCH=
mkdir -p "$DIR/state/session-jobs"
"$FAKEBIN/claude" -c '
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
wait_file "$DIR/state/.lock" 50 || fail "session never wrote the lock"

printf 'window=x\n' > "$DIR/state/task.meta"
printf 'working: go\n' > "$DIR/state/task.status"
# Prime seen so the first status line is not an immediate wake.
FM_STATE_OVERRIDE="$DIR/state" bash -c '
  . "$1"
  sig=$(fm_wake_signal_sig "$3") || exit 1
  printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
' _ "$ROOT/bin/fm-wake-lib.sh" "$DIR/state" "$DIR/state/task.status"

printf '%s\n' 'exec env FM_GUARD_GRACE=6 FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "'"$COORDINATOR"'" </dev/null >"'"$DIR"'/coord.out" 2>&1' \
  > "$DIR/state/session-jobs/run-coord.sh.tmp"
mv "$DIR/state/session-jobs/run-coord.sh.tmp" "$DIR/state/session-jobs/run-coord.sh"
wait_file "$DIR/state/session-jobs/coord.pid" 50 || fail "session never started the coordinator"
COORD_PID=$(cat "$DIR/state/session-jobs/coord.pid")

wait_file "$DIR/state/.watch.lock/pid" 400 || fail "coordinator never established a watcher: $(cat "$DIR/coord.out" 2>/dev/null)"
sleep 2
first=$(watch_pid "$DIR")
log "=== mid-turn live-watcher sample (grace=6s, sample window=10s) ==="
log "session_lock=$(cat "$DIR/state/.lock")"
log "coordinator_pid=$COORD_PID first_watch_pid=$first"
log "ready_record:"
sed 's/^/  /' "$DIR/state/.claude-ready-to-notify" 2>/dev/null | tee -a "$OUT" >/dev/null || true

stale=0
for t in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  wp=$(watch_pid "$DIR")
  alive=no
  kill -0 "$wp" 2>/dev/null && alive=yes
  age=$(beacon_age "$DIR")
  log "t=${t}s watcher_pid=$wp alive=$alive beacon_age=${age}s"
  [ "$alive" = yes ] || fail "no live watcher at t=${t}s"
  [ "$age" -lt 6 ] || { stale=1; fail "beacon stale (${age}s >= 6s) at t=${t}s"; }
done
last=$(watch_pid "$DIR")
log "last_watch_pid=$last"
[ "$first" = "$last" ] || fail "quiet fleet churned watchers ($first -> $last)"
log "PASS: live watcher $first owned the lock with a fresh beacon for 10s > 6s grace"

# Reap the real components before the cleanup demo so we do not leak them.
wpid=$(watch_pid "$DIR")
stop_bg "$COORD_PID" "$HOLDER_PID"
kill "$wpid" 2>/dev/null || true

log ""
log "=== live-e2e cleanup signals recorded watcher pid ==="
LAB="$TMP/lab"
HOME_DIR="$LAB/fmhome"
mkdir -p "$HOME_DIR/state/.watch.lock"
# A dummy watcher that would outlive a lab rm -rf if not signalled.
sleep 60 &
CLEAN_WATCH=$!
printf '%s\n' "$CLEAN_WATCH" > "$HOME_DIR/state/.watch.lock/pid"
log "dummy_watcher_pid=$CLEAN_WATCH (alive before cleanup)"
kill -0 "$CLEAN_WATCH" 2>/dev/null || fail "dummy watcher died before cleanup"

# Same sequence as tests/fm-claude-watch-coordinator-live-e2e.test.sh cleanup().
wpid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
case "$wpid" in
  '' | *[!0-9]*) : ;;
  *) kill "$wpid" 2>/dev/null || true ;;
esac
rm -rf "$LAB"

if kill -0 "$CLEAN_WATCH" 2>/dev/null; then
  kill "$CLEAN_WATCH" 2>/dev/null || true
  fail "cleanup removed the lab but left the recorded watcher pid $CLEAN_WATCH alive"
fi
log "PASS: recorded pid $CLEAN_WATCH was signalled and is gone; lab deleted"
[ ! -e "$LAB" ] || fail "lab directory still exists"

rm -rf "$TMP"
log ""
log "ALL EVIDENCE CHECKS PASSED"
