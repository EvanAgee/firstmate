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
# Case 1 drives the REAL reap_task_backend_process_group by running
# bin/fm-teardown.sh with lsof removed from its search path, which is the only
# way that fallback is reached.
# The process actually endangered by the defect is the LIVE NEIGHBOUR pane,
# because the raw read resolves that pane's own pid and the kill then targets
# that pane's process group.
# So the case asserts that the neighbour pane process and its process group are
# both still alive after teardown returns, alongside the leader-resolution
# warning and the absence of the reap line.
# All four assertions fail against the raw read and pass after the fix.
#
# Cases 2 and 3 exercise only the shared read helper fm_tmux_display_message,
# not the kill path, and are kept as direct coverage of the live-window and
# dead-server reads that the fix must not break.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-gone-window-reap)

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-teardown-reap-$$"
SHIM_DIR=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  fm_test_cleanup
  return 0
}
trap cleanup_all EXIT

# A `tmux` shim so every bare `tmux ...` call - from the sourced library code
# here and from the real teardown script - goes to the private socket and never
# touches the host's real `firstmate` session.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-reap.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# Build an executable search path WITHOUT lsof, plus the tmux shim, regardless
# of where the host installs lsof. reap_task_backend_process_group is only
# reached on the lsof-absent fallback, so this is what makes the real function
# run at all.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  ln -sf "$SHIM_DIR/tmux" "$path_dir/tmux"
  printf '%s\n' "$path_dir"
}

# Build a teardown sandbox for one case, in the shape tests/fm-teardown.test.sh
# uses: a bare origin, a project clone, a task worktree, a state dir, and
# fakebin mocks for the post-check steps. Echoes the case dir.
make_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Record a task whose tmux window is the one this suite controls, and land its
# work so the landed-work safety check lets teardown proceed to the reap step.
write_meta() {  # <case-dir> <window>
  local case_dir=$1 window=$2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=$window" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

run_teardown() {  # <case-dir> <lsof-free-path> [args...]
  local case_dir=$1 path_without_lsof=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$path_without_lsof" \
    "$TEARDOWN" task-x1 "$@"
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -n fm-alive >/dev/null 2>&1 \
  || fail "could not start the private tmux server"
# Give the pane's shell a moment to exist.
sleep 1

ALIVE_PID=$(tmux display-message -p -t firstmate:fm-alive '#{pane_pid}' 2>/dev/null)
case "$ALIVE_PID" in
  ''|*[!0-9]*) fail "could not read the live window's pane pid" ;;
esac

# --- 1. The real reap path, with the task's window GONE ---------------------
#
# The live `fm-alive` window is the neighbour whose pid a raw display-message
# would hand back for the absent `fm-task-x1` window.

CASE=$(make_case gone-window) || fail "could not build the teardown sandbox"
write_meta "$CASE" 'firstmate:fm-task-x1'
PATH_NO_LSOF=$(make_path_without_lsof "$CASE")
PATH="$PATH_NO_LSOF" command -v lsof >/dev/null 2>&1 \
  && fail "gone-window: fixture path unexpectedly exposes lsof"

ALIVE_PGID=$(ps -o pgid= -p "$ALIVE_PID" 2>/dev/null | tr -d '[:space:]')
case "$ALIVE_PGID" in
  ''|*[!0-9]*) fail "gone-window: could not read the live neighbour's process group" ;;
esac

RC=0
run_teardown "$CASE" "$PATH_NO_LSOF" > "$CASE/stdout" 2> "$CASE/stderr" || RC=$?

grep -Fq 'cannot resolve the tmux pane leader' "$CASE/stderr" \
  || fail "gone-window: teardown did not take the leader-resolution early return (rc=$RC); stderr: $(cat "$CASE/stderr")"
pass "a gone tmux window resolves no pane leader and takes the early return"

grep -Fq 'reaping leaked worktree process group' "$CASE/stderr" \
  && fail "gone-window: teardown reached the kill path against a gone window"
pass "teardown never reports reaping a process group for a gone window"

kill -0 "$ALIVE_PID" 2>/dev/null \
  || fail "gone-window: the live neighbour pane process $ALIVE_PID was killed; the raw display-message read resolves exactly this pid for the absent window"
pass "the live neighbour pane process survives teardown untouched"

kill -0 -- "-$ALIVE_PGID" 2>/dev/null \
  || fail "gone-window: the live neighbour pane's process group $ALIVE_PGID was killed; that is the group the raw read's kill -TERM would signal"
pass "the live neighbour pane's process group survives teardown untouched"

# --- 2. The live window still reads its own pane leader ---------------------
#
# This asserts only on the shared read helper, not on the kill path; it guards
# the fix against blinding the legitimate reap.
LIVE_LEADER=$(fm_tmux_display_message 'firstmate:fm-alive' '#{pane_pid}')
[ "$LIVE_LEADER" = "$ALIVE_PID" ] \
  || fail "live window read back '$LIVE_LEADER', expected '$ALIVE_PID'"
pass "a live tmux window still resolves its own pane leader (read helper only)"

# --- 3. A dead server resolves no leader ------------------------------------
#
# Also read-helper-only coverage.
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
DEAD_LEADER=$(fm_tmux_display_message 'firstmate:fm-alive' '#{pane_pid}')
[ -z "$DEAD_LEADER" ] \
  || fail "dead server resolved leader '$DEAD_LEADER', expected empty"
pass "a dead tmux server resolves no pane leader (read helper only)"

cleanup_all
echo "# fm-teardown-gone-window-reap: all checks passed"
