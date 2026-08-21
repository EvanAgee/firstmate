#!/usr/bin/env bash
# Public-interface probe: fm-control.sh exit on an already-dead and an
# already-missing task must retire leftover busy wiring. This is the
# CodeRabbit already-stopped path, not a source grep.
set -u
ROOT=${1:?usage: run-busy-retirement-probe.sh <repo-root>}
CONTROL="$ROOT/bin/fm-control.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# Re-resolve ROOT from lib.sh after sourcing.
ROOT="$(cd "$ROOT" && pwd)"
CONTROL="$ROOT/bin/fm-control.sh"

TMP=$(fm_test_tmproot busy-retire-probe)
mkdir -p "$TMP"

make_tmux_stub() {
  local dir=$1 fb="$1/fakebin"
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
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

setup_task() {
  local dir=$1 id=t1
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  make_tmux_stub "$dir"
  local proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$dir/home/data/$id"
  printf '# brief\n' > "$dir/home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

probe_one() {
  local label=$1 missing=$2
  local dir="$TMP/$label"
  mkdir -p "$dir"
  setup_task "$dir"
  if [ "$missing" = 1 ]; then
    : > "$dir/fake/windows"
  fi
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  echo "=== $label BEFORE ==="
  echo "busy-gen=$(cat "$dir/home/state/t1.busy-gen")"
  echo "busy-state=$(cat "$dir/home/state/t1.busy-state")"
  local out rc
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" t1 exit 2>&1); rc=$?
  echo "=== $label EXIT rc=$rc ==="
  printf '%s\n' "$out"
  echo "=== $label AFTER ==="
  if [ -e "$dir/home/state/t1.busy-gen" ]; then
    echo "busy-gen-present=$(cat "$dir/home/state/t1.busy-gen")"
  else
    echo "busy-gen-present=ABSENT"
  fi
  if [ -e "$dir/home/state/t1.busy-state" ]; then
    echo "busy-state-present=$(cat "$dir/home/state/t1.busy-state")"
  else
    echo "busy-state-present=ABSENT"
  fi
  echo "literals=$(cat "$dir/fake/literal")"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'already-stopped t1' \
     && [ ! -e "$dir/home/state/t1.busy-gen" ] \
     && [ ! -e "$dir/home/state/t1.busy-state" ]; then
    echo "RESULT $label: PASS (already-stopped and busy wiring retired)"
    return 0
  fi
  echo "RESULT $label: FAIL (busy wiring leftover or unexpected exit outcome)"
  return 1
}

fail=0
probe_one dead-agent 0 || fail=1
echo
probe_one missing-endpoint 1 || fail=1
exit "$fail"
