#!/usr/bin/env bash
# tests/fm-api-reads.test.sh - captain queue, blocked list, and rig read windows.
#
# Speaks real HTTP against a throwaway firstmate home. Does not read the live
# home and does not inspect server source.
set -u

# shellcheck source=tests/api-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/api-helpers.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
node -e 'process.stdout.write("fm-api-node-ok")' >/dev/null 2>&1 \
  || { echo "skip: node is not a usable Node.js"; exit 0; }

split_http() {
  HTTP_CODE=
  HTTP_BODY=
  IFS= read -r HTTP_CODE || true
  HTTP_BODY=$(cat)
}

write_status() {
  local home=$1 id=$2
  shift 2
  printf '%s\n' "$@" > "$home/state/${id}.status"
}

test_empty_home_queue_is_empty() {
  local home port resp
  home=$(fm_test_api_home api-queue-empty)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "empty queue status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = true ] || fail "empty queue missing ok: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions.length')" = 0 ] || \
    fail "empty home queue was not empty: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "empty home captain queue is an empty list"
}

test_captain_queue_returns_parked_decisions() {
  local home port resp summary
  home=$(fm_test_api_home api-queue)
  write_status "$home" ask-me \
    'needs-decision [key=api-shape]: which JSON shape should the queue use?' \
    'working: still drafting the other ticket'
  write_status "$home" other \
    'working: no decision here'
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "queue status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions.length')" = 1 ] || \
    fail "wanted 1 parked decision: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions[0].task')" = ask-me ] || \
    fail "queue task: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions[0].key')" = api-shape ] || \
    fail "queue key: $HTTP_BODY"
  summary=$(fm_test_json "$HTTP_BODY" 'd.decisions[0].summary')
  assert_contains "$summary" "which JSON shape should the queue use" "queue summary: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "captain queue returns the fixture parked decision and ignores a later working line"
}

test_resolved_decision_leaves_the_queue() {
  local home port resp
  home=$(fm_test_api_home api-queue-resolved)
  write_status "$home" ask-me \
    'needs-decision [key=api-shape]: which JSON shape?' \
    'resolved [key=api-shape]: use the glossary words'
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "resolved queue status $HTTP_CODE: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions.length')" = 0 ] || \
    fail "resolved decision stayed in the queue: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "a resolved parked decision does not appear in the captain queue"
}

test_empty_home_blocked_is_empty() {
  local home port resp
  home=$(fm_test_api_home api-blocked-empty)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /blocked)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "empty blocked status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = true ] || fail "empty blocked missing ok: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.blocked.length')" = 0 ] || \
    fail "empty home blocked list was not empty: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "empty home blocked list is an empty list"
}

test_blocked_list_returns_blocked_tasks() {
  local home port resp summary
  home=$(fm_test_api_home api-blocked)
  write_status "$home" stuck-task \
    'blocked [key=missing-tool]: jq is not installed'
  write_status "$home" ask-me \
    'needs-decision [key=api-shape]: which JSON shape?'
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /blocked)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "blocked status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.blocked.length')" = 1 ] || \
    fail "wanted 1 blocked task: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.blocked[0].task')" = stuck-task ] || \
    fail "blocked task: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.blocked[0].key')" = missing-tool ] || \
    fail "blocked key: $HTTP_BODY"
  summary=$(fm_test_json "$HTTP_BODY" 'd.blocked[0].summary')
  assert_contains "$summary" "jq is not installed" "blocked summary: $HTTP_BODY"
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions.length')" = 1 ] || \
    fail "parked decision missing from queue while blocked was listed: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.decisions[0].task')" = ask-me ] || \
    fail "queue mixed in the blocked task: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "blocked list returns the fixture blocked task and not the parked decision"
}

test_empty_home_rigs_is_empty() {
  local home port resp
  home=$(fm_test_api_home api-rigs-empty)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "empty rigs status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = true ] || fail "empty rigs missing ok: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs.length')" = 0 ] || \
    fail "empty home rigs was not empty: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "empty home rigs is an empty list"
}

test_rigs_returns_pools_and_rung_enabled_state() {
  local home port resp
  home=$(fm_test_api_home api-rigs)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {
      "when": "The task is a builder assignment.",
      "use": [
        { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" },
        { "harness": "grok", "model": "grok-4", "effort": "high", "enabled": false }
      ]
    }
  ],
  "default": [
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "rigs status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs.length')" = 2 ] || fail "wanted 2 rigs: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].name')" = "The task is a builder assignment." ] || \
    fail "first rig name: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs.length')" = 2 ] || \
    fail "first rig rung count: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs[0].harness')" = codex ] || \
    fail "first rung harness: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs[0].model')" = gpt-5.6-sol ] || \
    fail "first rung model: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs[0].effort')" = high ] || \
    fail "first rung effort: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs[0].enabled')" = true ] || \
    fail "omitted enabled should be on: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs[1].harness')" = grok ] || \
    fail "second rung harness: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].rungs[1].enabled')" = false ] || \
    fail "switched-off rung should be off: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[1].name')" = default ] || \
    fail "default rig name: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[1].rungs[0].harness')" = pi ] || \
    fail "default rung harness: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[1].rungs[0].enabled')" = true ] || \
    fail "default rung should be on: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "rigs returns pools, rungs, and each rung's enabled state"
}

test_rigs_returns_note_pins_and_harness_pins() {
  local home port resp
  home=$(fm_test_api_home api-rigs-extras)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "note": "FLOOR RULE: nothing drops below Grok. codex gpt-5.6-sol is capped until 2026-09-01.",
  "rules": [
    {
      "when": "The task is a builder assignment.",
      "use": [
        { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" }
      ],
      "pin": { "harness": "claude", "model": "claude-opus-4-8", "effort": "high" }
    }
  ],
  "default": [
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" }
  ],
  "defaultPin": { "harness": "pi", "model": "xai/grok-4.6" }
}
EOF
  printf 'pi\n' > "$home/config/crew-harness"
  printf '# pinned by hand\nclaude opus high\n' > "$home/config/secondmate-harness"
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "rigs extras status $HTTP_CODE, wanted 200: $HTTP_BODY"
  assert_contains "$(fm_test_json "$HTTP_BODY" 'd.note')" "FLOOR RULE" "rigs note: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].pin.harness')" = claude ] || \
    fail "rig pin harness: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].pin.model')" = claude-opus-4-8 ] || \
    fail "rig pin model: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].pin.enabled')" = true ] || \
    fail "rig pin enabled default: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.defaultPin.harness')" = pi ] || \
    fail "default pin harness: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.crew')" = pi ] || fail "crew pin line: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.secondmate')" = "claude opus high" ] || \
    fail "secondmate pin line skipped the comment: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "rigs carries the dispatch note, rig pins, and the crew and secondmate pin lines"
}

test_rigs_extras_default_to_empty_when_absent() {
  local home port resp
  home=$(fm_test_api_home api-rigs-extras-absent)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {
      "when": "The task is a builder assignment.",
      "use": [ { "harness": "codex", "model": "gpt-5.6-sol" } ]
    }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "rigs absent-extras status $HTTP_CODE: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.note === ""')" = true ] || \
    fail "absent note should be empty: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].pin === null')" = true ] || \
    fail "absent rig pin should be null: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.defaultPin === null')" = true ] || \
    fail "absent default pin should be null: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.crew === ""')" = true ] || \
    fail "absent crew pin should be empty: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.secondmate === ""')" = true ] || \
    fail "absent secondmate pin should be empty: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "rigs extras default to empty values when the config files are absent"
}

make_fake_tasks_axi() {  # <dir> <expected-file>
  local fakebin=$1 expected=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
[ -z "\${TASKS_AXI_FILE:-}" ] || exit 1
file=
args=()
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --file ]; then
    file=\$2
    shift 2
    continue
  fi
  args+=("\$1")
  shift
done
[ "\$file" = $(printf '%q' "$expected") ] || exit 1
set -- "\${args[@]}"
if [ "\${1:-}" = list ]; then
  # Two-space indented CSV rows, the shape parseCaptainIdList reads.
  printf '%s\n' '  ready-decision-key-a,captain,queued'
  printf '%s\n' '  blocked-hold,captain,queued'
  printf '%s\n' '  done-hold,captain,done'
  exit 0
fi
if [ "\${1:-}" = show ]; then
  case "\$2" in
    ready-decision-key-a)
      cat <<'EOF'
task:
  id: ready-decision-key-a
  title: "Pick the memory path"
  state: queued
  blocked: no
  blocked_by: none
  hold_reason: "Captain must choose"
  hold_kind: captain
  repo: firstmate
  created: 2026-08-20
EOF
      ;;
    blocked-hold)
      cat <<'EOF'
task:
  id: blocked-hold
  title: "Waits on another task"
  state: queued
  blocked: yes
  blocked_by: other-task
  hold_reason: "Blocked"
  hold_kind: captain
  repo: aos
  created: 2026-08-19
EOF
      ;;
    done-hold)
      cat <<'EOF'
task:
  id: done-hold
  title: "Already answered"
  state: done
  blocked: no
  blocked_by: none
  hold_kind: captain
  repo: firstmate
  created: 2026-08-18
EOF
      ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
}

test_captain_holds_returns_open_holds_actionable_first() {
  local home port resp fakebin
  home=$(fm_test_api_home api-holds)
  fakebin="$home/fakebin"
  : > "$home/data/backlog.md"
  make_fake_tasks_axi "$fakebin" "$(cd "$home" && pwd)/data/backlog.md"
  port=$(TASKS_AXI_FILE="$home/other-backlog.md" PATH="$fakebin:$PATH" fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-holds GET 8000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "holds status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = true ] || fail "holds missing ok: $HTTP_BODY"
  # done-hold is dropped; the two open holds remain.
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds.length')" = 2 ] || fail "wanted 2 open holds: $HTTP_BODY"
  # actionable (nothing blocking) sorts before blocked.
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[0].id')" = ready-decision-key-a ] || \
    fail "actionable hold should sort first: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[0].actionable')" = true ] || \
    fail "first hold actionable: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[0].answerable')" = true ] || \
    fail "a -decision- id is answerable: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[0].repo')" = firstmate ] || fail "hold repo: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[1].id')" = blocked-hold ] || \
    fail "blocked hold sorts last: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[1].actionable')" = false ] || \
    fail "blocked hold not actionable: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[1].answerable')" = false ] || \
    fail "a plain captain task is not answerable: $HTTP_BODY"
  assert_contains "$(fm_test_json "$HTTP_BODY" 'd.holds[1].blockedBy')" "other-task" \
    "blocked hold carries its blocker: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "captain holds returns open holds, actionable first, done dropped"
}

test_captain_holds_empty_without_tasks_axi() {
  local home port resp fakebin
  home=$(fm_test_api_home api-holds-empty)
  # tasks-axi that always fails, standing in for one that is not installed: the
  # endpoint answers empty, not an error. node stays on PATH so the server runs.
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/tasks-axi"
  port=$(PATH="$fakebin:$PATH" fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-holds GET 8000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "empty holds status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds.length')" = 0 ] || \
    fail "no tasks-axi should give empty holds: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "captain holds is empty, not an error, when tasks-axi is absent"
}

test_empty_home_queue_is_empty
test_captain_queue_returns_parked_decisions
test_resolved_decision_leaves_the_queue
test_empty_home_blocked_is_empty
test_blocked_list_returns_blocked_tasks
test_empty_home_rigs_is_empty
test_rigs_returns_pools_and_rung_enabled_state
test_rigs_returns_note_pins_and_harness_pins
test_rigs_extras_default_to_empty_when_absent
test_captain_holds_returns_open_holds_actionable_first
test_captain_holds_empty_without_tasks_axi

echo "# fm-api-reads.test.sh: all assertions passed"
