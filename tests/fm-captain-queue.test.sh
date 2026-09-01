#!/usr/bin/env bash
# tests/fm-captain-queue.test.sh - captain card add, reply, expiry, parking,
# migration, locking, and done-item retirement behavior.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

Q="$ROOT/bin/fm-captain-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-queue)
NOW=2026-08-27T18:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

run_q() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_CAPTAIN_QUEUE_NOW="$NOW" "$Q" "$@"
}

append_reply() {  # <home> <id> <answer> [generation]
  local home=$1 generation=${4:-}
  if [ -z "$generation" ]; then
    generation=$(jq -r --arg id "$2" \
      '[.records[]? | select(.id == $id) | .generation] | first // 1' \
      "$home/data/captain-queue.json")
  fi
  jq -nc --arg id "$2" --arg answer "$3" --arg at "$NOW" --argjson generation "$generation" \
    '{id: $id, generation: $generation, answer: $answer, at: $at}' >> "$home/state/captain-replies.jsonl"
}

active_ids() {  # <home>
  jq -r '
    if has("records") then .records[]? | select(.state == "open")
    else .items[]? | select((.status // "open") == "open")
    end
    | .id
  ' \
    "$1/data/captain-queue.json" 2>/dev/null || true
}

resolved_answer() {  # <home> <id>
  jq -r --arg id "$2" '
    if has("records") then .records[]? | select(.state == "resolved")
    else .resolved[]?
    end
    | select(.id == $id)
    | .answer
  ' \
    "$1/data/captain-queue.json"
}

parked_ids() {  # <home>
  jq -r '
    if has("records") then .records[]? | select(.state == "parked")
    else .parked[]?
    end
    | .id
  ' \
    "$1/data/captain-queue.json" 2>/dev/null || true
}

cursor_value() {  # <home>
  if [ -f "$1/state/captain-replies.cursor" ]; then
    tr -cd '0-9' < "$1/state/captain-replies.cursor"
  else
    printf '0'
  fi
}

test_add_uses_the_supplied_id() {
  local home out
  home=$(make_home add-id)
  out=$(run_q "$home" add \
    --id sample-origin-decision-prod-gate \
    --question "Ship on merge?" \
    --option "Yes" --option "No" \
    --project sample)
  assert_contains "$out" "added: sample-origin-decision-prod-gate" "add should echo the id"
  [ "$(jq -r '.records[0].id' "$home/data/captain-queue.json")" = \
    sample-origin-decision-prod-gate ] \
    || fail "card id was not the supplied hold identity"
  [ "$(jq -r '.records[0].state' "$home/data/captain-queue.json")" = open ] \
    || fail "new card should be open"
  [ "$(jq -r '.records[0].generation' "$home/data/captain-queue.json")" = 1 ] \
    || fail "new card should start at generation 1"
  pass "add writes a card under the supplied hold identity"
}

test_writer_persists_one_canonical_record_per_card() {
  local home
  home=$(make_home canonical-records)
  run_q "$home" add --id canonical-card --question "Original question?" >/dev/null
  run_q "$home" add --id canonical-card --question "Updated question?" >/dev/null
  jq -e '
    has("records")
    and (has("items") | not)
    and (has("resolved") | not)
    and (has("parked") | not)
    and (.records | length) == 1
    and .records[0].id == "canonical-card"
    and .records[0].state == "open"
    and (.records[0] | has("status") | not)
    and .records[0].question == "Updated question?"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "writer did not persist one canonical record for the card"
  pass "the writer persists one canonical record per card"
}

test_unbacked_card_expires_to_parked() {
  local home out
  home=$(make_home unbacked-expiry)
  run_q "$home" add \
    --id urgent-unbacked-question \
    --question "Approve the emergency change?" \
    --asked-at 2026-08-20T18:00:00Z >/dev/null
  [ "$(jq -r '.records[0].backlog_backed' "$home/data/captain-queue.json")" = false ] \
    || fail "unbacked card did not record its creation-time backing state"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=urgent-unbacked-question] expired-unbacked" \
    "expired unbacked card should report that it was parked"
  [ -z "$(active_ids "$home")" ] || fail "expired unbacked card stayed active"
  [ "$(parked_ids "$home")" = urgent-unbacked-question ] \
    || fail "expired unbacked card did not move to parked"
  pass "an unbacked card records its backing state and expires to parked after seven days"
}

test_unbacked_card_stays_active_before_expiry() {
  local home out
  home=$(make_home unbacked-before-expiry)
  run_q "$home" add \
    --id recent-unbacked-question \
    --question "Approve the recent change?" \
    --asked-at 2026-08-20T18:00:01Z >/dev/null
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "unbacked card younger than seven days should be silent: $out"
  [ "$(active_ids "$home")" = recent-unbacked-question ] \
    || fail "unbacked card expired before seven days"
  [ -z "$(parked_ids "$home")" ] || fail "recent unbacked card moved to parked"
  pass "an unbacked card stays active until the seven-day expiry boundary"
}

test_reposting_preserves_the_expiry_anchor() {
  local home out
  home=$(make_home repost-expiry)
  run_q "$home" add \
    --id reposted-unbacked-question \
    --question "Original question" \
    --asked-at 2026-08-20T18:00:00Z >/dev/null
  run_q "$home" add \
    --id reposted-unbacked-question \
    --question "Updated question" >/dev/null
  jq -e '
    .records[0].asked_at == "2026-08-20T18:00:00Z"
    and .records[0].backlog_backed == false
    and .records[0].question == "Updated question"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "reposting changed the card's original expiry metadata"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=reposted-unbacked-question] expired-unbacked" \
    "reposting must not reset the seven-day expiry window"
  pass "reposting updates the card body without resetting its expiry clock"
}

test_asked_at_is_normalized_or_rejected() {
  local home out rc
  home=$(make_home asked-at-validation)
  run_q "$home" add \
    --id offset-question \
    --question "Offset timestamp?" \
    --asked-at 2026-08-20T13:00:00-05:00 >/dev/null
  [ "$(jq -r '.records[0].asked_at' "$home/data/captain-queue.json")" = 2026-08-20T18:00:00Z ] \
    || fail "numeric-offset asked_at was not normalized to UTC"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=offset-question] expired-unbacked" \
    "a normalized offset timestamp should expire at the same instant"
  rc=0
  out=$(run_q "$home" add \
    --id malformed-time-question \
    --question "Malformed timestamp?" \
    --asked-at 2026-02-30T18:00:00Z 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "malformed asked_at should exit 2, got $rc"
  assert_contains "$out" "add --asked-at must be an ISO timestamp with a timezone" \
    "malformed asked_at should explain the accepted timestamp contract"
  [ -z "$(active_ids "$home")" ] || fail "malformed asked_at wrote an active card"
  rc=0
  out=$(run_q "$home" add \
    --id future-time-question \
    --question "Future timestamp?" \
    --asked-at 2026-08-27T18:00:01Z 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "future asked_at should exit 2, got $rc"
  assert_contains "$out" "add --asked-at cannot be later than the add time" \
    "future asked_at should explain the add-time boundary"
  [ -z "$(active_ids "$home")" ] || fail "future asked_at wrote an active card"
  pass "asked_at normalizes offsets and rejects invalid or future times"
}

test_legacy_offset_asked_at_expires() {
  local home out
  home=$(make_home legacy-offset-expiry)
  jq -n '{
    updated_at: "2026-08-20T18:00:00Z",
    records: [{
      id: "legacy-offset-expiry",
      num: 1,
      generation: 1,
      question: "Offset legacy question?",
      asked_at: "2026-08-20T13:00:00-05:00",
      backlog_backed: false,
      state: "open"
    }]
  }' > "$home/data/captain-queue.json"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=legacy-offset-expiry] expired-unbacked" \
    "a signed-offset legacy timestamp should expire at the same instant"
  jq -e '
    .records[0].state == "parked"
    and .records[0].asked_at == "2026-08-20T13:00:00-05:00"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "signed-offset expiry changed or failed to park the legacy card"
  pass "a signed-offset legacy asked-at reaches bounded expiry"
}

test_fractional_legacy_asked_at_expires() {
  local home out
  home=$(make_home legacy-fractional-expiry)
  jq -n '{
    updated_at: "2026-08-20T18:00:00Z",
    records: [{
      id: "fractional-z-expiry",
      num: 1,
      generation: 1,
      question: "Fractional UTC legacy question?",
      asked_at: "2026-08-20T17:59:59.500Z",
      backlog_backed: false,
      state: "open"
    }, {
      id: "fractional-offset-expiry",
      num: 2,
      generation: 1,
      question: "Fractional offset legacy question?",
      asked_at: "2026-08-20T12:59:59.500-05:00",
      backlog_backed: false,
      state: "open"
    }]
  }' > "$home/data/captain-queue.json"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=fractional-z-expiry] expired-unbacked" \
    "a fractional UTC legacy timestamp should expire"
  assert_contains "$out" "parked: [id=fractional-offset-expiry] expired-unbacked" \
    "a fractional numeric-offset legacy timestamp should expire"
  [ "$(parked_ids "$home")" = $'fractional-z-expiry\nfractional-offset-expiry' ] \
    || fail "fractional legacy timestamps did not reach bounded expiry"
  pass "fractional UTC and offset legacy asked-at values reach bounded expiry"
}

test_expiry_preserves_card_and_is_idempotent() {
  local home out
  home=$(make_home expiry-body)
  run_q "$home" add \
    --id full-unbacked-question \
    --question "Which release should ship?" \
    --context "Production is waiting." \
    --project sample \
    --asked-at 2026-08-20T17:59:59Z \
    --option "Ship A" \
    --option "Ship B" \
    --command "deploy-a" \
    --command "deploy-b" >/dev/null
  run_q "$home" reconcile >/dev/null
  jq -e '
    (.records | length) == 1
    and .records[0].id == "full-unbacked-question"
    and .records[0].question == "Which release should ship?"
    and .records[0].context == "Production is waiting."
    and .records[0].project == "sample"
    and .records[0].asked_at == "2026-08-20T17:59:59Z"
    and .records[0].options == ["Ship A", "Ship B"]
    and .records[0].commands == ["deploy-a", "deploy-b"]
    and .records[0].state == "parked"
    and .records[0].parked_reason == "expired-unbacked"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "expiry did not preserve the card body in a distinct parked group"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "reconcile mentioned an already parked card: $out"
  [ "$(jq '[.records[] | select(.state == "parked")] | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "reconcile re-parked an already parked card"
  [ -z "$(active_ids "$home")" ] || fail "reconcile resurrected an already parked card"
  pass "expiry preserves the full card in parked and never re-parks or resurrects it"
}

test_manual_park_defers_a_fresh_unbacked_card() {
  local home out rc
  home=$(make_home manual-park)
  run_q "$home" add \
    --id settled-existing-question \
    --question "Proceed with cutover?" \
    --context "The cutover has since completed." \
    --asked-at "$NOW" \
    --option "Proceed" \
    --option "Wait" >/dev/null
  out=$(run_q "$home" park \
    --id settled-existing-question \
    --note "Verified settled on 2026-08-27")
  assert_contains "$out" "parked: [id=settled-existing-question] manual" \
    "manual park should report the deferred card"
  [ -z "$(active_ids "$home")" ] || fail "manual park left the deferred card active"
  jq -e --arg now "$NOW" '
    (.records | length) == 1
    and .records[0].state == "parked"
    and .records[0].id == "settled-existing-question"
    and .records[0].question == "Proceed with cutover?"
    and .records[0].context == "The cutover has since completed."
    and .records[0].asked_at == $now
    and .records[0].options == ["Proceed", "Wait"]
    and .records[0].parked_reason == "manual"
    and .records[0].parked_note == "Verified settled on 2026-08-27"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "manual park did not preserve the fresh card and deferral note"
  out=$(run_q "$home" park \
    --id settled-existing-question \
    --note "Verified settled on 2026-08-27")
  assert_contains "$out" "parked: [id=settled-existing-question] already-parked" \
    "repeating manual park should report an idempotent no-op"
  [ "$(jq '[.records[] | select(.state == "parked")] | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "repeating manual park duplicated the card"
  rc=0
  run_q "$home" add \
    --id settled-existing-question \
    --question "Ask this again" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "add should refuse to resurrect a parked card, got $rc"
  [ -z "$(active_ids "$home")" ] || fail "add resurrected a parked card"
  [ "$(jq '[.records[] | select(.state == "parked")] | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "refused add changed the parked card"
  pass "manual park defers a fresh unbacked card and repeats safely"
}

test_legacy_card_waits_for_verified_migration() {
  local home out
  home=$(make_home legacy-card)
  jq -n '{
    updated_at: "2026-08-22T18:00:00Z",
    items: [{
      id: "legacy-question",
      num: 1,
      question: "Is this still needed?",
      context: "Created before backing state was recorded.",
      commands: [],
      options: ["Yes", "No"],
      asked_at: "2026-08-22T18:00:00Z",
      status: "open",
      project: "sample"
    }],
    resolved: []
  }' > "$home/data/captain-queue.json"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "legacy card should wait silently for verification: $out"
  [ "$(active_ids "$home")" = legacy-question ] \
    || fail "legacy card moved without human verification"
  [ -z "$(parked_ids "$home")" ] || fail "legacy card was automatically parked"
  out=$(run_q "$home" park --id legacy-question --note "Verified legacy migration")
  assert_contains "$out" "parked: [id=legacy-question] manual" \
    "manual verification should allow a legacy migration candidate to park"
  [ "$(parked_ids "$home")" = legacy-question ] \
    || fail "manual verification did not park the legacy migration candidate"
  jq -e '
    has("records")
    and (has("items") | not)
    and (has("resolved") | not)
    and (has("parked") | not)
    and (.records | length) == 1
    and .records[0].id == "legacy-question"
    and .records[0].state == "parked"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "successful legacy transition did not write the canonical queue shape"
  pass "a legacy card waits for human verification and then allows manual migration"
}

test_legacy_duplicate_id_prefers_visible_state_over_timestamp() {
  local home out
  home=$(make_home legacy-duplicate-id)
  jq -n '{
    updated_at: "2026-08-27T17:00:00Z",
    items: [{
      id: "reused-legacy-card",
      num: 1,
      question: "Current board question?",
      context: "This is the card the board was showing.",
      commands: ["run-current"],
      options: ["Current choice", "Something else"],
      asked_at: "2026-08-21T18:00:00Z",
      backlog_backed: false,
      status: "open",
      project: "sample"
    }],
    resolved: [{
      id: "reused-legacy-card",
      num: 1,
      question: "Older answered question?",
      context: "This record predates the current board card.",
      commands: ["run-old"],
      options: ["Old choice", "Something else"],
      asked_at: "2026-08-20T18:00:00Z",
      status: "resolved",
      answer: "Old answer",
      resolved_at: "2026-08-26T18:00:00Z",
      project: "sample"
    }],
    parked: []
  }' > "$home/data/captain-queue.json"
  append_reply "$home" reused-legacy-card "Current answer" 2
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=reused-legacy-card] Current answer" \
    "legacy duplicate migration should prefer the visible card despite its older asked-at"
  jq -e '
    has("records")
    and (has("items") | not)
    and (has("resolved") | not)
    and (has("parked") | not)
    and (.records | length) == 1
    and .records[0].id == "reused-legacy-card"
    and .records[0].generation == 2
    and .records[0].state == "resolved"
    and .records[0].question == "Current board question?"
    and .records[0].context == "This is the card the board was showing."
    and .records[0].commands == ["run-current"]
    and .records[0].options == ["Current choice", "Something else"]
    and .records[0].answer == "Current answer"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "legacy duplicate migration did not retain the visible card"
  pass "legacy duplicate migration prefers visible state over timestamps"
}

test_legacy_same_state_duplicate_compares_offset_timestamps() {
  local home
  home=$(make_home legacy-offset-timestamps)
  jq -n '{
    updated_at: "2026-08-26T18:00:00Z",
    items: [],
    resolved: [
      {
        id: "resolved-twice",
        num: 1,
        question: "Older resolved question?",
        asked_at: "2026-08-20T17:00:00Z",
        status: "resolved",
        answer: "Older answer",
        resolved_at: "2026-08-26T17:00:00Z"
      },
      {
        id: "resolved-twice",
        num: 1,
        question: "Newer offset question?",
        asked_at: "2026-08-20T13:00:00-05:00",
        status: "resolved",
        answer: "Newer offset answer",
        resolved_at: "2026-08-26T13:00:00-05:00"
      }
    ],
    parked: []
  }' > "$home/data/captain-queue.json"
  run_q "$home" add --id migration-write --question "Write the migrated queue?" >/dev/null
  jq -e '
    [.records[] | select(.id == "resolved-twice")] as $matches
    | ($matches | length) == 1
      and $matches[0].question == "Newer offset question?"
      and $matches[0].answer == "Newer offset answer"
      and $matches[0].resolved_at == "2026-08-26T13:00:00-05:00"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "legacy migration did not compare signed-offset timestamps chronologically"
  pass "legacy duplicate migration compares Z and signed-offset timestamps"
}

test_legacy_reopen_uses_successor_generation() {
  local home out
  home=$(make_home legacy-reopen-generation)
  jq -n '{
    updated_at: "2026-08-27T18:00:00Z",
    items: [{
      id: "legacy-reopened-card",
      num: 1,
      question: "New question?",
      asked_at: "2026-08-27T18:00:00Z",
      status: "open"
    }],
    resolved: [{
      id: "legacy-reopened-card",
      num: 1,
      question: "Old question?",
      asked_at: "2026-08-20T18:00:00Z",
      resolved_at: "2026-08-21T18:00:00Z",
      answer: "old answer",
      status: "resolved"
    }]
  }' > "$home/data/captain-queue.json"
  jq -nc \
    --arg id legacy-reopened-card \
    --arg answer "delayed old answer" \
    --arg at "$NOW" \
    '{id: $id, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "stale: [id=legacy-reopened-card] [generation=1] delayed old answer" \
    "a generation-less legacy reply must stay bound to the prior question"
  jq -e '
    .records == [{
      id: "legacy-reopened-card",
      num: 1,
      question: "New question?",
      asked_at: "2026-08-27T18:00:00Z",
      state: "open",
      generation: 2
    }]
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "legacy reopen did not persist one generation-2 open card"
  pass "legacy reopen migration keeps delayed answers on the prior generation"
}

test_future_legacy_anchor_gets_one_fresh_window() {
  local home out
  home=$(make_home future-legacy-anchor)
  jq -n '{
    updated_at: "2026-08-27T18:00:00Z",
    items: [{
      id: "future-legacy-card",
      num: 1,
      question: "Future legacy question?",
      asked_at: "2099-01-01T00:00:00Z",
      status: "open"
    }],
    resolved: []
  }' > "$home/data/captain-queue.json"

  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "future legacy anchor should start a fresh quiet window: $out"
  jq -e --arg now "$NOW" '
    .records[0].state == "open"
    and .records[0].asked_at == $now
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "future legacy anchor was not clamped to migration time"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "repeat migration restarted or expired the fresh window: $out"
  [ "$(jq -r '.records[0].asked_at' "$home/data/captain-queue.json")" = "$NOW" ] \
    || fail "repeat migration changed the clamped expiry anchor"
  out=$(FM_HOME="$home" FM_CAPTAIN_QUEUE_NOW=2026-09-03T18:00:00Z "$Q" reconcile)
  assert_contains "$out" "parked: [id=future-legacy-card] expired-legacy-backing" \
    "the clamped legacy card should expire after its fresh seven-day window"
  pass "future legacy anchors receive one persisted seven-day window"
}

test_malformed_legacy_anchor_gets_one_fresh_window() {
  local home out
  home=$(make_home malformed-legacy-anchor)
  jq -n '{
    updated_at: "2026-08-27T18:00:00Z",
    items: [{
      id: "malformed-legacy-card",
      num: 1,
      question: "Malformed legacy question?",
      asked_at: "not-a-date",
      status: "open"
    }],
    resolved: []
  }' > "$home/data/captain-queue.json"

  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "malformed legacy anchor should start a fresh quiet window: $out"
  jq -e --arg now "$NOW" '
    .records[0].state == "open"
    and .records[0].asked_at == $now
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "malformed legacy anchor was not clamped to migration time"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "repeat migration restarted or expired the malformed anchor: $out"
  [ "$(jq -r '.records[0].asked_at' "$home/data/captain-queue.json")" = "$NOW" ] \
    || fail "repeat migration changed the repaired expiry anchor"
  out=$(FM_HOME="$home" FM_CAPTAIN_QUEUE_NOW=2026-09-03T18:00:00Z "$Q" reconcile)
  assert_contains "$out" "parked: [id=malformed-legacy-card] expired-legacy-backing" \
    "the repaired legacy card should expire after its fresh seven-day window"
  pass "malformed legacy anchors receive one persisted seven-day window"
}

test_add_reconstructs_consumed_reply_history() {
  local home out
  home=$(make_home add-reconstructs-history)
  jq -n '{
    updated_at: "2026-08-26T18:00:00Z",
    records: [{
      id: "upgrade-card",
      num: 1,
      generation: 1,
      question: "Old question?",
      asked_at: "2026-08-20T18:00:00Z",
      state: "resolved",
      answer: "old answer",
      resolved_at: "2026-08-21T18:00:00Z"
    }]
  }' > "$home/data/captain-queue.json"
  jq -nc \
    --arg id upgrade-card \
    --arg answer "old answer" \
    --arg at 2026-08-21T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  printf '1\n' > "$home/state/captain-replies.cursor"

  run_q "$home" add --id upgrade-card --question "New question?" >/dev/null
  jq -e '
    .records[0].state == "open"
    and .records[0].generation == 2
    and .delivered_reply_winners == [{
      line: 1,
      id: "upgrade-card",
      generation: 1,
      answer: "old answer",
      kind: "handled"
    }]
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "add did not carry consumed reply history into the canonical queue"
  jq -nc \
    --arg id upgrade-card \
    --arg answer "old answer" \
    --arg at 2026-08-21T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  out=$(run_q "$home" reconcile)
  assert_not_contains "$out" "handled: [id=upgrade-card] old answer" \
    "add migration must not redeliver a consumed answer"
  [ "$(cursor_value "$home")" = 2 ] \
    || fail "the duplicate consumed answer did not advance the cursor"
  pass "add reconstructs consumed reply history before canonical write"
}

test_park_reconstructs_consumed_reply_history() {
  local home out
  home=$(make_home park-reconstructs-history)
  jq -n '{
    updated_at: "2026-08-26T18:00:00Z",
    items: [{
      id: "park-target",
      num: 1,
      question: "Park this?",
      asked_at: "2026-08-26T18:00:00Z",
      backlog_backed: false,
      status: "open"
    }],
    resolved: [{
      id: "answered-card",
      num: 2,
      question: "Answered?",
      asked_at: "2026-08-20T18:00:00Z",
      answer: "first answer",
      resolved_at: "2026-08-21T18:00:00Z",
      status: "resolved"
    }]
  }' > "$home/data/captain-queue.json"
  jq -nc \
    --arg id answered-card \
    --arg answer "first answer" \
    --arg at 2026-08-21T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  printf '1\n' > "$home/state/captain-replies.cursor"

  run_q "$home" park --id park-target --note "Verified migration" >/dev/null
  jq -e '
    .records[] | select(.id == "park-target" and .state == "parked")
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "park did not persist the requested card migration"
  jq -nc \
    --arg id answered-card \
    --arg answer "replacement answer" \
    --arg at "$NOW" \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "superseding: [id=answered-card] [generation=1] replacement answer" \
    "park migration should preserve the earlier delivered answer"
  assert_contains "$out" "handled: [id=answered-card] replacement answer" \
    "the later answer should be delivered as the superseding winner"
  pass "park reconstructs consumed reply history before canonical write"
}

test_legacy_backlog_done_history_reconstructs_dashboard_delivery() {
  local home out
  home=$(make_home legacy-backlog-done-history)
  jq -n '{
    updated_at: "2026-08-27T18:00:00Z",
    items: [{
      id: "legacy-backlog-done-card",
      num: 1,
      question: "New question?",
      asked_at: "2026-08-27T18:00:00Z",
      status: "open"
    }],
    resolved: [{
      id: "legacy-backlog-done-card",
      num: 1,
      question: "Old question?",
      asked_at: "2026-08-20T18:00:00Z",
      answer: "backlog-done",
      resolved_at: "2026-08-21T18:00:00Z",
      status: "resolved"
    }]
  }' > "$home/data/captain-queue.json"
  jq -nc \
    --arg id legacy-backlog-done-card \
    --arg answer "first dashboard answer" \
    '{id: $id, answer: $answer}' \
    >> "$home/state/captain-replies.jsonl"
  printf '1\n' > "$home/state/captain-replies.cursor"

  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "legacy backlog-done migration should be quiet: $out"
  jq -e '
    .records[0].state == "open"
    and .records[0].generation == 2
    and .delivered_reply_winners == [{
      line: 1,
      id: "legacy-backlog-done-card",
      generation: 1,
      answer: "first dashboard answer",
      kind: "handled"
    }]
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "legacy backlog-done history omitted the consumed dashboard answer"
  jq -nc \
    --arg id legacy-backlog-done-card \
    --arg answer "replacement dashboard answer" \
    --arg at "$NOW" \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "superseding: [id=legacy-backlog-done-card] [generation=1] replacement dashboard answer" \
    "the later historical answer should supersede reconstructed backlog-done delivery"
  assert_contains "$out" \
    "handled: [id=legacy-backlog-done-card] replacement dashboard answer" \
    "the later historical answer should be delivered"
  jq -e '
    .records[0].state == "open"
    and .records[0].generation == 2
    and .records[0].question == "New question?"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "historical backlog-done supersession changed the reopened card"
  pass "legacy backlog-done migration reconstructs dashboard delivery"
}

assert_consumed_legacy_reply_is_not_redelivered() {  # <name> <consumed-json>
  local home out
  home=$(make_home "$1")
  jq -n '{
    updated_at: "2026-08-27T18:00:00Z",
    items: [],
    resolved: [{
      id: "legacy-card",
      num: 1,
      question: "Old question?",
      asked_at: "2026-08-27T10:00:00Z",
      answer: "already acted on",
      resolved_at: "2026-08-27T11:00:00Z",
      status: "resolved"
    }]
  }' > "$home/data/captain-queue.json"
  printf '%s\n' "$2" > "$home/state/captain-replies.jsonl"
  printf '1\n' > "$home/state/captain-replies.cursor"
  jq -nc \
    --arg answer "already acted on" \
    --arg at "$NOW" \
    '{id: "legacy-card", generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  out=$(run_q "$home" reconcile)
  assert_not_contains "$out" "handled: [id=legacy-card]" \
    "an answer already consumed under the legacy contract must not run again"
  jq -e '
    [.delivered_reply_winners[] | select(.id == "legacy-card")]
    | length == 1 and .[0].line == 1
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "consumed legacy reply was not reconstructed as delivered history"
}

test_consumed_legacy_reply_never_redelivers() {
  assert_consumed_legacy_reply_is_not_redelivered \
    legacy-consumed-bad-generation \
    '{"id":"legacy-card","answer":"already acted on","generation":"one"}'
  assert_consumed_legacy_reply_is_not_redelivered \
    legacy-consumed-bad-receipt \
    '{"id":"legacy-card","answer":"already acted on","at":"nonsense"}'
  pass "consumed legacy replies are not redelivered after upgrade"
}

test_manual_park_rejects_backed_and_unknown_cards() {
  local home id out rc
  home=$(make_home manual-park-guards)
  jq -n '{
    updated_at: "2026-08-27T18:00:00Z",
    items: [
      {
        id: "backed-card",
        num: 1,
        question: "Backed?",
        asked_at: "2026-08-26T18:00:00Z",
        backlog_backed: true,
        status: "open"
      },
      {
        id: "unknown-card",
        num: 2,
        question: "Unknown?",
        asked_at: "2026-08-26T18:00:00Z",
        backlog_backed: null,
        status: "open"
      }
    ],
    resolved: [],
    parked: []
  }' > "$home/data/captain-queue.json"
  for id in backed-card unknown-card; do
    rc=0
    out=$(run_q "$home" park --id "$id" --note "Must stay active" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || fail "manual park of $id should exit 1, got $rc"
    assert_contains "$out" "manual park requires an unbacked or legacy card: $id" \
      "manual park should explain why $id cannot move"
  done
  [ "$(active_ids "$home" | sort | tr '\n' ' ')" = "backed-card unknown-card " ] \
    || fail "refused manual park changed the active cards"
  [ -z "$(parked_ids "$home")" ] || fail "refused manual park created parked history"
  pass "manual park accepts only verified unbacked or legacy cards"
}

test_backed_card_does_not_expire() {
  local home out
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (backed-card expiry)"
    return 0
  fi
  home=$(make_home backed-expiry)
  seed_backlog "$home"
  backlog_add "$home" long-running-choice "Keep waiting?"
  run_q "$home" add \
    --id long-running-choice \
    --question "Keep waiting?" \
    --asked-at 2026-08-01T18:00:00Z >/dev/null
  [ "$(jq -r '.records[0].backlog_backed' "$home/data/captain-queue.json")" = true ] \
    || fail "backed card did not record its creation-time backing state"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "open backed card should not produce reconcile output: $out"
  [ "$(active_ids "$home")" = long-running-choice ] \
    || fail "open backed card expired"
  [ -z "$(parked_ids "$home")" ] || fail "open backed card moved to parked"
  pass "a backed card records its backing state and never expires while its work stays open"
}

test_backlog_fallback_avoids_unknown_state() {
  local home fakebin out
  home=$(make_home backlog-fallback)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] fallback-backed-question - Keep the backed work open (repo: sample) (kind: captain)

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  make_failing_tasks_axi "$fakebin"
  PATH="$fakebin:$PATH" run_q "$home" add \
    --id fallback-backed-question \
    --question "Keep waiting?" \
    --asked-at 2026-08-01T18:00:00Z >/dev/null
  PATH="$fakebin:$PATH" run_q "$home" add \
    --id fallback-unbacked-question \
    --question "Urgent unbacked question?" \
    --asked-at 2026-08-01T18:00:00Z >/dev/null
  jq -e '
    any(.records[]; .id == "fallback-backed-question" and .backlog_backed == true)
    and any(.records[]; .id == "fallback-unbacked-question" and .backlog_backed == false)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "the readable backlog fallback did not record definite backing states"
  out=$(PATH="$fakebin:$PATH" run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=fallback-unbacked-question] expired-unbacked" \
    "the fallback-classified unbacked card should expire"
  [ "$(active_ids "$home")" = fallback-backed-question ] \
    || fail "the fallback-classified backed card did not remain active"
  pass "a readable backlog keeps backing state definite during tool failure"
}

test_repost_preserves_unknown_add_time_backing() {
  local home fakebin out
  home=$(make_home unreadable-backlog)
  printf '%s\n' 'backlog contents unavailable to the queue reader' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  make_failing_tasks_axi "$fakebin"
  cat > "$fakebin/awk" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/awk"
  PATH="$fakebin:$PATH" run_q "$home" add \
    --id unknown-backing-question \
    --question "Urgent question while backlog reads fail?" \
    --asked-at 2026-08-20T18:00:00Z >/dev/null \
    || fail "an unreadable backlog refused an urgent card"
  jq -e '
    .records[0].id == "unknown-backing-question"
    and .records[0].state == "open"
    and .records[0].backlog_backed == null
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "unreadable backlog did not record unknown backing"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- unknown-backing-question - Work filed after the captain card
EOF
  rm -f "$fakebin/awk"
  PATH="$fakebin:$PATH" run_q "$home" add \
    --id unknown-backing-question \
    --question "Updated urgent question after work appeared?" >/dev/null
  jq -e '
    .records[0].id == "unknown-backing-question"
    and .records[0].state == "open"
    and .records[0].question == "Updated urgent question after work appeared?"
    and .records[0].backlog_backed == null
    and .records[0].asked_at == "2026-08-20T18:00:00Z"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "repost changed unknown add-time backing or its expiry anchor"
  out=$(PATH="$fakebin:$PATH" run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=unknown-backing-question] expired-unknown-backing" \
    "later same-id work must not turn unknown add-time backing into backed"
  [ "$(parked_ids "$home")" = unknown-backing-question ] \
    || fail "later same-id work made an unknown card ask past its bounded window"
  jq -e '
    .records[0].id == "unknown-backing-question"
    and .records[0].state == "parked"
    and .records[0].backlog_backed == null
    and .records[0].asked_at == "2026-08-20T18:00:00Z"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "unknown add-time backing or its expiry anchor changed during reconcile"
  pass "repost preserves unknown add-time backing and bounded expiry"
}

test_later_done_item_does_not_resolve_an_unbacked_card() {
  local home out
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (unbacked same-id done item)"
    return 0
  fi
  home=$(make_home unbacked-id-collision)
  run_q "$home" add \
    --id later-colliding-work \
    --question "Still unanswered?" \
    --asked-at 2026-08-01T18:00:00Z >/dev/null
  seed_backlog "$home"
  backlog_add "$home" later-colliding-work "Later work with the same id"
  backlog_done "$home" later-colliding-work
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=later-colliding-work] expired-unbacked" \
    "the card's creation-time backing state should control its transition"
  assert_not_contains "$out" "cleared:" \
    "later same-id work must not mark an unanswered card resolved"
  [ "$(jq '[.records[] | select(.state == "resolved")] | length' "$home/data/captain-queue.json")" -eq 0 ] \
    || fail "later same-id work moved the unbacked card to resolved"
  pass "later same-id work cannot resolve an originally unbacked card"
}

test_matched_reply_removes_the_card_and_keeps_the_answer() {
  local home out
  home=$(make_home match)
  run_q "$home" add \
    --id sample-origin-decision-prod-gate \
    --question "Ship on merge?" >/dev/null
  append_reply "$home" sample-origin-decision-prod-gate "option 1"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=sample-origin-decision-prod-gate] option 1" \
    "reconcile should print the handled answer"
  [ -z "$(active_ids "$home")" ] || fail "matched card stayed on the active board: $(active_ids "$home")"
  [ "$(resolved_answer "$home" sample-origin-decision-prod-gate)" = "option 1" ] \
    || fail "resolved card lost the answer"
  [ "$(cursor_value "$home")" = 1 ] || fail "cursor should be 1 after one handled reply, got $(cursor_value "$home")"
  # A second reconcile is a no-op: the answer is already past the cursor.
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "caught-up reconcile should be silent, got: $out"
  [ "$(cursor_value "$home")" = 1 ] || fail "caught-up reconcile moved the cursor"
  pass "a matched reply removes the card, keeps the answer, and advances the cursor one line"
}

test_reconcile_handles_a_queue_larger_than_one_process_argument() {
  local home out payload_file
  home=$(make_home large-queue-reconcile)
  payload_file="$home/data/large-card-body"
  head -c 2097152 /dev/zero | tr '\0' x > "$payload_file"
  jq -n --rawfile context "$payload_file" '{
    updated_at: "2026-08-27T18:00:00Z",
    records: [
      {
        id: "large-history",
        num: 1,
        generation: 1,
        question: "Historical question?",
        context: $context,
        asked_at: "2026-08-20T18:00:00Z",
        state: "resolved",
        answer: "Historical answer",
        resolved_at: "2026-08-21T18:00:00Z"
      },
      {
        id: "large-queue-live-card",
        num: 2,
        generation: 1,
        question: "Handle this answer?",
        asked_at: "2026-08-27T18:00:00Z",
        backlog_backed: false,
        state: "open"
      }
    ],
    pending_reply_deliveries: [],
    delivered_reply_winners: [],
    reply_delivery_tracking: false
  }' > "$home/data/captain-queue.json"
  append_reply "$home" large-queue-live-card "large queue answer"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=large-queue-live-card] large queue answer" \
    "a large retained queue should not block a matching answer"
  [ "$(resolved_answer "$home" large-queue-live-card)" = "large queue answer" ] \
    || fail "large queue reconcile lost the matching answer"
  pass "reconcile handles a queue larger than one process argument"
}

test_resolved_card_id_reopens_without_parked_history() {
  local home fakebin out
  home=$(make_home resolved-id-reuse)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- resolved-card - Work remains open while questions change
EOF
  fakebin=$(fm_fakebin "$home")
  make_failing_tasks_axi "$fakebin"
  PATH="$fakebin:$PATH" run_q "$home" add \
    --id resolved-card \
    --question "First question?" \
    --asked-at 2026-08-26T18:00:00Z >/dev/null
  append_reply "$home" resolved-card "First answer"
  PATH="$fakebin:$PATH" run_q "$home" reconcile >/dev/null
  out=$(PATH="$fakebin:$PATH" run_q "$home" add \
    --id resolved-card \
    --question "Second question?" \
    --context "The same open work needs another decision.")
  assert_contains "$out" "added: resolved-card" \
    "the deterministic hold id should reopen after its earlier answer"
  jq -e --arg now "$NOW" '
    (.records | length) == 1
    and .records[0].id == "resolved-card"
    and .records[0].state == "open"
    and .records[0].question == "Second question?"
    and .records[0].context == "The same open work needs another decision."
    and .records[0].asked_at == $now
    and .records[0].backlog_backed == true
    and .records[0].generation == 2
    and (.records[0] | has("answer") | not)
    and (.records[0] | has("resolved_at") | not)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "resolved card did not reopen as the new backed question"
  pass "a resolved deterministic card id reopens without parked history"
}

test_orphan_reply_does_not_advance_or_drop() {
  local home out rc
  home=$(make_home orphan)
  run_q "$home" add \
    --id sample-origin-decision-prod-gate \
    --question "Ship on merge?" >/dev/null
  append_reply "$home" some-old-scheme-id "option 1"
  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 1 ] || fail "orphan reconcile should exit 1, got $rc"
  assert_contains "$out" "orphan: [id=some-old-scheme-id] option 1" \
    "orphan should be surfaced"
  [ "$(active_ids "$home")" = sample-origin-decision-prod-gate ] \
    || fail "orphan reconcile should leave the unmatched card on the board"
  [ "$(cursor_value "$home")" = 0 ] || fail "orphan should leave the cursor put, got $(cursor_value "$home")"
  [ -s "$home/state/captain-replies.jsonl" ] || fail "orphan reconcile dropped the reply log"
  pass "an unmatched reply is surfaced, leaves the cursor put, and is not dropped"
}

test_orphan_stops_before_a_later_match() {
  local home out rc
  home=$(make_home orphan-middle)
  run_q "$home" add --id card-a --question "A?" >/dev/null
  run_q "$home" add --id card-c --question "C?" >/dev/null
  append_reply "$home" card-a "yes a"
  append_reply "$home" card-b "yes b"
  append_reply "$home" card-c "yes c"
  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 1 ] || fail "middle orphan should exit 1, got $rc"
  assert_contains "$out" "handled: [id=card-a] yes a" "first matching reply should handle"
  assert_contains "$out" "orphan: [id=card-b] yes b" "unmatched middle reply should surface"
  assert_not_contains "$out" "card-c" "reconcile must not skip past the orphan to a later match"
  [ "$(cursor_value "$home")" = 1 ] || fail "cursor should sit after the handled line, before the orphan, got $(cursor_value "$home")"
  case "$(active_ids "$home")" in
    *card-c*) : ;;
    *) fail "later card was removed even though its reply was never reached" ;;
  esac
  case "$(active_ids "$home")" in
    *card-a*) fail "handled card-a stayed active" ;;
  esac
  pass "an orphan stops reconcile before any later matching reply"
}

test_conflict_ranking_sees_winner_after_orphan() {
  local home out rc
  home=$(make_home conflict-after-orphan)
  run_q "$home" add --id card-a --question "A?" >/dev/null
  jq -nc \
    --arg id card-a \
    --arg answer "older answer" \
    --arg at 2026-08-27T17:59:58Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  append_reply "$home" missing-card "orphan answer"
  jq -nc \
    --arg id card-a \
    --arg answer "newer answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 1 ] || fail "orphan-separated conflict should exit 1, got $rc"
  assert_contains "$out" "handled: [id=card-a] older answer" \
    "the reply before the orphan must be delivered in order"
  assert_not_contains "$out" "winner-line=3" \
    "a blocker must delimit the conflict group"
  assert_contains "$out" "orphan: [id=missing-card] orphan answer" \
    "the orphan should still stop cursor progress"
  [ "$(cursor_value "$home")" = 1 ] \
    || fail "cursor should stop before the orphan, got $(cursor_value "$home")"
  [ "$(active_ids "$home")" = "" ] \
    || fail "the answered card should have cleared, got $(active_ids "$home")"
  [ "$(jq -r '[.records[] | select(.id == "card-a")] | first | .answer' \
    "$home/data/captain-queue.json")" = "older answer" ] \
    || fail "card-a should record the delivered answer"
  pass "a blocker delimits the conflict group and the earlier reply is delivered"
}

test_reply_behind_orphan_delivers_after_orphan_clears() {
  local home out rc
  home=$(make_home reply-behind-orphan)
  run_q "$home" add --id card-a --question "A?" >/dev/null
  run_q "$home" add --id card-b --question "B?" >/dev/null
  append_reply "$home" missing-card "orphan answer"
  append_reply "$home" card-b "later answer"

  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 1 ] || fail "orphan should exit 1, got $rc"
  assert_not_contains "$out" "card-b" "reconcile must not jump past the orphan"
  [ "$(cursor_value "$home")" = 0 ] \
    || fail "cursor should stay before the orphan, got $(cursor_value "$home")"

  run_q "$home" resolve --id missing-card >/dev/null 2>&1 || true
  jq -c 'select(.id != "missing-card")' \
    "$home/state/captain-replies.jsonl" > "$home/state/replies.tmp"
  mv "$home/state/replies.tmp" "$home/state/captain-replies.jsonl"

  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 0 ] || fail "cleared log should exit 0, got $rc"
  assert_contains "$out" "handled: [id=card-b] later answer" \
    "the reply behind the cleared blocker must eventually deliver"
  case "$(active_ids "$home")" in
    *card-b*) fail "card-b stayed open after its answer was delivered" ;;
  esac
  pass "a reply behind a blocker still delivers once the blocker clears"
}

test_conflicting_replies_rank_timestamp_then_log_order() {
  local home out handled_count
  home=$(make_home conflicting-replies)
  run_q "$home" add --id conflict-card --question "Choose one answer?" >/dev/null
  run_q "$home" add --id interleaved-card --question "Unrelated answer?" >/dev/null
  run_q "$home" add --id tied-card --question "Break the tie?" >/dev/null
  jq -nc \
    --arg id conflict-card \
    --arg answer "older answer" \
    --arg at 2026-08-27T17:59:58Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  jq -nc \
    --arg id interleaved-card \
    --arg answer "unrelated answer" \
    --arg at 2026-08-27T17:59:59Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  jq -nc \
    --arg id conflict-card \
    --arg answer "newer answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  jq -nc \
    --arg id tied-card \
    --arg answer "first tied answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  jq -nc \
    --arg id tied-card \
    --arg answer "later tied answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  out=$(run_q "$home" reconcile) || fail "conflicting reply group failed: $out"
  assert_contains "$out" \
    "superseded: [id=conflict-card] [generation=1] [winner-line=3] older answer" \
    "an older receipt should be marked superseded"
  assert_contains "$out" \
    "superseded: [id=tied-card] [generation=1] [winner-line=5] first tied answer" \
    "later log order should break an equal receipt-time tie"
  assert_contains "$out" "handled: [id=conflict-card] newer answer" \
    "the newest conflict receipt should be handled"
  assert_contains "$out" "handled: [id=interleaved-card] unrelated answer" \
    "an interleaved reply should still be handled"
  assert_contains "$out" "handled: [id=tied-card] later tied answer" \
    "the later tied reply should be handled"
  handled_count=$(printf '%s\n' "$out" | grep -c '^handled:' || true)
  [ "$handled_count" = 3 ] \
    || fail "conflicting groups emitted $handled_count handled answers, wanted 3: $out"
  [ "$(cursor_value "$home")" = 5 ] \
    || fail "conflicting groups did not advance the cursor through every reply"
  [ "$(wc -l < "$home/state/captain-replies.jsonl" | tr -d ' ')" = 5 ] \
    || fail "conflicting groups removed durable reply evidence"
  jq -e '
    any(.records[]; .id == "conflict-card" and .answer == "newer answer")
    and any(.records[]; .id == "interleaved-card" and .answer == "unrelated answer")
    and any(.records[]; .id == "tied-card" and .answer == "later tied answer")
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "conflicting reply winners were not persisted"
  pass "conflicting replies rank receipt time then log order without blocking"
}

test_conflicting_reply_crash_replay_delivers_only_the_winner() {
  local home out queue_file next_file
  home=$(make_home conflicting-reply-crash)
  run_q "$home" add --id crash-conflict-card --question "Which persisted answer?" >/dev/null
  jq -nc \
    --arg id crash-conflict-card \
    --arg answer "superseded answer" \
    --arg at 2026-08-27T17:59:59Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  jq -nc \
    --arg id crash-conflict-card \
    --arg answer "winning answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  queue_file="$home/data/captain-queue.json"
  next_file="$home/data/captain-queue.next"
  jq --arg stamp "$NOW" '
    .records[0] += {
      state: "resolved",
      answer: "winning answer",
      resolved_at: $stamp
    }
    | .pending_reply_deliveries = [{
        line: 2,
        id: "crash-conflict-card",
        generation: 1,
        answer: "winning answer"
      }]
  ' "$queue_file" > "$next_file"
  mv "$next_file" "$queue_file"

  out=$(run_q "$home" reconcile) || fail "conflicting crash replay failed: $out"
  assert_contains "$out" \
    "superseded: [id=crash-conflict-card] [generation=1] [winner-line=2] superseded answer" \
    "crash replay should keep the losing reply superseded"
  assert_contains "$out" "handled: [id=crash-conflict-card] winning answer" \
    "crash replay should deliver the persisted winner"
  assert_not_contains "$out" "handled: [id=crash-conflict-card] superseded answer" \
    "crash replay must not deliver the losing reply"
  [ "$(cursor_value "$home")" = 2 ] \
    || fail "conflicting crash replay did not advance past the group"
  [ "$(jq '.pending_reply_deliveries | length' "$queue_file")" = 0 ] \
    || fail "conflicting crash replay left pending delivery evidence"
  pass "conflicting crash replay delivers only its persisted winner"
}

test_historical_conflict_preserves_pending_delivery() {
  local home out queue_file next_file
  home=$(make_home stale-conflict-delivery)
  run_q "$home" add --id card-a --question "First question?" >/dev/null
  jq -nc \
    --arg id card-a \
    --arg answer "persisted answer" \
    --arg at 2026-08-27T17:59:59Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  queue_file="$home/data/captain-queue.json"
  next_file="$home/data/captain-queue.next"
  jq --arg stamp "$NOW" '
    .records[0] += {
      state: "resolved",
      answer: "persisted answer",
      resolved_at: $stamp
    }
    | .pending_reply_deliveries = [{
        line: 1,
        id: "card-a",
        generation: 1,
        answer: "persisted answer",
        kind: "handled"
      }]
  ' "$queue_file" > "$next_file"
  mv "$next_file" "$queue_file"
  run_q "$home" add --id card-a --question "Second question?" >/dev/null
  jq -nc \
    --arg id card-a \
    --arg answer "later stale answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=card-a] persisted answer" \
    "the persisted answer should survive a later stale conflict"
  assert_contains "$out" \
    "superseding: [id=card-a] [generation=1] later stale answer" \
    "the later prior-generation conflict should supersede the delivered answer"
  assert_contains "$out" "handled: [id=card-a] later stale answer" \
    "the historical supersession should be delivered after the pending answer"
  [ "$(cursor_value "$home")" = 2 ] \
    || fail "stale conflict should advance through both lines"
  jq -e '
    .records[0].state == "open"
    and .records[0].generation == 2
    and .records[0].question == "Second question?"
    and (.pending_reply_deliveries | length) == 0
  ' "$queue_file" >/dev/null \
    || fail "historical conflict changed the reopened card or retained pending evidence"
  pass "a historical conflict preserves and supersedes pending delivery"
}

test_pending_group_winner_is_not_superseding() {
  local home out queue_file next_file
  home=$(make_home pending-group-winner)
  run_q "$home" add --id card-a --question "Choose?" >/dev/null
  jq -nc \
    --arg id card-a \
    --arg answer "persisted before delivery" \
    --arg at 2026-08-27T17:59:59Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  queue_file="$home/data/captain-queue.json"
  next_file="$home/data/captain-queue.next"
  jq --arg stamp "$NOW" '
    .records[0] += {
      state: "resolved",
      answer: "persisted before delivery",
      resolved_at: $stamp
    }
    | .pending_reply_deliveries = [{
        line: 1,
        id: "card-a",
        generation: 1,
        answer: "persisted before delivery",
        kind: "handled"
      }]
  ' "$queue_file" > "$next_file"
  mv "$next_file" "$queue_file"
  jq -nc \
    --arg id card-a \
    --arg answer "newer pending winner" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "superseded: [id=card-a] [generation=1] [winner-line=2] persisted before delivery" \
    "the persisted loser should remain superseded evidence"
  assert_contains "$out" "handled: [id=card-a] newer pending winner" \
    "the pending group winner should be delivered"
  assert_not_contains "$out" "handled: [id=card-a] persisted before delivery" \
    "the pending loser must not be delivered"
  assert_not_contains "$out" "superseding: [id=card-a]" \
    "an answer that was only persisted must not count as previously delivered"
  [ "$(resolved_answer "$home" card-a)" = "newer pending winner" ] \
    || fail "the pending group winner was not persisted"
  jq -e '
    .delivered_reply_winners == [{
      line: 2,
      id: "card-a",
      generation: 1,
      answer: "newer pending winner",
      kind: "handled"
    }]
  ' "$queue_file" >/dev/null \
    || fail "the pending group winner was not recorded as the first delivery"
  pass "a newer pending-group winner does not claim to supersede an unseen answer"
}

test_superseding_delivery_replay_keeps_marker() {
  local home out queue_file next_file
  home=$(make_home superseding-replay)
  run_q "$home" add --id card-a --question "Choose?" >/dev/null
  jq -nc \
    --arg id card-a \
    --arg answer "first answer" \
    --arg at 2026-08-27T17:59:59Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  jq -nc \
    --arg id card-a \
    --arg answer "replacement answer" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  printf '1\n' > "$home/state/captain-replies.cursor"
  queue_file="$home/data/captain-queue.json"
  next_file="$home/data/captain-queue.next"
  jq --arg stamp "$NOW" '
    .records[0] += {
      state: "resolved",
      answer: "replacement answer",
      resolved_at: $stamp
    }
    | .pending_reply_deliveries = [{
        line: 2,
        id: "card-a",
        generation: 1,
        answer: "replacement answer",
        kind: "superseding"
      }]
  ' "$queue_file" > "$next_file"
  mv "$next_file" "$queue_file"

  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "superseding: [id=card-a] [generation=1] replacement answer" \
    "a replayed superseding delivery should keep its marker"
  assert_contains "$out" "handled: [id=card-a] replacement answer" \
    "a replayed superseding delivery should still be handled"
  [ "$(cursor_value "$home")" = 2 ] \
    || fail "superseding replay should advance the cursor"
  [ "$(jq '.pending_reply_deliveries | length' "$queue_file")" = 0 ] \
    || fail "superseding replay left pending delivery evidence"
  pass "a superseding delivery keeps its marker across crash replay"
}

test_repeat_answer_after_crash_advances_cursor() {
  local home out
  home=$(make_home crash-window)
  run_q "$home" add --id card-a --question "A?" >/dev/null
  append_reply "$home" card-a "yes a"
  run_q "$home" reconcile >/dev/null
  # Simulate the crash window: card already resolved, cursor rolled back.
  printf '0\n' > "$home/state/captain-replies.cursor"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=card-a] yes a" \
    "same already-resolved answer should replay as handled"
  [ "$(cursor_value "$home")" = 1 ] || fail "replay should advance the cursor, got $(cursor_value "$home")"
  [ -z "$(active_ids "$home")" ] || fail "replay put the card back on the board"
  pass "a replay of an already-resolved answer advances the cursor without dropping it"
}

test_reopened_card_skips_a_completed_reply_replay() {
  local home out
  home=$(make_home reopened-crash-replay)
  run_q "$home" add --id card-a --question "First question?" >/dev/null
  append_reply "$home" card-a "first answer"
  run_q "$home" reconcile >/dev/null
  printf '0\n' > "$home/state/captain-replies.cursor"
  run_q "$home" add --id card-a --question "Second question?" >/dev/null
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "stale: [id=card-a] [generation=1] first answer" \
    "the prior generation replay should be surfaced as stale"
  [ "$(cursor_value "$home")" = 1 ] \
    || fail "stale replay should advance the cursor, got $(cursor_value "$home")"
  jq -e '
    .records[0].id == "card-a"
    and .records[0].state == "open"
    and .records[0].generation == 2
    and .records[0].question == "Second question?"
    and (.records[0] | has("answer") | not)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "crash replay changed the reopened question"
  pass "a reopened card skips a completed reply replay from its prior generation"
}

test_reopened_card_delivers_a_reply_persisted_before_crash() {
  local home out queue_file next_file
  home=$(make_home reopened-persisted-reply)
  run_q "$home" add --id card-a --question "First question?" >/dev/null
  append_reply "$home" card-a "first answer"
  queue_file="$home/data/captain-queue.json"
  next_file="$home/data/captain-queue.next"
  jq --arg stamp "$NOW" '
    .records[0] += {
      state: "resolved",
      answer: "first answer",
      resolved_at: $stamp
    }
    | .pending_reply_deliveries = [{
        line: 1,
        id: "card-a",
        generation: 1,
        answer: "first answer"
      }]
  ' "$queue_file" > "$next_file"
  mv "$next_file" "$queue_file"

  run_q "$home" add --id card-a --question "Second question?" >/dev/null
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=card-a] first answer" \
    "the persisted prior-generation answer should still reach firstmate"
  assert_not_contains "$out" "stale:" \
    "a persisted but unsurfaced answer must not become stale after reopen"
  [ "$(cursor_value "$home")" = 1 ] \
    || fail "persisted reply should advance the cursor, got $(cursor_value "$home")"
  jq -e '
    .records[0].id == "card-a"
    and .records[0].state == "open"
    and .records[0].generation == 2
    and .records[0].question == "Second question?"
    and (.pending_reply_deliveries | length) == 0
  ' "$queue_file" >/dev/null \
    || fail "delivery replay changed the reopened card or retained delivered evidence"
  pass "a reopen preserves and delivers an answer persisted before a crash"
}

test_reopened_card_surfaces_a_historical_supersession_without_blocking() {
  local home out
  home=$(make_home reopened-delayed-reply)
  run_q "$home" add --id card-a --question "First question?" >/dev/null
  append_reply "$home" card-a "first answer"
  run_q "$home" reconcile >/dev/null
  run_q "$home" add --id card-a --question "Second question?" >/dev/null
  append_reply "$home" card-a "late first answer" 1
  append_reply "$home" card-a "second answer" 2
  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "superseding: [id=card-a] [generation=1] late first answer" \
    "the newer historical answer should be marked superseding"
  assert_contains "$out" "handled: [id=card-a] late first answer" \
    "the historical supersession should be delivered once"
  assert_contains "$out" "handled: [id=card-a] second answer" \
    "the current reply should not stay blocked behind a stale reply"
  [ "$(cursor_value "$home")" = 3 ] \
    || fail "cursor should advance past stale and current replies, got $(cursor_value "$home")"
  [ "$(resolved_answer "$home" card-a)" = "second answer" ] \
    || fail "the historical supersession changed the current generation answer"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "historical supersession was delivered more than once: $out"
  pass "historical supersession is delivered without changing the reopened card"
}

test_replacing_an_open_ask_rotates_its_generation() {
  local home out
  home=$(make_home replaced-open-ask)
  run_q "$home" add --id card-a --question "First question?" >/dev/null
  append_reply "$home" card-a "answer from first render" 1
  run_q "$home" add --id card-a --question "Replacement question?" >/dev/null
  append_reply "$home" card-a "replacement answer" 2
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "stale: [id=card-a] [generation=1] answer from first render" \
    "the replaced ask should reject its earlier rendered reply"
  assert_contains "$out" "handled: [id=card-a] replacement answer" \
    "the replacement ask should accept its own reply"
  [ "$(resolved_answer "$home" card-a)" = "replacement answer" ] \
    || fail "the replaced open ask accepted an earlier generation"
  pass "replacing an open ask rotates its generation"
}

test_partial_last_line_without_newline_is_handled() {
  local home out json
  home=$(make_home partial-last)
  run_q "$home" add --id hold-1 --question "A?" >/dev/null
  json=$(jq -nc --arg id hold-1 --arg answer yes --arg at "$NOW" \
    '{id: $id, generation: 1, answer: $answer, at: $at}')
  printf '%s' "$json" > "$home/state/captain-replies.jsonl"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=hold-1] yes" \
    "a last reply without a trailing newline should still be handled"
  [ -z "$(active_ids "$home")" ] || fail "partial last line left the card on the board"
  [ "$(resolved_answer "$home" hold-1)" = yes ] \
    || fail "partial last line lost the answer"
  [ "$(cursor_value "$home")" = 1 ] || fail "cursor should advance past the partial last line, got $(cursor_value "$home")"
  pass "a last reply without a trailing newline is handled"
}

test_parallel_adds_keep_both_cards() {
  local home round ids pid_a pid_b rc_a rc_b
  home=$(make_home parallel-add)
  for round in 1 2 3 4 5; do
    rm -f "$home/data/captain-queue.json"
    run_q "$home" add --id "card-a-$round" --question "A$round?" >/dev/null &
    pid_a=$!
    run_q "$home" add --id "card-b-$round" --question "B$round?" >/dev/null &
    pid_b=$!
    rc_a=0
    rc_b=0
    wait "$pid_a" || rc_a=$?
    wait "$pid_b" || rc_b=$?
    [ "$rc_a" -eq 0 ] || fail "parallel add round $round card-a exited $rc_a"
    [ "$rc_b" -eq 0 ] || fail "parallel add round $round card-b exited $rc_b"
    ids=$(active_ids "$home")
    case "$ids" in
      *"card-a-$round"*) : ;;
      *) fail "parallel add round $round lost card-a-$round: $ids" ;;
    esac
    case "$ids" in
      *"card-b-$round"*) : ;;
      *) fail "parallel add round $round lost card-b-$round: $ids" ;;
    esac
  done
  pass "parallel adds keep both cards"
}

have_tasks_axi() {
  command -v tasks-axi >/dev/null 2>&1
}

seed_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

backlog_add() {  # <home> <id> <title>
  tasks-axi add "$2" "$3" --kind captain --repo sample --file "$1/data/backlog.md" >/dev/null
}

backlog_done() {  # <home> <id>
  tasks-axi "done" "$2" --file "$1/data/backlog.md" >/dev/null
}

make_failing_tasks_axi() {  # <fakebin>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'temporary backlog read failure' >&2
exit 1
SH
  chmod +x "$1/tasks-axi"
}

test_legacy_repost_preserves_bounded_expiry() {
  local home fakebin out
  home=$(make_home live-migration)
  jq -n '{
    updated_at: "2026-08-20T18:00:00Z",
    items: [{
      id: "legacy-live-question",
      num: 7,
      question: "Old question",
      context: "Created before backing state was recorded.",
      commands: [],
      options: ["Yes", "No"],
      asked_at: "2026-08-20T18:00:00Z",
      status: "open",
      project: "sample"
    }],
    resolved: []
  }' > "$home/data/captain-queue.json"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- legacy-live-question - Work filed after the legacy card
EOF
  fakebin=$(fm_fakebin "$home")
  make_failing_tasks_axi "$fakebin"
  PATH="$fakebin:$PATH" run_q "$home" add \
    --id legacy-live-question \
    --question "Updated legacy question" \
    --asked-at "$NOW" >/dev/null
  jq -e '
    (.records | length) == 1
    and .records[0].state == "open"
    and .records[0].id == "legacy-live-question"
    and .records[0].num == 7
    and .records[0].question == "Updated legacy question"
    and .records[0].asked_at == "2026-08-20T18:00:00Z"
    and (.records[0] | has("backlog_backed") | not)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "ordinary repost changed the legacy card's migration state or expiry anchor"
  out=$(PATH="$fakebin:$PATH" run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=legacy-live-question] expired-legacy-backing" \
    "legacy repost should retain the original bounded expiry"
  [ "$(parked_ids "$home")" = legacy-live-question ] \
    || fail "legacy repost escaped its bounded expiry"
  pass "legacy repost preserves its original bounded expiry"
}

test_done_backlog_item_clears_card_without_a_reply() {
  local home out
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (done-item auto-clear)"
    return 0
  fi
  home=$(make_home done-item)
  seed_backlog "$home"
  backlog_add "$home" sample-origin-decision-prod-gate "Ship on merge?"
  run_q "$home" add \
    --id sample-origin-decision-prod-gate \
    --question "Ship on merge?" >/dev/null
  out=$(run_q "$home" reconcile)
  [ "$(active_ids "$home")" = sample-origin-decision-prod-gate ] \
    || fail "open backlog item should leave the card on the board: $(active_ids "$home")"
  [ -z "$out" ] || fail "reconcile with an open item and no replies should be silent, got: $out"
  backlog_done "$home" sample-origin-decision-prod-gate
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "cleared: [id=sample-origin-decision-prod-gate] backlog-done" \
    "reconcile should print cleared for a done backlog item"
  [ -z "$(active_ids "$home")" ] || fail "done backlog item left the card on the board: $(active_ids "$home")"
  [ "$(resolved_answer "$home" sample-origin-decision-prod-gate)" = backlog-done ] \
    || fail "auto-cleared card lost the cleared marker"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "caught-up auto-clear should be silent, got: $out"
  pass "a card auto-clears when its backlog item is marked done"
}

test_legacy_missing_backing_ignores_done_collision_and_expires() {
  local home fakebin out
  home=$(make_home legacy-done)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] legacy-done-card - Completed legacy work (repo: sample) (kind: captain)
EOF
  jq -n '{
    updated_at: "2026-08-20T18:00:00Z",
    items: [{
      id: "legacy-done-card",
      num: 1,
      question: "Legacy completed question?",
      asked_at: "2026-08-20T18:00:00Z",
      status: "open"
    }],
    resolved: [],
    parked: []
  }' > "$home/data/captain-queue.json"
  fakebin=$(fm_fakebin "$home")
  make_failing_tasks_axi "$fakebin"
  out=$(PATH="$fakebin:$PATH" run_q "$home" reconcile)
  assert_not_contains "$out" "cleared:" \
    "same-id done work must not resolve a legacy card with unknown backing"
  assert_contains "$out" "parked: [id=legacy-done-card] expired-legacy-backing" \
    "an aged legacy card should use its bounded expiry path"
  [ "$(parked_ids "$home")" = legacy-done-card ] \
    || fail "legacy card did not remain visible in the parked group"
  [ -z "$(resolved_answer "$home" legacy-done-card)" ] \
    || fail "same-id done work resolved the legacy card"
  pass "legacy unknown backing ignores done collisions and expires to parked"
}

test_only_done_cards_auto_clear() {
  local home out ids
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (mixed done/open auto-clear)"
    return 0
  fi
  home=$(make_home mixed-done)
  seed_backlog "$home"
  backlog_add "$home" card-open "Still open?"
  backlog_add "$home" card-done "Already decided?"
  run_q "$home" add --id card-open --question "Still open?" >/dev/null
  run_q "$home" add --id card-done --question "Already decided?" >/dev/null
  backlog_done "$home" card-done
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "cleared: [id=card-done] backlog-done" \
    "the done card should auto-clear"
  assert_not_contains "$out" "card-open" "an open card must not be mentioned"
  ids=$(active_ids "$home")
  case "$ids" in
    *card-open*) : ;;
    *) fail "open card was removed: $ids" ;;
  esac
  case "$ids" in
    *card-done*) fail "done card stayed on the board: $ids" ;;
  esac
  [ "$(resolved_answer "$home" card-done)" = backlog-done ] \
    || fail "done card was not moved to resolved"
  pass "only cards whose backlog item is done auto-clear"
}

test_dashboard_reply_after_auto_clear_does_not_orphan() {
  local home out rc
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (dashboard reply after auto-clear)"
    return 0
  fi
  home=$(make_home reply-after-clear)
  seed_backlog "$home"
  backlog_add "$home" card-c "Ship on merge?"
  run_q "$home" add --id card-c --question "Ship on merge?" >/dev/null
  backlog_done "$home" card-c
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "cleared: [id=card-c] backlog-done" \
    "the done card should auto-clear before the late reply"
  [ "$(resolved_answer "$home" card-c)" = backlog-done ] \
    || fail "auto-clear did not store backlog-done"
  append_reply "$home" card-c "Done - command ran"
  run_q "$home" add --id card-d --question "Later?" >/dev/null
  append_reply "$home" card-d "yes d"
  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 0 ] || fail "late reply after auto-clear should exit 0, got $rc"
  assert_contains "$out" "handled: [id=card-c] Done - command ran" \
    "a late dashboard answer after auto-clear should still print handled"
  assert_contains "$out" "handled: [id=card-d] yes d" \
    "later replies must not stay blocked behind the late auto-cleared id"
  assert_not_contains "$out" "orphan:" "late reply after auto-clear must not orphan"
  [ "$(cursor_value "$home")" = 2 ] || fail "cursor should advance past both replies, got $(cursor_value "$home")"
  [ "$(resolved_answer "$home" card-c)" = backlog-done ] \
    || fail "late dashboard answer overwrote the stored backlog-done resolve"
  [ -z "$(active_ids "$home")" ] || fail "later card stayed on the board: $(active_ids "$home")"
  append_reply "$home" card-c "Do the other thing"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" \
    "superseding: [id=card-c] [generation=1] Do the other thing" \
    "a later conflict after a handled auto-clear reply should be marked superseding"
  assert_contains "$out" "handled: [id=card-c] Do the other thing" \
    "the later conflict should still be delivered"
  [ "$(resolved_answer "$home" card-c)" = backlog-done ] \
    || fail "superseding dashboard answer overwrote the stored backlog-done resolve"
  pass "auto-cleared cards distinguish first replies from later superseding answers"
}

test_backlog_done_winner_after_orphan_supersedes_delivered_answer() {
  local home out rc queue_file next_file
  home=$(make_home backlog-done-orphan-conflict)
  run_q "$home" add --id card-c --question "Ship?" >/dev/null
  queue_file="$home/data/captain-queue.json"
  next_file="$home/data/captain-queue.next"
  jq --arg stamp "$NOW" '
    .records[0] += {
      state: "resolved",
      answer: "backlog-done",
      resolved_at: $stamp
    }
  ' "$queue_file" > "$next_file"
  mv "$next_file" "$queue_file"
  jq -nc \
    --arg id card-c \
    --arg answer "older unseen answer" \
    --arg at 2026-08-27T17:59:58Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"
  append_reply "$home" missing-card "orphan answer"
  jq -nc \
    --arg id card-c \
    --arg answer "newer answer after orphan" \
    --arg at 2026-08-27T18:00:00Z \
    '{id: $id, generation: 1, answer: $answer, at: $at}' \
    >> "$home/state/captain-replies.jsonl"

  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 1 ] || fail "orphan-separated backlog conflict should exit 1, got $rc"
  assert_contains "$out" "handled: [id=card-c] older unseen answer" \
    "the reply before the orphan should be delivered in order"
  assert_not_contains "$out" "winner-line=3" \
    "the orphan must delimit the conflict group"
  run_q "$home" add --id missing-card --question "Recovered orphan?" >/dev/null
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=missing-card] orphan answer" \
    "the recovered orphan should advance"
  assert_contains "$out" "handled: [id=card-c] newer answer after orphan" \
    "the backlog-done winner should be delivered after the orphan"
  assert_contains "$out" "superseding: [id=card-c]" \
    "the later answer supersedes the answer already delivered before the orphan"
  [ "$(resolved_answer "$home" card-c)" = backlog-done ] \
    || fail "the backlog-done marker was overwritten"
  pass "a backlog-done winner after an orphan supersedes the delivered earlier answer"
}

test_dashboard_reply_still_clears_when_backlog_item_is_open() {
  local home out
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (dashboard reply with open item)"
    return 0
  fi
  home=$(make_home reply-open)
  seed_backlog "$home"
  backlog_add "$home" card-a "Ship on merge?"
  run_q "$home" add --id card-a --question "Ship on merge?" >/dev/null
  append_reply "$home" card-a "option 1"
  out=$(run_q "$home" reconcile)
  assert_contains "$out" "handled: [id=card-a] option 1" \
    "an open backlog item must still accept a dashboard reply"
  assert_not_contains "$out" "cleared:" "a dashboard answer is not an auto-clear"
  [ -z "$(active_ids "$home")" ] || fail "dashboard reply left the card on the board"
  [ "$(resolved_answer "$home" card-a)" = "option 1" ] \
    || fail "dashboard answer was replaced by auto-clear"
  pass "a dashboard reply still clears an open-item card and keeps the answer"
}

test_parked_reply_resolves_and_preserves_history() {
  local home out rc
  home=$(make_home parked-reply)
  run_q "$home" add \
    --id parked-card \
    --question "Old unanswered question?" \
    --asked-at 2026-08-01T18:00:00Z >/dev/null
  run_q "$home" reconcile >/dev/null
  run_q "$home" add --id later-card --question "Later question?" >/dev/null
  append_reply "$home" parked-card "Answer after parking"
  append_reply "$home" later-card "Later answer"
  rc=0
  out=$(run_q "$home" reconcile) || rc=$?
  [ "$rc" -eq 0 ] || fail "a parked answer should reconcile, got $rc"
  assert_contains "$out" "handled: [id=parked-card] Answer after parking" \
    "a parked card should accept its answer"
  assert_contains "$out" "handled: [id=later-card] Later answer" \
    "a parked answer must not block later replies"
  [ "$(cursor_value "$home")" = 2 ] || fail "cursor did not advance past both replies"
  [ -z "$(parked_ids "$home")" ] || fail "answered parked card stayed parked"
  jq -e '
    .records[]
    | select(.id == "parked-card" and .state == "resolved")
    | .answer == "Answer after parking"
      and .parked_reason == "expired-unbacked"
      and (.parked_at | length > 0)
      and (.parked_note | length > 0)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "resolved card lost its parked history"
  out=$(run_q "$home" park --id parked-card --note "Verified settled after answer")
  assert_contains "$out" "parked: [id=parked-card] already-parked" \
    "repeating park after an answer should remain an idempotent no-op"
  rc=0
  out=$(run_q "$home" add --id parked-card --question "Ask again" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "re-adding an answered parked card should exit 1, got $rc"
  assert_contains "$out" "card already parked: parked-card" \
    "answered parked history should block resurrection"
  [ -z "$(active_ids "$home")" ] || fail "answered parked card was resurrected"
  [ "$(jq '[.records[] | select(.id == "parked-card" and .state == "resolved")] | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "refused re-add changed resolved parked history"
  pass "an answered parked card stays resolved and cannot be resurrected"
}

test_add_uses_the_supplied_id
test_writer_persists_one_canonical_record_per_card
test_unbacked_card_expires_to_parked
test_unbacked_card_stays_active_before_expiry
test_reposting_preserves_the_expiry_anchor
test_asked_at_is_normalized_or_rejected
test_legacy_offset_asked_at_expires
test_fractional_legacy_asked_at_expires
test_expiry_preserves_card_and_is_idempotent
test_manual_park_defers_a_fresh_unbacked_card
test_legacy_card_waits_for_verified_migration
test_legacy_duplicate_id_prefers_visible_state_over_timestamp
test_legacy_same_state_duplicate_compares_offset_timestamps
test_legacy_reopen_uses_successor_generation
test_future_legacy_anchor_gets_one_fresh_window
test_malformed_legacy_anchor_gets_one_fresh_window
test_add_reconstructs_consumed_reply_history
test_park_reconstructs_consumed_reply_history
test_legacy_backlog_done_history_reconstructs_dashboard_delivery
test_consumed_legacy_reply_never_redelivers
test_manual_park_rejects_backed_and_unknown_cards
test_matched_reply_removes_the_card_and_keeps_the_answer
test_reconcile_handles_a_queue_larger_than_one_process_argument
test_orphan_reply_does_not_advance_or_drop
test_orphan_stops_before_a_later_match
test_conflict_ranking_sees_winner_after_orphan
test_reply_behind_orphan_delivers_after_orphan_clears
test_conflicting_replies_rank_timestamp_then_log_order
test_conflicting_reply_crash_replay_delivers_only_the_winner
test_historical_conflict_preserves_pending_delivery
test_pending_group_winner_is_not_superseding
test_superseding_delivery_replay_keeps_marker
test_repeat_answer_after_crash_advances_cursor
test_reopened_card_skips_a_completed_reply_replay
test_reopened_card_delivers_a_reply_persisted_before_crash
test_reopened_card_surfaces_a_historical_supersession_without_blocking
test_replacing_an_open_ask_rotates_its_generation
test_partial_last_line_without_newline_is_handled
test_parallel_adds_keep_both_cards
test_backed_card_does_not_expire
test_backlog_fallback_avoids_unknown_state
test_repost_preserves_unknown_add_time_backing
test_later_done_item_does_not_resolve_an_unbacked_card
test_resolved_card_id_reopens_without_parked_history
test_legacy_repost_preserves_bounded_expiry
test_done_backlog_item_clears_card_without_a_reply
test_legacy_missing_backing_ignores_done_collision_and_expires
test_only_done_cards_auto_clear
test_dashboard_reply_after_auto_clear_does_not_orphan
test_backlog_done_winner_after_orphan_supersedes_delivered_answer
test_dashboard_reply_still_clears_when_backlog_item_is_open
test_parked_reply_resolves_and_preserves_history

echo "# fm-captain-queue.test.sh: all assertions passed"
