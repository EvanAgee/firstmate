#!/usr/bin/env bash
# tests/fm-api-reads.test.sh - captain queue cards, blocked list, and rig read windows.
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

write_queue() {
  local home=$1
  cat > "$home/data/captain-queue.json"
}

test_empty_home_queue_is_empty() {
  local home port resp
  home=$(fm_test_api_home api-queue-empty)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "empty queue status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = true ] || fail "empty queue missing ok: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 0 ] || \
    fail "empty home queue was not empty: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "empty home captain queue is an empty list"
}

test_captain_queue_ignores_worker_needs_decision() {
  local home port resp
  home=$(fm_test_api_home api-queue-worker)
  write_status "$home" ask-me \
    'needs-decision [key=nm-custody-wedge]: retry the pipeline?' \
    'working: still drafting the other ticket'
  write_status "$home" other \
    'needs-decision [key=real-money-live-run]: approve the live run?'
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "queue status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 0 ] || \
    fail "worker needs-decision leaked onto the captain queue: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "an ordinary worker needs-decision does not appear on the captain queue"
}

test_captain_queue_serves_open_named_cards() {
  local home port resp
  home=$(fm_test_api_home api-queue-card)
  write_status "$home" ask-me \
    'needs-decision [key=nm-custody-wedge]: retry the pipeline?'
  write_queue "$home" <<'EOF'
{
  "updated_at": "2026-08-27T16:00:00Z",
  "items": [
    {
      "id": "fm-memory-path",
      "num": 3,
      "question": "Keep trimming memory, or adopt a vault?",
      "context": "The research recommends staying with trim.",
      "commands": [],
      "options": [
        "Stay with trim (recommended)",
        "Adopt a vault",
        "Something else"
      ],
      "asked_at": "2026-08-26T20:45:00Z",
      "status": "open",
      "project": "firstmate"
    },
    {
      "id": "already-done",
      "num": 1,
      "question": "Already answered",
      "options": ["Yes, ship it (recommended)", "Hold"],
      "status": "resolved",
      "project": "firstmate"
    }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "queue status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 1 ] || \
    fail "wanted 1 open card and no worker leak: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].id')" = fm-memory-path ] || \
    fail "queue id: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].options.length')" = 3 ] || \
    fail "queue options: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].options[0]')" = "Stay with trim (recommended)" ] || \
    fail "recommended option was not first: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].recommended')" = "Stay with trim (recommended)" ] || \
    fail "recommended field: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.updatedAt')" = "2026-08-27T16:00:00Z" ] || \
    fail "updatedAt: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "captain queue serves an open named card and hides a resolved one"
}

test_captain_queue_serves_parked_cards_separately() {
  local home port resp
  home=$(fm_test_api_home api-queue-parked)
  write_queue "$home" <<'EOF'
{
  "updated_at": "2026-08-31T18:00:00Z",
  "items": [
    {
      "id": "active-choice",
      "question": "Keep waiting?",
      "options": ["Keep waiting (recommended)", "Stop"],
      "status": "open"
    }
  ],
  "resolved": [],
  "parked": [
    {
      "id": "expired-choice",
      "num": 4,
      "question": "Approve the old release?",
      "context": "No backlog item tracked this question.",
      "commands": ["deploy-old"],
      "options": ["Approve (recommended)", "Decline"],
      "asked_at": "2026-08-20T18:00:00Z",
      "status": "parked",
      "project": "sample",
      "parked_at": "2026-08-27T18:00:00Z",
      "parked_reason": "expired-unbacked",
      "parked_note": "Expired after 7 days without a backing backlog item"
    }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "parked queue status $HTTP_CODE: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 1 ] \
    || fail "active captain queue changed when parked cards were present: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.parked.length')" = 1 ] \
    || fail "parked captain card was not exposed separately: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.parked[0].id')" = expired-choice ] \
    || fail "parked captain card id missing: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.parked[0].status')" = parked ] \
    || fail "parked captain card status missing: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.parked[0].parkedReason')" = expired-unbacked ] \
    || fail "parked captain card reason missing: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.parked[0].parkedNote')" = "Expired after 7 days without a backing backlog item" ] \
    || fail "parked captain card note missing: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "captain queue serves parked cards separately from active cards"
}

test_captain_queue_rejects_bad_options() {
  local home port resp
  home=$(fm_test_api_home api-queue-bad-options)
  write_queue "$home" <<'EOF'
{
  "items": [
    {
      "id": "generic-letters",
      "question": "Pick a path",
      "options": ["A", "B", "C"],
      "status": "open"
    },
    {
      "id": "letter-prefix",
      "question": "Approve the live run?",
      "options": ["A - approve the real run", "B - use the fake proof"],
      "status": "open"
    },
    {
      "id": "option-letter-prefix",
      "question": "Keep the current memory plan?",
      "options": ["Option A - stay with trim (recommended)", "Option B - adopt a vault"],
      "status": "open"
    },
    {
      "id": "lowercase-letter-prefix",
      "question": "Keep the current memory plan?",
      "options": ["a - stay with trim (recommended)", "b - adopt a vault"],
      "status": "open"
    },
    {
      "id": "unmarked",
      "question": "Keep the current memory plan?",
      "options": ["Adopt a vault", "Stay with trim", "Something else"],
      "status": "open"
    },
    {
      "id": "jargon",
      "question": "Retry the wedge?",
      "options": ["[key=nm-custody-wedge] retry", "keep going"],
      "status": "open"
    },
    {
      "id": "empty-options",
      "question": "No choices",
      "options": [],
      "status": "open"
    },
    {
      "id": "good-card",
      "question": "Push the dashboard live?",
      "options": ["Push it live (recommended)", "Let me look first", "Something else"],
      "status": "open",
      "project": "agee-dev-dashboard"
    }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "bad-options status $HTTP_CODE: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 1 ] || \
    fail "bad option cards should be dropped, one good card kept: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].id')" = good-card ] || \
    fail "the surviving card should be the named one: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "cards with empty, generic-letter, unmarked, or jargon options are rejected"
}

test_captain_queue_moves_recommended_first() {
  local home port resp
  home=$(fm_test_api_home api-queue-recommended)
  write_queue "$home" <<'EOF'
{
  "items": [
    {
      "id": "reorder-me",
      "question": "Keep the current memory plan?",
      "options": ["Adopt a vault", "Stay with trim (recommended)", "Something else"],
      "status": "open"
    }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "reorder status $HTTP_CODE: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].options[0]')" = "Stay with trim (recommended)" ] || \
    fail "recommended option should be moved first: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].options[2]')" = "Something else" ] || \
    fail "Something else should stay last: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "the recommended option is marked and comes first"
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
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 0 ] || \
    fail "a worker needs-decision leaked onto the captain queue: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "blocked list returns the fixture blocked task and not a worker decision"
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
      "class": "builder",
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
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[0].class')" = builder ] || \
    fail "first rig class: $HTTP_BODY"
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
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs[1].class')" = __default__ ] || \
    fail "default rig class: $HTTP_BODY"
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
      "class": "builder",
      "when": "The task is a builder assignment.",
      "use": [
        { "harness": "claude", "model": "claude-opus-4-8", "effort": "high" },
        { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" }
      ],
      "pin": { "harness": "claude", "model": "claude-opus-4-8", "effort": "high" }
    }
  ],
  "default": [
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" }
  ],
  "defaultPin": { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" }
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
      "class": "builder",
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

test_rigs_refuses_a_symlinked_config() {
  local home port resp
  home=$(fm_test_api_home api-rigs-symlink)
  # A crew-dispatch.json that is a symlink is refused, not followed: the answer
  # is the same empty response a missing file gives.
  printf '{"note":"secret","rules":[]}\n' > "$home/elsewhere.json"
  ln -s "$home/elsewhere.json" "$home/config/crew-dispatch.json"
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "symlinked rigs status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.note === ""')" = true ] || \
    fail "symlinked config note should be empty, not read: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.rigs.length')" = 0 ] || \
    fail "symlinked config should give no rigs: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "a symlinked crew-dispatch.json is refused, not read"
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
  printf '%s\n' '  parked-decision-key-b,captain,queued'
  printf '%s\n' '  future-decision-key-c,captain,queued'
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
    parked-decision-key-b)
      cat <<'EOF'
task:
  id: parked-decision-key-b
  title: "Revisit the parked choice"
  state: queued
  blocked: no
  blocked_by: none
  held: yes
  hold_reason: "2026-08-20: Captain deferred"
  hold_kind: parked
  repo: firstmate
  created: 2026-08-21
EOF
      ;;
    future-decision-key-c)
      cat <<'EOF'
task:
  id: future-decision-key-c
  title: "Revisit the dated choice"
  state: queued
  blocked: no
  blocked_by: none
  held: yes
  hold_reason: "2026-08-20: Captain deferred until review"
  hold_kind: future
  hold_until: 2099-12-31
  repo: firstmate
  created: 2026-08-22
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
  # done-hold is dropped; the four open holds remain.
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds.length')" = 4 ] || fail "wanted 4 open holds: $HTTP_BODY"
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
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[2].id')" = parked-decision-key-b ] || \
    fail "parked hold missing from the response: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[2].hold_kind')" = parked ] || \
    fail "parked hold kind missing from the response: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[2].actionable')" = false ] || \
    fail "parked hold remained actionable: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[2].parked')" = true ] || \
    fail "parked hold was not classified as parked: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[2].answerable')" = false ] || \
    fail "parked hold remained answerable: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[3].id')" = future-decision-key-c ] || \
    fail "future hold missing from the response: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[3].hold_kind')" = future ] || \
    fail "future hold kind missing from the response: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[3].actionable')" = false ] || \
    fail "future hold remained actionable: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[3].parked')" = true ] || \
    fail "future hold was not classified as parked: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[3].answerable')" = false ] || \
    fail "future hold remained answerable: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "captain holds retains deferred rows without making them actionable"
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

test_captain_attention_hold_present_worker_absent() {
  local home port resp fakebin
  home=$(fm_test_api_home api-attention-split)
  fakebin="$home/fakebin"
  : > "$home/data/backlog.md"
  make_fake_tasks_axi "$fakebin" "$(cd "$home" && pwd)/data/backlog.md"
  write_status "$home" internal-wedge \
    'needs-decision [key=nm-custody-wedge]: retry bin/fm-captain-queue.sh?'
  write_queue "$home" <<'EOF'
{
  "items": [
    {
      "id": "fm-memory-path",
      "question": "Keep trimming memory, or adopt a vault?",
      "options": ["Stay with trim (recommended)", "Adopt a vault"],
      "status": "open"
    }
  ]
}
EOF
  port=$(TASKS_AXI_FILE="$home/other-backlog.md" PATH="$fakebin:$PATH" fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /captain-queue)
  split_http <<<"$resp"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items.length')" = 1 ] || \
    fail "wanted the escalated card only: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.items[0].id')" = fm-memory-path ] || \
    fail "queue served the worker instead of the card: $HTTP_BODY"
  resp=$(fm_test_api_http "$port" /captain-holds GET 8000)
  split_http <<<"$resp"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds.length')" = 4 ] || \
    fail "captain hold missing from /captain-holds: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.holds[0].id')" = ready-decision-key-a ] || \
    fail "actionable hold should still sort first: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "a captain hold and card are shown; a worker needs-decision is not"
}

test_empty_home_queue_is_empty
test_captain_queue_ignores_worker_needs_decision
test_captain_queue_serves_open_named_cards
test_captain_queue_serves_parked_cards_separately
test_captain_queue_rejects_bad_options
test_captain_queue_moves_recommended_first
test_captain_attention_hold_present_worker_absent
test_empty_home_blocked_is_empty
test_blocked_list_returns_blocked_tasks
test_empty_home_rigs_is_empty
test_rigs_returns_pools_and_rung_enabled_state
test_rigs_returns_note_pins_and_harness_pins
test_rigs_extras_default_to_empty_when_absent
test_rigs_refuses_a_symlinked_config
test_captain_holds_returns_open_holds_actionable_first
test_captain_holds_empty_without_tasks_axi

echo "# fm-api-reads.test.sh: all assertions passed"
