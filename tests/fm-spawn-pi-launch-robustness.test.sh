#!/usr/bin/env bash
# Behavior tests for the two Pi launch failures fm-spawn defends against.
#
# Both are launch-environment failures, not Pi failures, and both are invisible
# until a crewmate pane dies at startup, so they are pinned here through the
# literal launch command a fake tmux captures with `tmux send-keys -l`.
#
# 1. Pi ships as a `#!/usr/bin/env node` script, so a project that pins an older
#    Node puts the wrong runtime ahead of the one Pi's install owns and Pi dies
#    importing its own dependencies. fm-spawn prepends the directory of the
#    resolved Pi executable, which is where an nvm/Volta/asdf install also keeps
#    `node`, so the owning runtime wins in the pane.
# 2. A crewmate worktree of the firstmate project carries firstmate's tracked
#    primary-only .pi extensions, which a crew Pi session must not discover.
#    fm-spawn passes --no-extensions for crewmate and scout launches while a
#    secondmate, which is a primary in its own home, keeps discovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-launch)

# A Pi stub that advertises the flags the real 0.84.2 CLI advertises, so the
# launch construction under test sees a supporting Pi.
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

# The Pi entry point and its owning `node` share one bin directory in every
# version-manager layout, so a sibling stub is what makes the pin observable.
install_sibling_node() {
  local fakebin=$1
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/node"
}

make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
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

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
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
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

test_crew_pi_launch_pins_node_from_pi_install_dir() {
  local rec id out status launch
  id=pi-node-pin-a1
  rec=$(make_case pi-node-pin pi "$id")
  read_case_record "$rec"
  install_sibling_node "$FAKEBIN_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn beside its own node should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "PATH='$FAKEBIN_DIR':\"\$PATH\"" \
    "pi launch must put the directory owning its install ahead of a project Node pin"
  # The pin must precede the executable, or the project's Node still wins.
  case "$launch" in
    *"PATH='$FAKEBIN_DIR'"*"$FAKEBIN_DIR/pi"*) ;;
    *) fail "pi launch put the Node pin after the executable it must govern"$'\n'"actual: $launch" ;;
  esac
  pass "a crew pi launch pins the Node that owns its install ahead of the project's"
}

test_pi_launch_omits_node_pin_without_a_sibling_runtime() {
  local rec id out status launch
  id=pi-node-nopin-a2
  rec=$(make_case pi-node-nopin pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn without a sibling node should still succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" 'PATH=' \
    "a standalone Pi install needs no interpreter pin and must not get a synthetic one"
  pass "a Pi install with no sibling runtime launches without an invented pin"
}

test_pi_node_pin_survives_a_probe_under_a_hostile_path() {
  local rec id out status launch
  id=pi-node-pin-probe-a3
  rec=$(make_case pi-node-pin-probe pi "$id")
  read_case_record "$rec"
  install_sibling_node "$FAKEBIN_DIR"
  # A project Node pin that breaks Pi: the stub refuses unless the launch pins
  # the runtime beside Pi itself, exactly as the real undici import failure does.
  mkdir -p "$CASE_DIR/repo-node/bin"
  cat > "$CASE_DIR/repo-node/bin/node" <<'SH'
#!/usr/bin/env bash
echo 'TypeError: webidl.util.markAsUncloneable is not a function' >&2
exit 1
SH
  chmod +x "$CASE_DIR/repo-node/bin/node"

  out=$(PATH="$CASE_DIR/repo-node/bin:$PATH" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn under a hostile project Node pin should still succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "PATH='$FAKEBIN_DIR':\"\$PATH\"" \
    "a hostile project Node pin must not stop the launch from pinning Pi's own runtime"
  assert_contains "$launch" '--tui-mode regular' \
    "the CLI probe must run under the pinned runtime so a supported flag is not silently dropped"
  pass "a project Node pin cannot break the pin or silently drop a probed Pi flag"
}

test_crew_pi_launch_disables_extension_discovery() {
  local rec id out status launch
  id=pi-noext-a4
  rec=$(make_case pi-noext pi "$id")
  read_case_record "$rec"
  # A primary-only extension of the kind a firstmate worktree carries; a crew
  # session must never discover it. It is committed, because the real ones are
  # tracked files every worktree of that project inherits.
  mkdir -p "$PROJ_DIR/.pi/extensions"
  printf 'export default function () {}\n' > "$PROJ_DIR/.pi/extensions/fm-primary-pi-watch.ts"
  git -C "$PROJ_DIR" add .pi >/dev/null 2>&1
  git -C "$PROJ_DIR" commit -q -m 'add primary-only extension' >/dev/null 2>&1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi crew spawn in a worktree carrying primary extensions should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '--no-extensions' \
    "a crew pi launch must not discover the worktree's primary-only extensions"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" \
    "--no-extensions must not cost the crew its explicit per-task turn-end extension"
  # The launch never edits the project copy; discovery is refused in the pane.
  [ -f "$PROJ_DIR/.pi/extensions/fm-primary-pi-watch.ts" ] \
    || fail "the launch removed a project extension instead of refusing discovery"
  pass "a crew pi launch refuses extension discovery while keeping its own sidecar"
}

test_scout_pi_launch_disables_extension_discovery() {
  local rec id out status launch
  id=pi-noext-scout-a5
  rec=$(make_case pi-noext-scout pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "pi scout spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '--no-extensions' \
    "a scout pi launch shares the crew contract and must refuse extension discovery"
  pass "a scout pi launch refuses extension discovery too"
}

test_secondmate_pi_launch_keeps_extension_discovery() {
  local rec id out status launch sm
  id=pi-secondmate-a6
  rec=$(make_case pi-secondmate pi "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi secondmate spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" '--no-extensions' \
    "a secondmate is a primary in its own home and must keep extension discovery"
  assert_contains "$launch" "-e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "a secondmate launch must keep its own primary supervision extensions"
  pass "a secondmate pi launch keeps extension discovery"
}

test_pi_signed_shares_the_crew_launch_contract() {
  local rec id out status launch
  id=pi-signed-parity-a7
  rec=$(make_case pi-signed-parity pi-signed "$id")
  read_case_record "$rec"
  install_sibling_node "$FAKEBIN_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi-signed crew spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" \
    "pi-signed must keep its own recorded identity while sharing pi's launch fixes"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "PATH='$FAKEBIN_DIR':\"\$PATH\"" \
    "pi-signed must receive the same interpreter pin as pi"
  assert_contains "$launch" '--no-extensions' \
    "pi-signed must refuse crew extension discovery exactly like pi"
  pass "pi-signed shares pi's crew launch contract on both axes"
}

test_crew_pi_launch_pins_node_from_pi_install_dir
test_pi_launch_omits_node_pin_without_a_sibling_runtime
test_pi_node_pin_survives_a_probe_under_a_hostile_path
test_crew_pi_launch_disables_extension_discovery
test_scout_pi_launch_disables_extension_discovery
test_secondmate_pi_launch_keeps_extension_discovery
test_pi_signed_shares_the_crew_launch_contract

echo "# all fm-spawn-pi-launch-robustness tests passed"
