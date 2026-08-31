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

append_reply() {  # <home> <id> <answer>
  local home=$1
  jq -nc --arg id "$2" --arg answer "$3" --arg at "$NOW" \
    '{id: $id, answer: $answer, at: $at}' >> "$home/state/captain-replies.jsonl"
}

active_ids() {  # <home>
  jq -r '.items[]?.id' "$1/data/captain-queue.json" 2>/dev/null || true
}

resolved_answer() {  # <home> <id>
  jq -r --arg id "$2" '.resolved[] | select(.id == $id) | .answer' \
    "$1/data/captain-queue.json"
}

parked_ids() {  # <home>
  jq -r '.parked[]?.id' "$1/data/captain-queue.json" 2>/dev/null || true
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
  [ "$(jq -r '.items[0].id' "$home/data/captain-queue.json")" = \
    sample-origin-decision-prod-gate ] \
    || fail "card id was not the supplied hold identity"
  [ "$(jq -r '.items[0].status' "$home/data/captain-queue.json")" = open ] \
    || fail "new card should be open"
  pass "add writes a card under the supplied hold identity"
}

test_unbacked_card_expires_to_parked() {
  local home out
  home=$(make_home unbacked-expiry)
  run_q "$home" add \
    --id urgent-unbacked-question \
    --question "Approve the emergency change?" \
    --asked-at 2026-08-20T18:00:00Z >/dev/null
  [ "$(jq -r '.items[0].backlog_backed' "$home/data/captain-queue.json")" = false ] \
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
    .items[0].asked_at == "2026-08-20T18:00:00Z"
    and .items[0].backlog_backed == false
    and .items[0].question == "Updated question"
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
  [ "$(jq -r '.items[0].asked_at' "$home/data/captain-queue.json")" = 2026-08-20T18:00:00Z ] \
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
    (.items | length) == 0
    and (.resolved | length) == 0
    and (.parked | length) == 1
    and .parked[0].id == "full-unbacked-question"
    and .parked[0].question == "Which release should ship?"
    and .parked[0].context == "Production is waiting."
    and .parked[0].project == "sample"
    and .parked[0].asked_at == "2026-08-20T17:59:59Z"
    and .parked[0].options == ["Ship A", "Ship B"]
    and .parked[0].commands == ["deploy-a", "deploy-b"]
    and .parked[0].status == "parked"
    and .parked[0].parked_reason == "expired-unbacked"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "expiry did not preserve the card body in a distinct parked group"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "reconcile mentioned an already parked card: $out"
  [ "$(jq '.parked | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "reconcile re-parked an already parked card"
  [ -z "$(active_ids "$home")" ] || fail "reconcile resurrected an already parked card"
  pass "expiry preserves the full card in parked and never re-parks or resurrects it"
}

test_manual_park_supports_verified_migration() {
  local home out rc
  home=$(make_home manual-park)
  run_q "$home" add \
    --id settled-existing-question \
    --question "Proceed with cutover?" \
    --context "The cutover has since completed." \
    --asked-at 2026-08-26T18:00:00Z \
    --option "Proceed" \
    --option "Wait" >/dev/null
  out=$(run_q "$home" park \
    --id settled-existing-question \
    --note "Verified settled on 2026-08-27")
  assert_contains "$out" "parked: [id=settled-existing-question] manual" \
    "manual park should report the migrated card"
  [ -z "$(active_ids "$home")" ] || fail "manual park left the migrated card active"
  jq -e '
    (.parked | length) == 1
    and .parked[0].id == "settled-existing-question"
    and .parked[0].question == "Proceed with cutover?"
    and .parked[0].context == "The cutover has since completed."
    and .parked[0].asked_at == "2026-08-26T18:00:00Z"
    and .parked[0].options == ["Proceed", "Wait"]
    and .parked[0].parked_reason == "manual"
    and .parked[0].parked_note == "Verified settled on 2026-08-27"
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "manual park did not preserve the verified card and migration note"
  out=$(run_q "$home" park \
    --id settled-existing-question \
    --note "Verified settled on 2026-08-27")
  assert_contains "$out" "parked: [id=settled-existing-question] already-parked" \
    "repeating manual park should report an idempotent no-op"
  [ "$(jq '.parked | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "repeating manual park duplicated the card"
  rc=0
  run_q "$home" add \
    --id settled-existing-question \
    --question "Ask this again" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "add should refuse to resurrect a parked card, got $rc"
  [ -z "$(active_ids "$home")" ] || fail "add resurrected a parked card"
  [ "$(jq '.parked | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "refused add changed the parked card"
  pass "manual park supports a repeat-safe human-verified migration with a note"
}

test_legacy_card_waits_for_verified_migration() {
  local home out
  home=$(make_home legacy-card)
  jq -n '{
    updated_at: "2026-08-01T18:00:00Z",
    items: [{
      id: "legacy-question",
      num: 1,
      question: "Is this still needed?",
      context: "Created before backing state was recorded.",
      commands: [],
      options: ["Yes", "No"],
      asked_at: "2026-08-01T18:00:00Z",
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
  pass "a legacy card waits for human verification and then allows manual migration"
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
  [ "$(jq -r '.items[0].backlog_backed' "$home/data/captain-queue.json")" = true ] \
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
    any(.items[]; .id == "fallback-backed-question" and .backlog_backed == true)
    and any(.items[]; .id == "fallback-unbacked-question" and .backlog_backed == false)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "the readable backlog fallback did not record definite backing states"
  out=$(PATH="$fakebin:$PATH" run_q "$home" reconcile)
  assert_contains "$out" "parked: [id=fallback-unbacked-question] expired-unbacked" \
    "the fallback-classified unbacked card should expire"
  [ "$(active_ids "$home")" = fallback-backed-question ] \
    || fail "the fallback-classified backed card did not remain active"
  pass "a readable backlog keeps backing state definite during tool failure"
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
  [ "$(jq '.resolved | length' "$home/data/captain-queue.json")" -eq 0 ] \
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

test_partial_last_line_without_newline_is_handled() {
  local home out json
  home=$(make_home partial-last)
  run_q "$home" add --id hold-1 --question "A?" >/dev/null
  json=$(jq -nc --arg id hold-1 --arg answer yes --arg at "$NOW" \
    '{id: $id, answer: $answer, at: $at}')
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

test_verified_live_card_can_be_reposted_with_backing() {
  local home out
  if ! have_tasks_axi; then
    echo "skip: tasks-axi not found (verified live-card migration)"
    return 0
  fi
  home=$(make_home live-migration)
  seed_backlog "$home"
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
  backlog_add "$home" legacy-live-question "Track the verified live question"
  run_q "$home" add \
    --id legacy-live-question \
    --question "Verified live question" \
    --asked-at "$NOW" >/dev/null
  jq -e --arg now "$NOW" '
    (.items | length) == 1
    and .items[0].id == "legacy-live-question"
    and .items[0].num == 7
    and .items[0].question == "Verified live question"
    and .items[0].asked_at == $now
    and .items[0].backlog_backed == true
    and (.parked | length) == 0
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "re-post did not attach the verified live card to its new backlog item"
  out=$(run_q "$home" reconcile)
  [ -z "$out" ] || fail "verified backed re-post should stay active: $out"
  [ "$(active_ids "$home")" = legacy-live-question ] \
    || fail "verified backed re-post left the active queue"
  pass "a verified live legacy card can be re-posted after its backing work is filed"
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

test_legacy_backed_done_card_still_clears() {
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
  assert_contains "$out" "cleared: [id=legacy-done-card] backlog-done" \
    "verified done work should retire a legacy card without a backing marker"
  [ -z "$(active_ids "$home")" ] || fail "legacy done card stayed active"
  [ "$(resolved_answer "$home" legacy-done-card)" = backlog-done ] \
    || fail "legacy done card did not record its retirement"
  pass "legacy backed cards still retire when their work is done"
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
  pass "a late dashboard reply after auto-clear prints handled, keeps backlog-done, and does not block later replies"
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
    .resolved[]
    | select(.id == "parked-card")
    | .answer == "Answer after parking"
      and .parked_reason == "expired-unbacked"
      and (.parked_at | length > 0)
      and (.parked_note | length > 0)
  ' "$home/data/captain-queue.json" >/dev/null \
    || fail "resolved card lost its parked history"
  rc=0
  out=$(run_q "$home" add --id parked-card --question "Ask again" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "re-adding an answered parked card should exit 1, got $rc"
  assert_contains "$out" "card already parked: parked-card" \
    "answered parked history should block resurrection"
  [ -z "$(active_ids "$home")" ] || fail "answered parked card was resurrected"
  [ "$(jq '[.resolved[] | select(.id == "parked-card")] | length' "$home/data/captain-queue.json")" -eq 1 ] \
    || fail "refused re-add changed resolved parked history"
  pass "an answered parked card stays resolved and cannot be resurrected"
}

test_add_uses_the_supplied_id
test_unbacked_card_expires_to_parked
test_unbacked_card_stays_active_before_expiry
test_reposting_preserves_the_expiry_anchor
test_asked_at_is_normalized_or_rejected
test_expiry_preserves_card_and_is_idempotent
test_manual_park_supports_verified_migration
test_legacy_card_waits_for_verified_migration
test_manual_park_rejects_backed_and_unknown_cards
test_matched_reply_removes_the_card_and_keeps_the_answer
test_orphan_reply_does_not_advance_or_drop
test_orphan_stops_before_a_later_match
test_repeat_answer_after_crash_advances_cursor
test_partial_last_line_without_newline_is_handled
test_parallel_adds_keep_both_cards
test_backed_card_does_not_expire
test_backlog_fallback_avoids_unknown_state
test_later_done_item_does_not_resolve_an_unbacked_card
test_verified_live_card_can_be_reposted_with_backing
test_done_backlog_item_clears_card_without_a_reply
test_legacy_backed_done_card_still_clears
test_only_done_cards_auto_clear
test_dashboard_reply_after_auto_clear_does_not_orphan
test_dashboard_reply_still_clears_when_backlog_item_is_open
test_parked_reply_resolves_and_preserves_history

echo "# fm-captain-queue.test.sh: all assertions passed"
