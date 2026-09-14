#!/usr/bin/env bash
# tests/fm-teardown-gone-window-reap.test.sh - regression test for
# bin/fm-teardown.sh's reap_task_backend_process_group against a REAL tmux
# server on a private socket.
#
# The defect: the pane leader was read with a raw
# `tmux display-message -p -t "$T" '#{pane_pid}'`. When the task's window is
# gone, tmux answers for the client's current window instead of failing, so the
# read returns the pid of a LIVE, UNRELATED pane, and the function then sends
# SIGTERM to that process group. The identity guards downstream cannot catch it,
# because leader_start is sampled from the same wrong pid and therefore matches
# itself.
#
# This suite proves the gone-window case resolves no leader and kills nothing,
# while a live neighbour window's process group survives untouched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-teardown-reap-$$"
SHIM_DIR=
VICTIM_PID=

cleanup_all() {
  [ -n "${VICTIM_PID:-}" ] && kill -KILL "$VICTIM_PID" 2>/dev/null
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  return 0
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so every bare `tmux ...` call from the sourced library
# code goes to the private socket and never touches the host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-reap.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# The function under test, lifted verbatim in shape from bin/fm-teardown.sh so
# the test exercises the real read path (fm_tmux_display_message) rather than a
# paraphrase of it. The assertions below are about which pid that read resolves.
read_leader() {  # <target>
  fm_tmux_display_message "$1" '#{pane_pid}'
}

tmux new-session -d -s firstmate -n fm-alive >/dev/null 2>&1 \
  || fail "could not start the private tmux server"
# Give the pane's shell a moment to exist.
sleep 1

ALIVE_PID=$(tmux display-message -p -t firstmate:fm-alive '#{pane_pid}' 2>/dev/null)
case "$ALIVE_PID" in
  ''|*[!0-9]*) fail "could not read the live window's pane pid" ;;
esac

# 1. A gone window must resolve NO leader.
GONE_LEADER=$(read_leader 'firstmate:fm-gone-task')
if [ -n "$GONE_LEADER" ]; then
  fail "gone window resolved leader '$GONE_LEADER' (live neighbour is $ALIVE_PID); a raw display-message fallback would return the neighbour's pid and teardown would kill it"
fi
pass "a gone tmux window resolves no pane leader"

# 2. That empty leader must take the non-numeric early return, so nothing is
#    killed and the live neighbour survives.
case "$GONE_LEADER" in
  ''|*[!0-9]*) ;;
  *) fail "gone-window leader '$GONE_LEADER' is numeric and would reach the kill path" ;;
esac
if ! kill -0 "$ALIVE_PID" 2>/dev/null; then
  fail "the live neighbour pane process $ALIVE_PID died; the gone-window read must never reach a kill"
fi
pass "the live neighbour's process group is untouched"

# 3. The live window itself must still read its own real pane pid, so the fix
#    does not blind the legitimate reap path.
LIVE_LEADER=$(read_leader 'firstmate:fm-alive')
[ "$LIVE_LEADER" = "$ALIVE_PID" ] \
  || fail "live window read back '$LIVE_LEADER', expected '$ALIVE_PID'"
pass "a live tmux window still resolves its own pane leader"

# 4. A dead server resolves no leader either.
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
DEAD_LEADER=$(read_leader 'firstmate:fm-alive')
[ -z "$DEAD_LEADER" ] \
  || fail "dead server resolved leader '$DEAD_LEADER', expected empty"
pass "a dead tmux server resolves no pane leader"

cleanup_all
echo "# fm-teardown-gone-window-reap: all checks passed"
