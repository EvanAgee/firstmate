#!/usr/bin/env bash
# Operator-facing transcript of the herdr husk relaunch fix.
# Not a repo test: writes only to this evidence directory.
set -u
ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0JQK5NH56RJ2Z38N95G84RP"
EVID="/Users/evanagee/.no-mistakes/evidence/01M0JQK5NH56RJ2Z38N95G84RP"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(fm_test_tmproot husk-relaunch-demo)
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0

# Minimal copies of the herdr test fixtures used by the new classifier cases.
make_herdr_fakebin() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ] && [ "${FM_HERDR_SCRIPT_STATUS:-0}" != 1 ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

make_death_lab() {
  local dir=$1 pid=$2
  mkdir -p "$dir"
  cat > "$dir/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  "-axo pid=,ppid=") printf '1 0\n$pid 1\n' ;;
  "-p $pid -o stat=") printf 'Ss+\n' ;;
  "-p $pid -o comm=") printf -- '-zsh\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/ps"
}

death_process_info_fixture() {
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh"}]}}}\n' "$1" "$2" "$2" "$2"
}

live_agent_process_info_fixture() {
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"omp","argv0":"omp"}]}}}\n' "$1" "$2" "$3" "$3"
}

classify() {
  local label=$1 dir=$2
  local log resp fb pane_state recovery_state
  mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  pane_state=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_SESSION=fmtest FM_HERDR_PS_BIN="${FM_HERDR_PS_BIN:-}" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state fmtest w1:p2' "$ROOT")
  rm -f "$resp/.count"
  recovery_state=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_SESSION=fmtest FM_HERDR_PS_BIN="${FM_HERDR_PS_BIN:-}" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p2' "$ROOT")
  printf '\n== %s ==\npane_agent_state=%s\nrecovery_state=%s\n' "$label" "$pane_state" "$recovery_state"
}

printf 'HERDR HUSK CLASSIFIER (public backend functions)\n'

# 1. done-binding + bare shell => no-agent / dead
dir="$TMP_ROOT/husk-done-bare-shell"; mkdir -p "$dir/responses"
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' > "$dir/responses/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"done"}}}' > "$dir/responses/2.out"
death_process_info_fixture w1:p2 4242 > "$dir/responses/3.out"
cp "$dir/responses/1.out" "$dir/responses/4.out"
cp "$dir/responses/2.out" "$dir/responses/5.out"
cp "$dir/responses/3.out" "$dir/responses/6.out"
make_death_lab "$dir" 4242
FM_HERDR_PS_BIN="$dir/ps" classify "done binding + bare shell (provider-death husk)" "$dir"

# 2. done-binding + live omp => live / alive
dir="$TMP_ROOT/husk-done-live-agent"; mkdir -p "$dir/responses"
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' > "$dir/responses/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"done"}}}' > "$dir/responses/2.out"
live_agent_process_info_fixture w1:p2 100 200 > "$dir/responses/3.out"
cp "$dir/responses/1.out" "$dir/responses/4.out"
cp "$dir/responses/2.out" "$dir/responses/5.out"
cp "$dir/responses/3.out" "$dir/responses/6.out"
unset FM_HERDR_PS_BIN
classify "done binding + live omp foreground (must still refuse)" "$dir"

# 3. closed pane => dead / missing
dir="$TMP_ROOT/husk-missing-endpoint"; mkdir -p "$dir/responses"
printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$dir/responses/1.out"
classify "closed pane / missing endpoint (recreate)" "$dir"

printf '\nCONTROL PLANE (public CLIs, no --force)\n'

# Reuse the tmux lifecycle stub from fm-control tests by invoking the real CLIs
# through the same fakebin convention.
make_tmux_stub() {
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

setup_task() {
  local dir=$1 id=$2
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/becomes"
  make_tmux_stub "$dir"
  local proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$dir/home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_cli() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_CONTROL_SETTLE_WAIT=0.05 \
    "$@" 2>&1
}

# Missing endpoint: fm-control exit is already-stopped (no deadlock).
dir="$TMP_ROOT/control-missing"
setup_task "$dir" gone1
: > "$dir/fake/windows"
printf 'zsh' > "$dir/fake/command"
out=$(run_cli "$dir" "$ROOT/bin/fm-control.sh" gone1 exit); rc=$?
printf '\n== fm-control gone1 exit (missing window list) ==\nexit=%s\n%s\n' "$rc" "$out"

# Live agent: fm-spawn --relaunch refuses (true-positive guard).
dir="$TMP_ROOT/spawn-live"
setup_task "$dir" live1
printf 'claude' > "$dir/fake/command"
out=$(run_cli "$dir" "$ROOT/bin/fm-spawn.sh" live1 --relaunch --harness claude); rc=$?
printf '\n== fm-spawn live1 --relaunch (live agent, no --force) ==\nexit=%s\n%s\n' "$rc" "$out"

# Dead husk analog: agent-free pane, fm-control relaunch without force.
dir="$TMP_ROOT/control-husk"
setup_task "$dir" husk1
printf 'zsh' > "$dir/fake/command"
out=$(run_cli "$dir" "$ROOT/bin/fm-control.sh" husk1 relaunch --note "provider died; relaunch the husk"); rc=$?
printf '\n== fm-control husk1 relaunch --note ... (agent-free pane, no --force) ==\nexit=%s\n%s\n' "$rc" "$out"

# Dead husk analog via spawn --relaunch directly.
dir="$TMP_ROOT/spawn-dead"
setup_task "$dir" dead1
printf 'zsh' > "$dir/fake/command"
out=$(run_cli "$dir" "$ROOT/bin/fm-spawn.sh" dead1 --relaunch --harness claude); rc=$?
printf '\n== fm-spawn dead1 --relaunch (agent-free pane, no --force) ==\nexit=%s\n%s\n' "$rc" "$out"
