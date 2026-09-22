#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --coding-safety-pilot: the opt-in path that
# launches a claude crewmate through the AOS coding pilot instead of `claude`.
#
# A fake tmux captures the literal launch command sent with `send-keys -l` and
# logs endpoint creation, a fake docker answers the pinned-image probe, and a
# real isolated git worktree stands in for the task. No real harness, container,
# or model call runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-coding-safety-pilot)
RUN_TOKEN="t$$-${RANDOM:-0}"
pilot_id() { printf '%s-%s' "$1" "$RUN_TOKEN"; }
cleanup() {
  local meta tasktmp
  for meta in "$TMP_ROOT"/*/home/state/*.meta; do
    [ -f "$meta" ] || continue
    tasktmp=$(sed -n 's/^tasktmp=//p' "$meta")
    case "$tasktmp" in /tmp/fm-pilot-*) rm -rf "$tasktmp" ;; esac
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -f "$0.windows" ] || cat "$0.windows" ;;
  kill-window) rm -f "$0.windows" ;;
  new-window)
    while [ "$#" -gt 1 ]; do
      [ "$1" != -n ] || { printf '%s\n' "$2" > "$0.windows"; break; }
      shift
    done
    printf 'new-window\n' >> "$FM_FAKE_ENDPOINT_LOG"
    printf '@fake\n' ;;
  send-keys)
    prev=
    for a in "$@"; do
      [ "$prev" != -l ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
      prev=$a
    done ;;
esac
exit 0
SH
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "image inspect "*) [ "${FM_FAKE_DOCKER_IMAGE:-present}" = present ] ;;
  *) exit 0 ;;
esac
SH
  # A stand-in node: a bare entry path is fm-spawn's load probe and answers with
  # the pilot's usage refusal (exit 2) unless the entry is set to fail to load.
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ]; then
  [ "${FM_FAKE_PILOT_LOADS:-yes}" = yes ] || { echo 'coding-pilot: infrastructure failure: runPilot is not a function' >&2; exit 4; }
  echo 'coding-pilot: usage: coding-pilot.mjs run --launch <launch.json> --receipt <absolute receipt path>' >&2
  exit 2
fi
exit "${FM_FAKE_NODE_EXIT:-0}"
SH
  fm_fake_exit0 "$fakebin" treehouse
  chmod +x "$fakebin/tmux" "$fakebin/timeout" "$fakebin/docker" "$fakebin/node"
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id>: a home whose crew harness is claude, a project
# with an isolated worktree, a brief, and a configured trusted pilot entry.
make_case() {
  local name=$1 id=$2 dir
  dir="$TMP_ROOT/$name"
  CASE_HOME="$dir/home"
  CASE_WT="$dir/wt"
  CASE_PROJ="$dir/project"
  CASE_FAKEBIN=$(make_fakebin "$dir/fake")
  CASE_LAUNCH_LOG="$dir/launch.log"
  CASE_ENDPOINT_LOG="$dir/endpoint.log"
  CASE_WORKER_HOME="$dir/worker-home"
  CASE_PILOT="$dir/aos/.claude/sandbox/coding-pilot.mjs"
  mkdir -p "$CASE_HOME/data/$id" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config" \
    "$CASE_WORKER_HOME" "${CASE_PILOT%/*}"
  mkdir -p "$CASE_WORKER_HOME/.agents/skills/caveman" "$CASE_WORKER_HOME/.agents/skills/ponytail"
  printf 'CAVEMAN_FIXTURE_BODY\n' > "$CASE_WORKER_HOME/.agents/skills/caveman/SKILL.md"
  printf 'PONYTAIL_FIXTURE_BODY\n' > "$CASE_WORKER_HOME/.agents/skills/ponytail/SKILL.md"
  printf '// trusted pilot entry fixture\n' > "$CASE_PILOT"
  printf '%s\n' "$CASE_PILOT" > "$CASE_HOME/config/aos-coding-pilot"
  printf 'claude\n' > "$CASE_HOME/config/crew-harness"
  printf 'brief for %s\nDelivery contract: mode=local-only\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  touch "$CASE_HOME/state/.last-watcher-beat"
  : > "$CASE_LAUNCH_LOG"
  : > "$CASE_ENDPOINT_LOG"
}

run_spawn() {
  HOME="$CASE_WORKER_HOME" FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_WT" TMUX="fake,1,0" CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" FM_FAKE_ENDPOINT_LOG="$CASE_ENDPOINT_LOG" \
    FM_FAKE_DOCKER_IMAGE="${FM_TEST_DOCKER_IMAGE:-present}" \
    FM_FAKE_PILOT_LOADS="${FM_TEST_PILOT_LOADS:-yes}" \
    PATH="$CASE_FAKEBIN:$PATH" "$SPAWN" "$@" 2>&1
}

# A refused pilot spawn must start nothing: no endpoint, no launch, no record.
assert_started_nothing() {  # <id> <label>
  assert_no_grep new-window "$CASE_ENDPOINT_LOG" "$2: an endpoint was created"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "$2: a launch command was sent: $(cat "$CASE_LAUNCH_LOG")"
  assert_absent "$CASE_HOME/state/$1.meta" "$2: a task record was written"
}

expect_refusal() {  # <name> <expected-message> <spawn args...>
  local name=$1 msg=$2 id out status
  shift 2
  id=$(pilot_id "pilot-$name")
  make_case "$name" "$id"
  [ "${FM_TEST_NO_ENTRY:-0}" != 1 ] || rm -f "$CASE_HOME/config/aos-coding-pilot"
  out=$(run_spawn "$id" "$CASE_PROJ" --mode local-only --yolo off "$@")
  status=$?
  [ "$status" -ne 0 ] || fail "$name: spawn should refuse; output: $out"
  assert_contains "$out" "$msg" "$name: refusal did not explain itself"
  assert_started_nothing "$id" "$name"
  pass "refuses and starts nothing: $name"
}

test_ordinary_claude_launch_is_unchanged() {
  local id out status tasktmp prompt expected launch
  id=$(pilot_id pilot-ordinary)
  make_case ordinary "$id"
  out=$(run_spawn "$id" "$CASE_PROJ" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "ordinary claude spawn should succeed: $out"
  tasktmp=$(sed -n 's/^tasktmp=//p' "$CASE_HOME/state/$id.meta")
  prompt=$(printf '%s\n' "$tasktmp"/worker-skills.????????)
  # The exact bytes main produced before the pilot existed
  # (tests/fm-spawn-dispatch-profile.test.sh pins the same command).
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --append-system-prompt-file '$prompt' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$CASE_HOME/data/$id/brief.md')\""
  launch=$(grep -v '^export ' "$CASE_LAUNCH_LOG")
  [ "$launch" = "$expected" ] || fail "ordinary claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  ! grep -Eq '^(coding_safety_pilot|sensitivity|pilot_[a-z_]*)=' "$CASE_HOME/state/$id.meta" \
    || fail "ordinary spawn recorded pilot fields"
  assert_absent "$CASE_HOME/state/$id.pilot" "ordinary spawn built a pilot input set"
  pass "ordinary claude launch is byte-for-byte unchanged"
}

test_pilot_spawn_launches_the_pilot_and_records_it() {
  local id out status meta pdir launch_json receipt exitfile launch expected encoded
  id=$(pilot_id pilot-ok)
  make_case ok "$id"
  out=$(run_spawn "$id" "$CASE_PROJ" --mode local-only --yolo off \
    --coding-safety-pilot --sensitivity confidential --pilot-verify 'npm  test')
  status=$?
  expect_code 0 "$status" "pilot spawn should succeed: $out"
  meta="$CASE_HOME/state/$id.meta"
  pdir="$CASE_HOME/state/$id.pilot"
  assert_grep 'coding_safety_pilot=1' "$meta" "meta missing coding_safety_pilot=1"
  assert_grep 'sensitivity=confidential' "$meta" "meta missing sensitivity"
  assert_grep 'harness=claude' "$meta" "meta missing harness=claude"
  launch_json=$(sed -n 's/^pilot_launch=//p' "$meta")
  receipt=$(sed -n 's/^pilot_receipt=//p' "$meta")
  exitfile=$(sed -n 's/^pilot_exit_file=//p' "$meta")
  case "$launch_json:$receipt:$exitfile" in
    "$pdir"/launch-*.json:"$pdir"/receipt-*.json:"$pdir"/receipt-*.json.exit) ;;
    *) fail "pilot paths not recorded under $pdir: $launch_json $receipt $exitfile" ;;
  esac
  [ "$exitfile" = "$receipt.exit" ] || fail "exit file is not beside the receipt"
  assert_absent "$receipt" "spawn must leave the receipt path new for the pilot"

  launch=$(grep -v '^export ' "$CASE_LAUNCH_LOG")
  expected="'$CASE_FAKEBIN/node' '$CASE_PILOT' run --launch '$launch_json' --receipt '$receipt'; printf '%s\n' \"\$?\" > '$exitfile'"
  [ "$launch" = "$expected" ] || fail "pilot launch command wrong"$'\n'"expected: $expected"$'\n'"actual:   $launch"

  jq -e --arg id "$id" --arg src "$(git -C "$CASE_WT" rev-parse HEAD)" \
    --arg input "$pdir/input" --arg brief "$pdir/brief.md" '
      .schemaVersion == 1 and .taskId == $id and (.runId | startswith($id + "-"))
      and (.runId | test("^[a-z0-9][a-z0-9-]{0,47}$")) and .sourceCommit == $src
      and (.launcherCommit == null or (.launcherCommit | test("^[0-9a-f]{40}$")))
      and .harness == "claude" and .routeId == "claude-subscription-interim"
      and .sensitivity == "confidential" and .inputSetHash == null and .policyHash == null
      and .routeEvidenceHash == null and .imageDigest == null
      and .run.inputDir == $input and .run.briefPath == $brief
      and .run.model == "claude-opus-5-5" and .run.mode == "interactive"
      and .run.maxTurns == 50 and .run.wallClockMs == 1800000
      and .run.verifyCommand == ["npm", "test"]' "$launch_json" >/dev/null \
    || fail "launch record does not match the pilot schema: $(cat "$launch_json")"
  assert_present "$pdir/input/README.md" "input set missing the tracked file"
  assert_absent "$pdir/input/.git" "input set carries git internals"
  encoded=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$CASE_HOME/data/$id/brief.md")
  [ "$(cat "$pdir/brief.md")" = "$encoded" ] || fail "pilot brief is not the encoded task brief"

  # Run the pane command with the stand-in node exiting like a cancelled pilot:
  # the pilot's own exit code must land in the recorded exit file.
  FM_FAKE_NODE_EXIT=3 bash -c "$launch"
  [ "$(cat "$exitfile")" = 3 ] || fail "pilot exit code not recorded: $(cat "$exitfile" 2>&1)"
  pass "pilot spawn launches the pilot, builds the launch record, and records exit and receipt paths"
}

test_pilot_spawn_passes_an_admitted_model() {
  local id out status launch_json pinned
  id=$(pilot_id pilot-model)
  make_case model "$id"
  # A second config line pins the Node the trusted AOS checkout supports.
  pinned="$TMP_ROOT/model/pinned-node/node"
  mkdir -p "${pinned%/*}"
  cp "$CASE_FAKEBIN/node" "$pinned"
  printf '%s\n' "$pinned" >> "$CASE_HOME/config/aos-coding-pilot"
  out=$(run_spawn "$id" "$CASE_PROJ" --mode local-only --yolo off --model claude-sonnet-5 \
    --coding-safety-pilot --sensitivity internal --pilot-verify true)
  status=$?
  expect_code 0 "$status" "pilot spawn with an admitted model should succeed: $out"
  launch_json=$(sed -n 's/^pilot_launch=//p' "$CASE_HOME/state/$id.meta")
  [ "$(jq -r .run.model "$launch_json")" = claude-sonnet-5 ] || fail "admitted model not passed to the pilot"
  case "$(grep -v '^export ' "$CASE_LAUNCH_LOG")" in
    "'$pinned' '$CASE_PILOT' run "*) ;;
    *) fail "pinned node not used for the pilot launch: $(cat "$CASE_LAUNCH_LOG")" ;;
  esac
  pass "pilot spawn passes an admitted --model and runs the pinned node"
}

# A resumed pilot task must never fall back to an ordinary host launch.
test_relaunch_refuses_pilot_tasks() {
  local id out status
  id=$(pilot_id pilot-relaunch)
  make_case relaunch "$id"
  out=$(run_spawn "$id" --relaunch --coding-safety-pilot)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch with --coding-safety-pilot should refuse"
  assert_contains "$out" "--relaunch cannot start a coding-safety pilot task" "relaunch flag refusal unclear"
  fm_write_meta "$CASE_HOME/state/$id.meta" "window=firstmate:fm-$id" "worktree=$CASE_WT" \
    "project=$CASE_PROJ" harness=claude kind=ship mode=local-only yolo=off coding_safety_pilot=1
  out=$(run_spawn "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch of a recorded pilot task should refuse"
  assert_contains "$out" "--relaunch cannot start a coding-safety pilot task" "recorded pilot relaunch refusal unclear"
  assert_no_grep new-window "$CASE_ENDPOINT_LOG" "relaunch refusal created an endpoint"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "relaunch refusal sent a launch command"
  pass "relaunch refuses a coding-safety pilot task rather than launching it on the host"
}

test_ordinary_claude_launch_is_unchanged
test_relaunch_refuses_pilot_tasks
test_pilot_spawn_launches_the_pilot_and_records_it
test_pilot_spawn_passes_an_admitted_model
expect_refusal harness-codex "coding-safety pilot runs only the claude harness" \
  --harness codex --coding-safety-pilot --sensitivity internal --pilot-verify true
expect_refusal raw-launch "coding-safety pilot runs only the claude harness" \
  --coding-safety-pilot --sensitivity internal --pilot-verify true 'claude --print hi'
FM_TEST_DOCKER_IMAGE=absent expect_refusal image-missing "runtime-unavailable" \
  --coding-safety-pilot --sensitivity internal --pilot-verify true
expect_refusal no-sensitivity "--coding-safety-pilot requires --sensitivity" \
  --coding-safety-pilot --pilot-verify true
expect_refusal bad-sensitivity "--sensitivity must be one of public, internal, confidential, restricted" \
  --coding-safety-pilot --sensitivity secret --pilot-verify true
expect_refusal no-verify "--coding-safety-pilot requires --pilot-verify" \
  --coding-safety-pilot --sensitivity internal
expect_refusal model-not-admitted "is not admitted by the coding-safety pilot" \
  --model claude-opus-5 --coding-safety-pilot --sensitivity internal --pilot-verify true
expect_refusal flags-without-pilot "--sensitivity and --pilot-verify apply only with --coding-safety-pilot" \
  --sensitivity internal
# The pilot's runId is "<task-id>-<epoch>" and must fit 48 characters.
expect_refusal id-too-long-for-a-pilot-run-id "invalid launch record" \
  --coding-safety-pilot --sensitivity internal --pilot-verify true
FM_TEST_NO_ENTRY=1 expect_refusal no-entry "config/aos-coding-pilot" \
  --coding-safety-pilot --sensitivity internal --pilot-verify true
FM_TEST_PILOT_LOADS=no expect_refusal no-load "runtime-unavailable: the pilot entry does not load" \
  --coding-safety-pilot --sensitivity internal --pilot-verify true
