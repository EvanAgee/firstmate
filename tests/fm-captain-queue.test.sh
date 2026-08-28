#!/usr/bin/env bash
# tests/fm-captain-queue.test.sh - board cards share the reply id, reconcile
# removes a matched card, an unmatched reply neither advances the cursor
# nor disappears, and a card whose backlog item is done leaves without a reply.
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

test_add_uses_the_supplied_id
test_matched_reply_removes_the_card_and_keeps_the_answer
test_orphan_reply_does_not_advance_or_drop
test_orphan_stops_before_a_later_match
test_repeat_answer_after_crash_advances_cursor
test_partial_last_line_without_newline_is_handled
test_parallel_adds_keep_both_cards
test_done_backlog_item_clears_card_without_a_reply
test_only_done_cards_auto_clear
test_dashboard_reply_after_auto_clear_does_not_orphan
test_dashboard_reply_still_clears_when_backlog_item_is_open

echo "# fm-captain-queue.test.sh: all assertions passed"
