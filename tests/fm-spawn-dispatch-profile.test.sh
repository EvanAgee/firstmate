#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)
PROFILE_RUN_TOKEN="t$$-${RANDOM:-0}"
profile_id() { printf '%s-%s' "$1" "$PROFILE_RUN_TOKEN"; }
cleanup() {
  local data_dir id home meta tasktmp
  while IFS= read -r data_dir; do
    id=$(basename "$data_dir")
    home=$(dirname "$(dirname "$data_dir")")
    meta="$home/state/$id.meta"
    tasktmp=$(sed -n 's/^tasktmp=//p' "$meta" 2>/dev/null)
    [ -n "$tasktmp" ] || tasktmp=$(sed -n 's/^tasktmp=//p' "$meta.test-owner" 2>/dev/null)
    [ -n "$tasktmp" ] || tasktmp="/tmp/fm-$id"
    case "$id:$tasktmp" in
      profile-*:/tmp/fm-"$id") rm -rf "$tasktmp" ;;
    esac
  done < <(find "$TMP_ROOT" -type d -path '*/home/data/profile-*' 2>/dev/null)
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
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
  has-session|new-session) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'kill-window %s\n' "$*" >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'new-window\n' >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
      case "$*" in
        *Enter*)
          if grep -Fq 'FM_OMP_HARNESS=omp' "$FM_FAKE_LAUNCH_LOG" 2>/dev/null; then
            [ -z "${FM_FAKE_OMP_ACK:-}" ] || : > "$FM_FAKE_OMP_ACK"
            if [ -n "${FM_FAKE_OMP_META_TAMPER:-}" ]; then
              cp "$FM_FAKE_OMP_META_TAMPER" "$FM_FAKE_OMP_META_TAMPER.test-owner"
              printf 'window=unrelated:retry\n' > "$FM_FAKE_OMP_META_TAMPER"
            fi
          fi
          ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ -n "${FM_FAKE_CAT_FAILURE_PATH:-}" ] \
   && [ "$1" = "$FM_FAKE_CAT_FAILURE_PATH" ]; then
  exit 1
fi
exec /bin/cat "$@"
SH
  cat > "$fakebin/id" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ -n "${FM_FAKE_CURRENT_UID:-}" ]; then
  printf '%s\n' "$FM_FAKE_CURRENT_UID"
  exit 0
fi
exec /usr/bin/id "$@"
SH
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_MKTEMP_PATTERN:-}" ] && [ "${1:-}" = "$FM_FAKE_MKTEMP_PATTERN" ]; then
  exit 1
fi
exec /usr/bin/mktemp "$@"
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_STAT_FAILURE_FORMAT:-}" ] && [ "${2:-}" = "$FM_FAKE_STAT_FAILURE_FORMAT" ]; then
  exit 1
fi
exec /usr/bin/stat "$@"
SH
  chmod +x "$fakebin/cat" "$fakebin/id" "$fakebin/mktemp" "$fakebin/stat"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${1:-}
sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fm-profile-herdr.sock"}]}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[]}}'
    ;;
  "tab create")
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'tab create\n' >> "$FM_FAKE_ENDPOINT_LOG"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "pane get")
    if [ -n "${FM_FAKE_HERDR_PANE_FLAG:-}" ] && [ ! -f "$FM_FAKE_HERDR_PANE_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${3:-w1:p2}" "${FM_FAKE_PANE_PATH:-}"
    ;;
  "pane run")
    exit 0
    ;;
  "pane send-text")
    [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
    ;;
  "pane send-keys")
    case "${4:-}" in
      enter)
        if grep -Fq 'FM_OMP_HARNESS=omp' "${FM_FAKE_LAUNCH_LOG:-/dev/null}" 2>/dev/null; then
          [ -z "${FM_FAKE_OMP_ACK:-}" ] || : > "$FM_FAKE_OMP_ACK"
        fi
        ;;
    esac
    ;;
  "pane close")
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'pane close %s\n' "${3:-}" >> "$FM_FAKE_ENDPOINT_LOG"
    if [ "${FM_FAKE_HERDR_REFUSE_CLOSE:-0}" = 1 ]; then
      exit 0
    fi
    [ -z "${FM_FAKE_HERDR_PANE_FLAG:-}" ] || rm -f "$FM_FAKE_HERDR_PANE_FLAG"
    ;;
  "agent get")
    if [ -n "${FM_FAKE_HERDR_PANE_FLAG:-}" ] && [ ! -f "$FM_FAKE_HERDR_PANE_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"agent":{"agent":"omp","agent_status":"idle"}}}'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bun
case "${1:-}" in
  --help)
    printf '%s\n' '--model=<value>' '--thinking=<value>' '--auto-approve' '--session-dir=<value>' '-e, --extension=<value>' '-r, --resume=<value>'
    [ "${FM_FAKE_OMP_APPEND:-yes}" != yes ] || printf '%s\n' '--append-system-prompt=<path>'
    ;;
  --version) printf 'omp/17.1.8\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/omp"
  cat > "$fakebin/bun" <<'SH'
#!/usr/bin/env bash
script=$1
shift
exec bash "$script" "$@"
SH
  chmod +x "$fakebin/bun"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog worker_home id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  worker_home="$case_dir/worker-home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$worker_home/.agents/skills/caveman" "$worker_home/.agents/skills/ponytail"
  printf '%s\n' 'CAVEMAN_FIXTURE_BODY' > "$worker_home/.agents/skills/caveman/SKILL.md"
  printf '%s\n' 'PONYTAIL_FIXTURE_BODY' > "$worker_home/.agents/skills/ponytail/SKILL.md"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    [ ! -e "/tmp/fm-$id" ] && [ ! -L "/tmp/fm-$id" ] \
      || fail "refusing fixture task-id collision at /tmp/fm-$id"
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","when":"builder work","use":[{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"grok","model":"grok-4","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

# A ladder with one switched-off rung (claude/opus/high) beside an enabled one.
enable_dispatch_profile_with_switched_off_rung() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","when":"big feature","use":[{"harness":"claude","model":"opus","effort":"high","enabled":false},{"harness":"codex","model":"gpt-5","effort":"high"}]}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

enable_dispatch_profile_with_switched_off_pin() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","when":"big feature","use":[{"harness":"codex","model":"gpt-5","effort":"high","enabled":false},{"harness":"grok","model":"grok-4","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

enable_dispatch_profile_with_default_model_duplicate() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","use":[{"harness":"codex","enabled":false},{"harness":"codex","model":"default"}],"pin":{"harness":"codex"}}],"default":{"harness":"claude"}}' \
    > "$home/config/crew-dispatch.json"
}

enable_dispatch_profile_with_whitespace() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","use":{"harness":"codex","model":"gpt 5","effort":"high"},"pin":{"harness":"codex","model":"gpt 5","effort":"high"}}],"default":{"harness":"claude"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 endpointlog treehouselog herdrpaneflag worker_home rc meta tasktmp
  shift 4
  endpointlog="${launchlog%/*}/endpoint.log"
  treehouselog="${launchlog%/*}/treehouse.log"
  herdrpaneflag="${launchlog%/*}/herdr-pane"
  worker_home="${FM_TEST_WORKER_HOME:-${launchlog%/*}/worker-home}"
  : > "$launchlog"
  : > "$endpointlog"
  : > "$treehouselog"
  : > "$herdrpaneflag"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  HOME="$worker_home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    FM_FAKE_ENDPOINT_LOG="$endpointlog" \
    FM_FAKE_TREEHOUSE_LOG="$treehouselog" FM_FAKE_OMP_ACK="${FM_TEST_OMP_ACK:-}" \
    FM_FAKE_OMP_APPEND="${FM_TEST_OMP_APPEND:-yes}" \
    FM_FAKE_CAT_FAILURE_PATH="${FM_TEST_CAT_FAILURE_PATH:-}" \
    FM_FAKE_CURRENT_UID="${FM_TEST_CURRENT_UID:-}" \
    FM_FAKE_MKTEMP_PATTERN="${FM_TEST_MKTEMP_PATTERN:-}" \
    FM_FAKE_STAT_FAILURE_FORMAT="${FM_TEST_STAT_FAILURE_FORMAT:-}" \
    FM_FAKE_PRINTF_FAILURE_FORMAT="${FM_TEST_PRINTF_FAILURE_FORMAT:-}" \
    FM_FAKE_HERDR_PANE_FLAG="$herdrpaneflag" \
    FM_FAKE_HERDR_REFUSE_CLOSE="${FM_TEST_HERDR_REFUSE_CLOSE:-0}" \
    FM_FAKE_OMP_META_TAMPER="${FM_TEST_OMP_META_TAMPER:-}" \
    BASH_ENV="${FM_TEST_BASH_ENV:-}" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ "${FM_TEST_KEEP_TASK_TMP:-0}" != 1 ]; then
    for meta in "$home/state"/*.meta; do
      [ -f "$meta" ] || continue
      tasktmp=$(sed -n 's/^tasktmp=//p' "$meta")
      case "$tasktmp" in /tmp/fm-profile-*) rm -rf "$tasktmp" ;; esac
    done
  fi
  return "$rc"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

assert_meta_dispatch() {
  local meta=$1 dispatch_class=$2 dispatch_reason=$3
  assert_grep "dispatch_class=$dispatch_class" "$meta" "meta missing dispatch_class=$dispatch_class"
  assert_grep "dispatch_reason=$dispatch_reason" "$meta" "meta missing dispatch_reason=$dispatch_reason"
}

find_single_task_tmp_file() {  # <task-tmp> <prefix>
  local tasktmp=$1 prefix=$2
  set -- "$tasktmp/$prefix".????????
  [ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ] \
    || fail "expected one regular $prefix task-temp file under $tasktmp"
  printf '%s\n' "$1"
}

task_tmp_mode() {  # <directory>
  if [ "$(uname -s)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch tasktmp prompt
  id=$(profile_id profile-off-z1)
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"

  out=$(FM_TEST_KEEP_TASK_TMP=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  prompt=$(find_single_task_tmp_file "$tasktmp" worker-skills) \
    || fail "could not locate the no-profile Claude worker-skill prompt"
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --append-system-prompt-file '$prompt' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  rm -rf "$tasktmp"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-claude-cursor-markers-z1b
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

assert_worker_skill_prompt() {  # <prompt-file>
  local prompt=$1
  [ "$(sed -n '1p' "$prompt")" = 'Active skill levels: caveman: full, ponytail: full' ] \
    || fail "worker skill prompt did not start with both full levels"
  assert_grep 'CAVEMAN_FIXTURE_BODY' "$prompt" "worker skill prompt lost the caveman body"
  assert_grep 'PONYTAIL_FIXTURE_BODY' "$prompt" "worker skill prompt lost the ponytail body"
}

test_claude_loads_concatenated_worker_skill_prompt() {
  local rec id out status launch prompt tasktmp
  id=$(profile_id profile-worker-skills-claude)
  rec=$(make_spawn_case profile-worker-skills-claude claude "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"

  out=$(FM_TEST_KEEP_TASK_TMP=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude worker-skill spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  prompt=$(find_single_task_tmp_file "$tasktmp" worker-skills) \
    || fail "could not locate the Claude worker-skill prompt"
  assert_contains "$launch" "--append-system-prompt-file '$prompt'" \
    "Claude launch omitted its worker skill prompt file"
  assert_worker_skill_prompt "$prompt"
  rm -rf "$tasktmp"
  pass "Claude launch appends one prompt containing both worker skills"
}

test_pi_family_loads_each_worker_skill_directory() {
  local harness rec id out status launch worker_home tasktmp
  for harness in pi pi-signed; do
    id=$(profile_id "profile-worker-skills-$harness")
    rec=$(make_spawn_case "profile-worker-skills-$harness" "$harness" "$id")
    read_case_record "$rec"
    tasktmp="/tmp/fm-$id"
    worker_home=$(cd "$CASE_DIR/worker-home" && pwd -P)

    out=$(FM_TEST_KEEP_TASK_TMP=1 \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness worker-skill spawn should succeed"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "--skill '$worker_home/.agents/skills/caveman'" \
      "$harness launch omitted the caveman skill directory"
    assert_contains "$launch" "--skill '$worker_home/.agents/skills/ponytail'" \
      "$harness launch omitted the ponytail skill directory"
    [ "$(grep -Fo -- '--skill' "$LAUNCH_LOG" | wc -l | tr -d ' ')" = 2 ] \
      || fail "$harness launch did not pass exactly two --skill flags"
    rm -rf "$tasktmp"
  done
  pass "Pi and pi-signed launch with each worker skill directory"
}

test_pi_worker_skill_paths_preserve_ampersands() {
  local rec id out status launch worker_home tasktmp
  id=$(profile_id profile-worker-skills-pi-ampersand)
  rec=$(make_spawn_case profile-worker-skills-pi-ampersand pi "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  worker_home="$CASE_DIR/worker&home"
  mv "$CASE_DIR/worker-home" "$worker_home"
  worker_home=$(cd "$worker_home" && pwd -P)

  out=$(FM_TEST_KEEP_TASK_TMP=1 FM_TEST_WORKER_HOME="$worker_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Pi worker-skill spawn with an ampersand-bearing HOME should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--skill '$worker_home/.agents/skills/caveman'" \
    "Pi launch corrupted the caveman skill directory"
  assert_contains "$launch" "--skill '$worker_home/.agents/skills/ponytail'" \
    "Pi launch corrupted the ponytail skill directory"
  assert_not_contains "$launch" '__WORKERSKILLPI__' \
    "Pi launch expanded an ampersand into the worker-skill placeholder"
  rm -rf "$tasktmp"
  pass "Pi preserves ampersands in worker skill paths"
}

test_omp_loads_concatenated_worker_skill_prompt() {
  local rec id out status launch prompt tasktmp
  id=$(profile_id profile-worker-skills-omp)
  rec=$(make_spawn_case profile-worker-skills-omp omp "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"

  out=$(FM_TEST_KEEP_TASK_TMP=1 FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP worker-skill spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  prompt=$(find_single_task_tmp_file "$tasktmp" worker-skills) \
    || fail "could not locate the OMP worker-skill prompt"
  assert_contains "$launch" "--append-system-prompt='$prompt'" \
    "OMP launch omitted its worker skill prompt file"
  assert_worker_skill_prompt "$prompt"
  rm -rf "$tasktmp"
  pass "OMP launch appends one prompt containing both worker skills"
}

test_omp_without_append_support_uses_worker_skill_brief() {
  local rec id out status launch delivered worker_home tasktmp expected
  id=$(profile_id profile-worker-skills-omp-fallback)
  rec=$(make_spawn_case profile-worker-skills-omp-fallback omp "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  worker_home=$(cd "$CASE_DIR/worker-home" && pwd -P)
  expected="Caveman and ponytail are active for this session. Load their rules from $worker_home/.agents/skills/caveman/SKILL.md and $worker_home/.agents/skills/ponytail/SKILL.md."

  out=$(FM_TEST_KEEP_TASK_TMP=1 FM_TEST_OMP_APPEND=no \
    FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP without append-system-prompt should use brief delivery"
  launch=$(cat "$LAUNCH_LOG")
  delivered=$(find_single_task_tmp_file "$tasktmp" brief) \
    || fail "could not locate the OMP fallback brief"
  assert_not_contains "$launch" "--append-system-prompt" \
    "OMP fallback launch used an unsupported append-system-prompt flag"
  assert_contains "$launch" "encode launch-brief < '$delivered'" \
    "OMP fallback launch did not deliver the prefixed brief"
  [ "$(sed -n '1p' "$delivered")" = "$expected" ] \
    || fail "OMP fallback brief did not name both active skill paths"
  rm -rf "$tasktmp"
  pass "OMP uses brief delivery when append-system-prompt is unavailable"
}

test_fallback_harness_gets_worker_skill_brief_prefix() {
  local rec id out status launch delivered worker_home tasktmp expected
  id=$(profile_id profile-worker-skills-fallback)
  rec=$(make_spawn_case profile-worker-skills-fallback codex "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  worker_home=$(cd "$CASE_DIR/worker-home" && pwd -P)
  expected="Caveman and ponytail are active for this session. Load their rules from $worker_home/.agents/skills/caveman/SKILL.md and $worker_home/.agents/skills/ponytail/SKILL.md."

  out=$(FM_TEST_KEEP_TASK_TMP=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "fallback worker-skill spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  delivered=$(find_single_task_tmp_file "$tasktmp" brief) \
    || fail "could not locate the fallback worker-skill brief"
  assert_contains "$launch" "encode launch-brief < '$delivered'" \
    "fallback launch did not deliver the prefixed brief"
  [ "$(sed -n '1p' "$delivered")" = "$expected" ] \
    || fail "fallback brief did not name both active skill paths"
  [ "$(sed -n '2p' "$delivered")" = "brief for $id" ] \
    || fail "fallback brief prefix replaced the original brief"
  rm -rf "$tasktmp"
  pass "fallback launch prepends both worker skill paths to the delivered brief"
}

test_task_tmp_uses_private_directories_and_exclusive_files() {
  local harness_leaf harness leaf rec id out status tasktmp victim generated
  for harness_leaf in claude:worker-skills.md codex:brief.md; do
    harness=${harness_leaf%%:*}
    leaf=${harness_leaf#*:}
    id=$(profile_id "profile-worker-skills-private-$harness")
    rec=$(make_spawn_case "profile-worker-skills-private-$harness" "$harness" "$id")
    read_case_record "$rec"
    tasktmp="/tmp/fm-$id"
    victim="$CASE_DIR/victim"
    printf '%s\n' untouched > "$victim"
    mkdir "$tasktmp"
    chmod 0777 "$tasktmp"
    ln -s "$victim" "$tasktmp/$leaf"

    out=$(FM_TEST_KEEP_TASK_TMP=1 \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness spawn should ignore a symlink at the old predictable leaf"
    [ "$(cat "$victim")" = untouched ] || fail "$harness spawn followed $leaf symlink"
    [ "$(task_tmp_mode "$tasktmp")" = 700 ] || fail "$harness task temp root was not mode 0700"
    [ "$(task_tmp_mode "$tasktmp/gotmp")" = 700 ] || fail "$harness Go temp directory was not mode 0700"
    if [ "$harness" = claude ]; then
      generated=$(find_single_task_tmp_file "$tasktmp" worker-skills) \
        || fail "could not locate the private Claude worker-skill prompt"
    else
      generated=$(find_single_task_tmp_file "$tasktmp" brief) \
        || fail "could not locate the private fallback brief"
    fi
    [ ! -L "$generated" ] || fail "$harness generated a symlinked worker-skill file"
    rm -rf "$tasktmp"
  done
  pass "worker-skill task temp uses private directories and exclusive files"
}

test_missing_worker_skill_warns_once_and_launches() {
  local rec id out status launch worker_home missing tasktmp
  id=$(profile_id profile-worker-skills-missing)
  rec=$(make_spawn_case profile-worker-skills-missing pi "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  worker_home=$(cd "$CASE_DIR/worker-home" && pwd -P)
  missing="$CASE_DIR/worker-home/.agents/skills/ponytail/SKILL.md"
  rm "$missing"

  out=$(FM_TEST_KEEP_TASK_TMP=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should continue when one worker skill is missing"
  [ "$(printf '%s\n' "$out" | grep -c '^SKILLS:')" = 1 ] \
    || fail "missing worker skill did not produce exactly one SKILLS diagnostic"
  assert_contains "$out" "$missing" \
    "missing worker skill diagnostic did not name the absent file"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--skill '$worker_home/.agents/skills/caveman'" \
    "spawn dropped the available caveman skill"
  assert_not_contains "$launch" "--skill '$worker_home/.agents/skills/ponytail'" \
    "spawn passed a missing ponytail skill directory"
  rm -rf "$tasktmp"
  pass "a missing worker skill warns once and does not fail the launch"
}

test_worker_skill_read_failure_warns_once_and_drops_only_failed_skill() {
  local rec id out status prompt caveman_source caveman_resolved tasktmp
  id=$(profile_id profile-worker-skills-read-failure)
  rec=$(make_spawn_case profile-worker-skills-read-failure claude "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  caveman_source="$CASE_DIR/worker-home/.agents/skills/caveman/SKILL.md"
  caveman_resolved=$(cd "$(dirname "$caveman_source")" && pwd -P)/SKILL.md

  out=$(FM_TEST_KEEP_TASK_TMP=1 FM_TEST_CAT_FAILURE_PATH="$caveman_resolved" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should continue when one resolved worker skill cannot be read"
  [ "$(printf '%s\n' "$out" | grep -c '^SKILLS:')" = 1 ] \
    || fail "unreadable worker skill did not produce exactly one SKILLS diagnostic"
  assert_contains "$out" "$caveman_source" \
    "unreadable worker skill diagnostic did not name the failed file"
  prompt=$(find_single_task_tmp_file "$tasktmp" worker-skills) \
    || fail "could not locate the partial worker-skill prompt"
  [ "$(sed -n '1p' "$prompt")" = 'Active skill levels: ponytail: full' ] \
    || fail "worker skill prompt claimed the unreadable caveman skill was active"
  assert_no_grep 'CAVEMAN_FIXTURE_BODY' "$prompt" \
    "worker skill prompt included the unreadable caveman body"
  assert_grep 'PONYTAIL_FIXTURE_BODY' "$prompt" \
    "worker skill prompt dropped the readable ponytail body"
  rm -rf "$tasktmp"
  pass "an unreadable worker skill warns once and is not claimed active"
}

test_task_tmp_refusal_precedes_endpoint_and_worktree_allocation() {
  local rec id out status tasktmp
  id=$(profile_id profile-task-tmp-ordering)
  rec=$(make_spawn_case profile-task-tmp-ordering claude "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  mkdir "$tasktmp"

  out=$(FM_TEST_CURRENT_UID=999999 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn should refuse a task temp root owned by another user"
  assert_contains "$out" "task temp directory is not owned by the current user" \
    "task temp ownership refusal was not reported"
  [ ! -s "$CASE_DIR/endpoint.log" ] \
    || fail "task temp ownership refusal created a backend endpoint"
  [ ! -s "$CASE_DIR/treehouse.log" ] \
    || fail "task temp ownership refusal allocated a worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "task temp ownership refusal wrote task metadata"
  rm -rf "$tasktmp"
  pass "task temp validation runs before endpoint and worktree allocation"
}

test_task_tmp_stat_failures_report_the_path() {
  local kind format kind_format rec id out status tasktmp
  if [ "$(uname -s)" = Darwin ]; then
    set -- owner:%u mode:%Lp
  else
    set -- owner:%u mode:%a
  fi
  for kind_format in "$@"; do
    kind=${kind_format%%:*}
    format=${kind_format#*:}
    id=$(profile_id "profile-task-tmp-stat-$kind")
    rec=$(make_spawn_case "profile-task-tmp-stat-$kind" claude "$id")
    read_case_record "$rec"
    tasktmp="/tmp/fm-$id"

    out=$(FM_TEST_STAT_FAILURE_FORMAT="$format" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "spawn should refuse a task temp $kind read failure"
    assert_contains "$out" "could not read task temp directory $kind: $tasktmp" \
      "task temp $kind read failure did not name $tasktmp"
    rm -rf "$tasktmp"
  done
  pass "task temp stat failures name the affected path"
}

test_worker_skill_artifact_creation_failure_precedes_allocation() {
  local rec id out status tasktmp
  id=$(profile_id profile-worker-skills-artifact-failure)
  rec=$(make_spawn_case profile-worker-skills-artifact-failure claude "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"

  out=$(FM_TEST_MKTEMP_PATTERN="$tasktmp/worker-skills.XXXXXXXX" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn should refuse a worker-skill artifact creation failure"
  [ ! -s "$CASE_DIR/endpoint.log" ] \
    || fail "worker-skill artifact failure created a backend endpoint"
  [ ! -s "$CASE_DIR/treehouse.log" ] \
    || fail "worker-skill artifact failure allocated a worktree"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "worker-skill artifact failure typed a launch command"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "worker-skill artifact failure wrote task metadata"
  rm -rf "$tasktmp"
  pass "worker-skill artifacts are created before endpoint and worktree allocation"
}

test_single_skill_prompt_write_failure_is_not_masked() {
  local rec id out status tasktmp bash_env
  id=$(profile_id profile-worker-skills-prompt-write-failure)
  rec=$(make_spawn_case profile-worker-skills-prompt-write-failure claude "$id")
  read_case_record "$rec"
  tasktmp="/tmp/fm-$id"
  rm "$CASE_DIR/worker-home/.agents/skills/ponytail/SKILL.md"
  bash_env="$CASE_DIR/bash-env"
  cat > "$bash_env" <<'SH'
printf() {
  if [ -n "${FM_FAKE_PRINTF_FAILURE_FORMAT:-}" ] \
     && [ "${1:-}" = "$FM_FAKE_PRINTF_FAILURE_FORMAT" ]; then
    return 1
  fi
  builtin printf "$@"
}
SH

  out=$(FM_TEST_BASH_ENV="$bash_env" \
    FM_TEST_PRINTF_FAILURE_FORMAT='Active skill levels: %s\n\n' \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn should propagate a single-skill prompt write failure"
  [ ! -s "$CASE_DIR/endpoint.log" ] \
    || fail "single-skill prompt write failure created a backend endpoint"
  [ ! -s "$CASE_DIR/treehouse.log" ] \
    || fail "single-skill prompt write failure allocated a worktree"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "single-skill prompt write failure typed a launch command"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "single-skill prompt write failure wrote task metadata"
  rm -rf "$tasktmp"
  pass "single-skill prompt write failures stop before allocation"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=$(profile_id profile-relative-paths-z1b)
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=$(profile_id profile-relative-home-defaults-z1c)
  absolute_id=$(profile_id profile-absolute-home-defaults-z1d)
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=$(profile_id profile-absolute-paths-z1c)
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=$(profile_id profile-unresolvable-paths-z1d)
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_class_for_ship() {
  local rec id out status
  id=$(profile_id profile-required-ship-z11)
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without class should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass --class <class>" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires a class for ship spawns"
}

test_active_dispatch_profile_requires_class_for_scout() {
  local rec id out status
  id=$(profile_id profile-required-scout-z12)
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without class should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass --class <class>" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires a class for scout spawns"
}

test_class_resolves_pinned_runtime() {
  local rec id out status launch
  id=$(profile_id profile-explicit-z13)
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "class-based spawn should resolve and launch"
  assert_contains "$out" "dispatch: class=builder harness=codex model=gpt-5 effort=high reason=pin" \
    "spawn did not print the resolved runtime"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report resolved codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_meta_dispatch "$HOME_DIR/state/$id.meta" builder pin
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "a dispatch class resolves its pinned runtime inside fm-spawn"
}

test_active_dispatch_profile_refuses_concrete_harness_without_class() {
  local rec id out status
  id=$(profile_id profile-positional-z14)
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "concrete runtime without class should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass --class <class>" \
    "explicit runtime bypassed class resolution"
  assert_absent "$HOME_DIR/state/$id.meta" "concrete runtime refusal should happen before meta is written"
  pass "an active dispatch profile refuses a concrete runtime without a class"
}

test_class_runtime_override_requires_and_records_captain_reason() {
  local rec id out status
  id=$(profile_id profile-override-z16)
  rec=$(make_spawn_case profile-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness grok --model grok-4 --effort high)
  status=$?
  expect_code 1 "$status" "class runtime override without a captain reason should fail"
  assert_contains "$out" "pass --captain-override <reason>" \
    "spawn did not require a captain override reason"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness grok --model grok-4 --effort high \
    --captain-override "captain chose Grok for this task")
  status=$?
  expect_code 0 "$status" "class runtime override with a captain reason should launch"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  assert_meta_dispatch "$HOME_DIR/state/$id.meta" builder pin
  assert_grep "dispatch_override=captain chose Grok for this task" "$HOME_DIR/state/$id.meta" \
    "meta missing the captain override reason"
  pass "a class runtime override requires and records the captain's reason"
}

test_dispatch_metadata_rejects_line_breaks() {
  local rec id out status
  id=$(profile_id profile-dispatch-line-breaks-z16b)
  rec=$(make_spawn_case profile-dispatch-line-breaks claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class $'builder\nforged=value')
  status=$?
  expect_code 1 "$status" "a dispatch class containing LF should fail"
  assert_contains "$out" "--class cannot contain CR or LF characters" \
    "spawn did not reject LF in the dispatch class"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class $'builder\rforged=value')
  status=$?
  expect_code 1 "$status" "a dispatch class containing CR should fail"
  assert_contains "$out" "--class cannot contain CR or LF characters" \
    "spawn did not reject CR in the dispatch class"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness grok --model grok-4 --effort high \
    --captain-override $'reason\nforged=value')
  status=$?
  expect_code 1 "$status" "a captain override containing LF should fail"
  assert_contains "$out" "--captain-override cannot contain CR or LF characters" \
    "spawn did not reject LF in the captain override"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness grok --model grok-4 --effort high \
    --captain-override $'reason\rforged=value')
  status=$?
  expect_code 1 "$status" "a captain override containing CR should fail"
  assert_contains "$out" "--captain-override cannot contain CR or LF characters" \
    "spawn did not reject CR in the captain override"
  assert_absent "$HOME_DIR/state/$id.meta" "line-break validation should happen before meta is written"
  pass "dispatch metadata rejects CR and LF before writing meta"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=$(profile_id profile-raw-z15)
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  [ "$(printf '%s\n' "$out" | grep -c '^SKILLS:')" = 1 ] \
    || fail "raw launch did not print exactly one SKILLS diagnostic"
  assert_contains "$out" "SKILLS: raw launches get no skill injection" \
    "raw launch did not explain its worker-skill exclusion"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_raw_override_with_class_requires_provable_runtime() {
  local rec id out status
  id=$(profile_id profile-raw-override-z15b)
  rec=$(make_spawn_case profile-raw-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_switched_off_pin "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness "claude --model opus --effort high" \
    --captain-override "captain selected a raw command")
  status=$?
  expect_code 1 "$status" "a raw class override with an unproven runtime should fail"
  assert_contains "$out" "cannot prove runtime axes harness, model, and effort" \
    "raw class refusal did not name every unproven runtime axis"
  assert_contains "$out" "use a supported concrete --harness <adapter>" \
    "raw class refusal did not offer a provable runtime path"
  assert_contains "$out" "omit --class to use the raw launch-command escape hatch" \
    "raw class refusal did not preserve the non-class raw escape hatch"
  [ ! -s "$LAUNCH_LOG" ] || fail "unproven raw class override typed a launch command"
  assert_absent "$HOME_DIR/state/$id.meta" "unproven raw class override wrote metadata"
  pass "a raw class override refuses an unprovable runtime tuple"
}

test_default_model_forms_match_through_spawn() {
  local rec id out status
  id=$(profile_id profile-default-model-z15d)
  rec=$(make_spawn_case profile-default-model claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_default_model_duplicate "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "omitted and explicit default models should resolve identically"
  assert_contains "$out" "dispatch: class=builder harness=codex model=default effort=default reason=pin" \
    "spawn did not normalize the equivalent default models"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "omitted and explicit default models remain equivalent through spawn"
}

test_runtime_whitespace_refuses_before_launch() {
  local rec id out status
  id=$(profile_id profile-runtime-whitespace-z15e)
  rec=$(make_spawn_case profile-runtime-whitespace claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_whitespace "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "runtime whitespace should fail before resolver output is parsed"
  assert_contains "$out" 'runtime values cannot contain whitespace: use profile model="gpt 5"' \
    "runtime whitespace refusal did not name the offending field and value"
  [ ! -s "$LAUNCH_LOG" ] || fail "runtime whitespace reached a launch command"
  assert_absent "$HOME_DIR/state/$id.meta" "runtime whitespace wrote metadata"
  pass "runtime whitespace is refused before launch"
}

test_class_override_refuses_unsupported_runtime() {
  local rec id out status
  id=$(profile_id profile-unsupported-override-z15f)
  rec=$(make_spawn_case profile-unsupported-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness codex --model gpt-5 --effort max \
    --captain-override "captain requested an unsupported proof")
  status=$?
  expect_code 1 "$status" "an unsupported class override should fail"
  assert_contains "$out" "unsupported effort 'max' for captain override for class 'builder' harness 'codex'" \
    "class override refusal did not name the unsupported runtime"
  assert_contains "$out" "supported efforts: low, medium, high, xhigh, or omit effort" \
    "class override refusal did not list the supported correction"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported class override typed a launch command"
  assert_absent "$HOME_DIR/state/$id.meta" "unsupported class override wrote metadata"
  pass "class overrides validate runtime support before launch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=$(profile_id profile-claude-z2)
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=$(profile_id profile-codex-z3)
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=$(profile_id profile-codex-max-z4)
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=$(profile_id profile-grok-z5)
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=$(profile_id profile-grok-max-z6)
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=$(profile_id profile-grok-xhigh-z6b)
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry trust, autonomy, model, and exact workspace flags"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id=profile-cursor-unsupported-z6d
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id=profile-cursor-catalog-unreachable-z6e
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  FM_TEST_CURSOR_LIST_STATUS=124 \
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=$(profile_id profile-opencode-z7)
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=$(profile_id profile-pi-z8)
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' --no-extensions -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=$(profile_id profile-pi-signed-z8b)
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' --no-extensions -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=$(profile_id profile-pi-signed-missing-z8c)
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_omp_threads_exact_identity_model_and_every_thinking_level() {
  local effort rec id out status launch expected_bin expected_bun
  for effort in low medium high xhigh max; do
    id=$(profile_id "profile-omp-${effort}-z8o")
    rec=$(make_spawn_case "profile-omp-$effort" omp "$id")
    read_case_record "$rec"
    export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model openai-codex/gpt-5.6-sol --effort "$effort")
    status=$?
    expect_code 0 "$status" "OMP spawn with $effort thinking should succeed"
    assert_contains "$out" "spawned $id harness=omp kind=ship" "OMP spawn did not preserve exact identity"
    assert_meta_profile "$HOME_DIR/state/$id.meta" omp openai-codex/gpt-5.6-sol "$effort"
    launch=$(cat "$LAUNCH_LOG")
    expected_bin=$(cd "$FAKEBIN_DIR" && pwd -P)/omp
    expected_bun=$(cd "$FAKEBIN_DIR" && pwd -P)/bun
    assert_contains "$launch" "FM_OMP_HARNESS=omp '$expected_bun' '$expected_bin' --session-dir '/tmp/fm-$id/omp-sessions' --auto-approve --model 'openai-codex/gpt-5.6-sol' --thinking '$effort' -e '$HOME_DIR/state/$id.omp-ext.ts'" \
      "OMP launch did not execute the canonical Bun/OMP pair with unattended mode, model, thinking, and extension"
    assert_grep "omp_bun=$expected_bun" "$HOME_DIR/state/$id.meta" \
      "OMP launch metadata did not bind the same Bun executable used by the literal pane command"
    [ "$(grep -Fo "encode launch-brief" "$LAUNCH_LOG" | wc -l | tr -d ' ')" = 1 ] \
      || fail "OMP launch did not deliver exactly one positional launch brief"
    assert_present "$HOME_DIR/state/$id.omp-ext.ts" "OMP launch did not create the external turn extension"
    unset FM_TEST_OMP_ACK
  done
  pass "OMP launches through its metadata-bound canonical Bun/OMP pair and forwards every supported thinking level"
}

test_omp_herdr_worker_and_scout_launch_with_exact_identity_and_ack() {
  local kind rec id out status launch
  local -a flag
  for kind in worker scout; do
    id=$(profile_id "profile-omp-herdr-$kind-z8ph")
    rec=$(make_spawn_case "profile-omp-herdr-$kind" omp "$id")
    read_case_record "$rec"
    export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
    # A ship worker carries the delivery contract; a scout does not.
    if [ "$kind" = scout ]; then
      flag=(--scout)
    else
      flag=(--mode no-mistakes --yolo off)
    fi

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --backend herdr --model openai-codex/gpt-5.6-sol --effort low "${flag[@]}")
    status=$?
    expect_code 0 "$status" "OMP Herdr $kind launch should succeed after turn-start acknowledgement"
    assert_contains "$out" "spawned $id harness=omp" "OMP Herdr $kind launch lost exact runtime identity"
    assert_grep 'backend=herdr' "$HOME_DIR/state/$id.meta" "OMP Herdr $kind metadata lost its backend"
    assert_grep 'herdr_session=default' "$HOME_DIR/state/$id.meta" "OMP Herdr $kind metadata lost its named session"
    assert_grep 'herdr_pane_id=w1:p2' "$HOME_DIR/state/$id.meta" "OMP Herdr $kind metadata lost its exact pane"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "FM_OMP_HARNESS=omp '$(cd "$FAKEBIN_DIR" && pwd -P)/bun' '$(cd "$FAKEBIN_DIR" && pwd -P)/omp'" \
      "OMP Herdr $kind launch omitted its canonical Bun/OMP execution boundary"
    assert_contains "$launch" "--session-dir '/tmp/fm-$id/omp-sessions'" "OMP Herdr $kind launch omitted its nonempty isolated session directory"
    assert_contains "$launch" "-e '$HOME_DIR/state/$id.omp-ext.ts'" "OMP Herdr $kind launch omitted its acknowledgement extension"
    unset FM_TEST_OMP_ACK
  done
  pass "OMP Herdr workers and scouts preserve exact identity, isolated sessions, metadata, and launch acknowledgement"
}

test_omp_refuses_unverified_backends_before_endpoint_creation() {
  local backend rec id out status endpoint_log
  for backend in zellij orca cmux; do
    id=$(profile_id "profile-omp-unverified-$backend-z8pu")
    rec=$(make_spawn_case "profile-omp-unverified-$backend" omp "$id")
    read_case_record "$rec"
    endpoint_log="$CASE_DIR/endpoint.log"
    : > "$endpoint_log"

    out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --backend "$backend" --mode no-mistakes --yolo off)
    status=$?
    expect_code 1 "$status" "OMP should refuse unverified backend $backend"
    assert_contains "$out" "verified only on backend=tmux or backend=herdr" \
      "OMP $backend refusal did not name the supported backend allowlist"
    assert_absent "$HOME_DIR/state/$id.meta" "OMP $backend refusal wrote task metadata"
    [ ! -s "$endpoint_log" ] || fail "OMP $backend refusal created an endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "OMP $backend refusal typed a launch command"
  done
  pass "OMP refuses every backend outside the verified tmux/herdr allowlist before endpoint creation"
}

test_omp_scout_uses_external_turn_extension() {
  local rec id out status
  id=$(profile_id profile-omp-scout-z8p)
  rec=$(make_spawn_case profile-omp-scout omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "OMP scout spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp kind=scout" "OMP scout did not preserve exact identity"
  assert_grep 'kind=scout' "$HOME_DIR/state/$id.meta" "OMP scout metadata lost delivery semantics"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "OMP scout did not receive the external turn extension"
  rm -f "$HOME_DIR/state/$id.omp-ready" "$HOME_DIR/state/$id.omp-started" "$HOME_DIR/state/$id.turn-ended"
  PLUGIN="$HOME_DIR/state/$id.omp-ext.ts" READY="$HOME_DIR/state/$id.omp-ready" \
    STARTED="$HOME_DIR/state/$id.omp-started" TURNENDED="$HOME_DIR/state/$id.turn-ended" \
    node --input-type=module <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const extension = await import(pathToFileURL(process.env.PLUGIN).href);
extension.default({ on(name, handler) { handlers.set(name, handler); } });
await handlers.get("session_start")?.();
await handlers.get("turn_start")?.();
await handlers.get("turn_end")?.();
for (let i = 0; i < 50 && (!existsSync(process.env.READY) || !existsSync(process.env.STARTED) || !existsSync(process.env.TURNENDED)); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.READY)) throw new Error("OMP session_start did not report readiness");
if (!existsSync(process.env.STARTED)) throw new Error("OMP turn_start did not acknowledge launch");
if (!existsSync(process.env.TURNENDED)) throw new Error("OMP turn_end did not publish completion");
JS
  unset FM_TEST_OMP_ACK
  pass "OMP scouts retain scout semantics and external per-turn notification"
}

test_omp_whitespace_identity_paths_refuse_before_endpoint() {
  local mode rec id out status spaced path
  for mode in omp bun; do
    id=$(profile_id "omp-space-$mode")
    rec=$(make_spawn_case "omp-space-$mode" omp "$id")
    read_case_record "$rec"
    spaced="$CASE_DIR/$mode identity"
    mkdir -p "$spaced"
    cp "$FAKEBIN_DIR/$mode" "$spaced/$mode"
    chmod +x "$spaced/$mode"
    path="$spaced:$FAKEBIN_DIR"

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$path" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 1 "$status" "OMP should refuse a whitespace-bearing $mode identity"
    assert_contains "$out" 'canonical executable paths without whitespace' \
      "OMP whitespace-bearing $mode refusal was not actionable"
    [ ! -s "$CASE_DIR/endpoint.log" ] || fail "OMP whitespace-bearing $mode identity created an endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "OMP whitespace-bearing $mode identity typed a launch command"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "OMP whitespace-bearing $mode identity published metadata"
  done
  pass "OMP and Bun whitespace-bearing identity paths refuse before endpoint creation"
}

test_omp_missing_binary_or_capability_refuses_before_endpoint_and_metadata() {
  local mode rec id out status endpoint_log
  for mode in missing-binary missing-thinking existing-artifact; do
    id=$(profile_id "profile-omp-$mode-z8q")
    rec=$(make_spawn_case "profile-omp-$mode" omp "$id")
    read_case_record "$rec"
    endpoint_log="$CASE_DIR/endpoint.log"
    : > "$endpoint_log"
    case "$mode" in
      missing-binary) rm -f "$FAKEBIN_DIR/omp" ;;
      missing-thinking)
        grep -v 'thinking' "$FAKEBIN_DIR/omp" > "$FAKEBIN_DIR/omp.tmp"
        mv "$FAKEBIN_DIR/omp.tmp" "$FAKEBIN_DIR/omp"
        chmod +x "$FAKEBIN_DIR/omp"
        ;;
      existing-artifact) : > "$HOME_DIR/state/$id.status" ;;
    esac

    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_ENDPOINT_LOG="$endpoint_log" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
      "$SPAWN" "$id" "$PROJ_DIR" --harness omp --mode no-mistakes --yolo off 2>&1)
    status=$?
    expect_code 1 "$status" "OMP $mode should refuse before launch"
    assert_contains "$out" "omp" "OMP preflight refusal did not name the selected runtime"
    assert_absent "$HOME_DIR/state/$id.meta" "OMP $mode refusal wrote task metadata"
    [ ! -s "$endpoint_log" ] || fail "OMP $mode refusal created a backend endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "OMP $mode refusal typed a launch command"
  done
  pass "OMP missing binary and capability failures occur before endpoint or metadata publication"
}

test_omp_launch_requires_observable_turn_start_acknowledgement() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-unacked-z8r)
  rec=$(make_spawn_case profile-omp-unacked omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "unacknowledged OMP launch should fail"
  assert_contains "$out" "initial instruction was not acknowledged" \
    "OMP unacknowledged launch did not report its concrete postcondition"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_grep 'kill-window' "$endpointlog" "OMP unacknowledged launch left its owned endpoint alive"
  assert_grep "return --force $WT_DIR" "$treehouselog" "OMP unacknowledged launch did not return its unchanged worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "OMP unacknowledged launch left owned metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "OMP unacknowledged launch left its extension"
  assert_absent "/tmp/fm-$id" "OMP unacknowledged launch left its task temp root"
  pass "OMP spawn requires the initial turn-start acknowledgement and cleans its unchanged launch"
}

test_omp_herdr_unacked_launch_cleans_owned_endpoint_worktree_and_artifacts() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-herdr-unacked-z8rh)
  rec=$(make_spawn_case profile-omp-herdr-unacked omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --backend herdr --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "unacknowledged OMP Herdr launch should fail"
  assert_contains "$out" "initial instruction was not acknowledged" \
    "OMP Herdr unacknowledged launch did not reach the observable acknowledgement gate"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_grep 'pane close w1:p2' "$endpointlog" "OMP Herdr unacknowledged launch left its owned endpoint alive"
  assert_grep "return --force $WT_DIR" "$treehouselog" "OMP Herdr unacknowledged launch did not return its unchanged worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "OMP Herdr unacknowledged launch left owned metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "OMP Herdr unacknowledged launch left its extension"
  assert_absent "/tmp/fm-$id" "OMP Herdr unacknowledged launch left its task temp root"
  pass "OMP Herdr spawn failure cleans its proven endpoint, unchanged worktree, and task artifacts"
}

test_omp_herdr_refused_close_preserves_worktree_and_artifacts() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-herdr-refused-z8rr)
  rec=$(make_spawn_case profile-omp-herdr-refused omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    FM_TEST_HERDR_REFUSE_CLOSE=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --backend herdr --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "unacknowledged OMP Herdr launch should fail"
  assert_contains "$out" "could not confirm its owned endpoint stopped" \
    "OMP Herdr cleanup trusted a refused pane close as a stopped endpoint"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_grep 'pane close w1:p2' "$endpointlog" "OMP Herdr cleanup never attempted its owned close"
  assert_no_grep 'return --force' "$treehouselog" \
    "OMP Herdr cleanup returned the worktree without a confirmed endpoint stop"
  assert_present "$HOME_DIR/state/$id.meta" "OMP Herdr cleanup deleted metadata for a still-live endpoint"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "OMP Herdr cleanup deleted the extension for a still-live endpoint"
  assert_present "/tmp/fm-$id" "OMP Herdr cleanup deleted the task temp root for a still-live endpoint"
  pass "OMP Herdr cleanup preserves the worktree and task artifacts when its close is refused"
}

test_omp_ack_cleanup_preserves_artifacts_when_ownership_changes() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-unacked-owner-z8s)
  rec=$(make_spawn_case profile-omp-unacked-owner omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    FM_TEST_OMP_META_TAMPER="$HOME_DIR/state/$id.meta" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "ownership-changed OMP launch should fail"
  assert_contains "$out" "could not prove ownership" \
    "OMP ownership-changed abort did not explain why cleanup was refused"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_no_grep 'kill-window' "$endpointlog" "OMP abort killed an endpoint after metadata ownership changed"
  assert_no_grep 'return --force' "$treehouselog" "OMP abort returned a worktree after metadata ownership changed"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "OMP abort removed metadata after ownership changed"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = 'window=unrelated:retry' ] \
    || fail "OMP abort did not preserve the intentionally tampered metadata"
  [ -d "/tmp/fm-$id" ] || fail "OMP abort removed task temp after ownership changed"
  [ "$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$id.meta.test-owner")" = "/tmp/fm-$id" ] \
    || fail "the pre-tamper metadata did not prove test ownership of /tmp/fm-$id"
  rm -rf "/tmp/fm-$id"
  pass "OMP spawn abort preserves endpoint, worktree, and artifacts unless ownership is proven"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=$(profile_id profile-pi-signed-secondmate-z8d)
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  assert_not_contains "$launch" "--skill" "secondmate launch received worker skill flags"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_class() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "batch spawn with a shared class should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  assert_meta_dispatch "$HOME_DIR/state/$id1.meta" builder pin
  assert_meta_dispatch "$HOME_DIR/state/$id2.meta" builder pin
  pass "batch dispatch forwards one shared class to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=$(profile_id profile-claude-cfgdir-z17)
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=$(profile_id profile-claude-nocfgdir-z18)
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=$(profile_id profile-codex-nocfgdir-z19)
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=$(profile_id profile-secondmate-z16)
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_claude_loads_concatenated_worker_skill_prompt
test_pi_family_loads_each_worker_skill_directory
test_pi_worker_skill_paths_preserve_ampersands
test_omp_loads_concatenated_worker_skill_prompt
test_omp_without_append_support_uses_worker_skill_brief
test_fallback_harness_gets_worker_skill_brief_prefix
test_task_tmp_uses_private_directories_and_exclusive_files
test_missing_worker_skill_warns_once_and_launches
test_worker_skill_read_failure_warns_once_and_drops_only_failed_skill
test_task_tmp_refusal_precedes_endpoint_and_worktree_allocation
test_task_tmp_stat_failures_report_the_path
test_worker_skill_artifact_creation_failure_precedes_allocation
test_single_skill_prompt_write_failure_is_not_masked
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_class_for_ship
test_active_dispatch_profile_requires_class_for_scout
test_class_resolves_pinned_runtime
test_active_dispatch_profile_refuses_concrete_harness_without_class
test_class_runtime_override_requires_and_records_captain_reason
test_dispatch_metadata_rejects_line_breaks
test_active_dispatch_profile_allows_raw_launch_command
test_raw_override_with_class_requires_provable_runtime
test_default_model_forms_match_through_spawn
test_runtime_whitespace_refuses_before_launch
test_class_override_refuses_unsupported_runtime
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_cursor_threads_model_workspace_and_omits_effort_axis
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_omp_threads_exact_identity_model_and_every_thinking_level
test_omp_herdr_worker_and_scout_launch_with_exact_identity_and_ack
test_omp_refuses_unverified_backends_before_endpoint_creation
test_omp_scout_uses_external_turn_extension
test_omp_whitespace_identity_paths_refuse_before_endpoint
test_omp_missing_binary_or_capability_refuses_before_endpoint_and_metadata
test_omp_launch_requires_observable_turn_start_acknowledgement
test_omp_herdr_unacked_launch_cleans_owned_endpoint_worktree_and_artifacts
test_omp_herdr_refused_close_preserves_worktree_and_artifacts
test_omp_ack_cleanup_preserves_artifacts_when_ownership_changes
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_class
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

test_switched_off_rung_is_refused() {
  local rec id out status
  id=$(profile_id profile-rung-off-refused-z40)
  rec=$(make_spawn_case rung-off-refused claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_switched_off_rung "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness claude --model opus --effort high \
    --captain-override "captain selected the disabled tuple for this proof")
  status=$?
  expect_code 1 "$status" "a spawn naming a switched-off rung should be refused"
  assert_contains "$out" "captain override selects disabled member harness=claude model=opus effort=high" \
    "spawn did not name the disabled member"
  assert_contains "$out" "re-enable it in config/crew-dispatch.json" \
    "spawn did not explain how to re-enable the member"
  assert_absent "$HOME_DIR/state/$id.meta" "switched-off refusal should happen before meta is written"
  pass "a switched-off crew-dispatch rung refuses the spawn"
}

test_enabled_override_precedes_switched_off_pin() {
  local rec id out status
  id=$(profile_id profile-override-pin-off-z40b)
  rec=$(make_spawn_case override-pin-off claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_switched_off_pin "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness grok --model grok-4 --effort high \
    --captain-override "captain selected the enabled member")
  status=$?
  expect_code 0 "$status" "an enabled captain override should precede a switched-off class pin"
  assert_contains "$out" "spawned $id harness=grok" "enabled captain override did not launch"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  assert_meta_dispatch "$HOME_DIR/state/$id.meta" builder pin
  assert_grep "dispatch_override=captain selected the enabled member" "$HOME_DIR/state/$id.meta" \
    "meta missing the captain override reason"
  pass "an enabled captain override precedes a switched-off class pin"
}

test_enabled_sibling_rung_still_spawns() {
  local rec id out status
  id=$(profile_id profile-rung-off-sibling-z41)
  rec=$(make_spawn_case rung-off-sibling claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_switched_off_rung "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "the enabled rung beside a switched-off one should still spawn"
  assert_contains "$out" "spawned $id harness=codex" "enabled sibling rung did not spawn"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "an enabled rung beside a switched-off one still spawns"
}

test_off_ladder_profile_is_not_refused_by_the_switch() {
  local rec id out status
  id=$(profile_id profile-rung-off-ladder-z42)
  rec=$(make_spawn_case rung-off-ladder claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_switched_off_rung "$HOME_DIR"

  # claude/sonnet/high appears nowhere in the file. The switch blocks only rungs
  # the file marks off; an explicit off-ladder profile stays the captain's call.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness claude --model sonnet --effort high \
    --captain-override "captain selected an off-ladder runtime")
  status=$?
  expect_code 0 "$status" "a profile absent from the ladder should not be refused by the switch"
  assert_contains "$out" "spawned $id harness=claude" "off-ladder profile did not spawn"
  pass "the switch refuses only rungs the dispatch file marks off"
}

# The switched-off rung here is claude/opus/high, and this secondmate resolves to
# exactly that tuple. It must still launch: secondmates route through
# config/secondmate-harness, not the crewmate ladders.
test_switched_off_rung_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=$(profile_id profile-rung-off-secondmate-z43)
  rec=$(make_spawn_case rung-off-secondmate claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile_with_switched_off_rung "$HOME_DIR"
  printf '%s\n' 'claude opus high' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "a secondmate launch should be exempt from the rung switch"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" \
    "secondmate launch was blocked by the rung switch"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude opus high
  pass "a switched-off rung does not block a secondmate launch"
}

test_switched_off_rung_is_refused
test_enabled_override_precedes_switched_off_pin
test_enabled_sibling_rung_still_spawns
test_off_ladder_profile_is_not_refused_by_the_switch
test_switched_off_rung_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
