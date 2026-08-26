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

test_empty_home_queue_is_empty
test_captain_queue_returns_parked_decisions
test_resolved_decision_leaves_the_queue
test_empty_home_blocked_is_empty
test_blocked_list_returns_blocked_tasks
test_empty_home_rigs_is_empty
test_rigs_returns_pools_and_rung_enabled_state

echo "# fm-api-reads.test.sh: all assertions passed"
