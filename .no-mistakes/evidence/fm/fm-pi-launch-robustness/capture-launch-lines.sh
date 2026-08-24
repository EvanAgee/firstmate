#!/usr/bin/env bash
# Capture the literal tmux send-keys launch lines fm-spawn would type into a pane.
set -u
ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0TV0Z65JH69CXP0DFGC5PRQ"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-launch-evidence)

make_pi_stub() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Options:' '  --tui-mode <mode>' '  --no-extensions, -ne' '  --extension, -e <path>'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_pi_stub "$fakebin" pi
  make_pi_stub "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

install_sibling_node() {
  local fakebin=$1
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/node"
}

make_case() {
  local name=$1 harness=$2 id=$3
  local case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>/dev/null
}

dump() {
  local title=$1 log=$2
  printf '\n======== %s ========\n' "$title"
  cat "$log"
  printf '\n'
}

IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$(make_case crew-pin pi crew-pin-e1)
EOF
install_sibling_node "$FAKEBIN_DIR"
run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" crew-pin-e1 "$PROJ_DIR" --mode no-mistakes --yolo off >/dev/null
dump "crew pi with sibling node (must PATH-pin then --no-extensions)" "$LAUNCH_LOG"

IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$(make_case crew-nopin pi crew-nopin-e2)
EOF
run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" crew-nopin-e2 "$PROJ_DIR" --mode no-mistakes --yolo off >/dev/null
dump "crew pi without sibling node (no invented PATH pin, still --no-extensions)" "$LAUNCH_LOG"

IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$(make_case scout-pi pi scout-e3)
EOF
install_sibling_node "$FAKEBIN_DIR"
run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" scout-e3 "$PROJ_DIR" --scout >/dev/null
dump "scout pi (must --no-extensions + PATH pin)" "$LAUNCH_LOG"

IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$(make_case secondmate-pi pi secondmate-e4)
EOF
install_sibling_node "$FAKEBIN_DIR"
sm="$CASE_DIR/secondmate-home"
mkdir -p "$sm/bin" "$sm/data"
printf '# Firstmate\n' > "$sm/AGENTS.md"
printf '%s\n' "secondmate-e4" > "$sm/.fm-secondmate-home"
printf 'charter for secondmate-e4\n' > "$sm/data/charter.md"
sm=$(cd "$sm" && pwd -P)
run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" secondmate-e4 "$sm" --secondmate >/dev/null
dump "secondmate pi (must keep discovery: no --no-extensions)" "$LAUNCH_LOG"

IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$(make_case hostile-probe pi hostile-e5)
EOF
install_sibling_node "$FAKEBIN_DIR"
mkdir -p "$CASE_DIR/repo-node/bin"
cat > "$CASE_DIR/repo-node/bin/node" <<'SH'
#!/usr/bin/env bash
echo 'TypeError: webidl.util.markAsUncloneable is not a function' >&2
exit 1
SH
chmod +x "$CASE_DIR/repo-node/bin/node"
: > "$LAUNCH_LOG"
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  PATH="$CASE_DIR/repo-node/bin:$FAKEBIN_DIR:$PATH" \
  "$SPAWN" hostile-e5 "$PROJ_DIR" --mode no-mistakes --yolo off >/dev/null
dump "crew pi under hostile repo Node (probe must still keep --tui-mode regular)" "$LAUNCH_LOG"
