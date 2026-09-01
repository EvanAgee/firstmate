#!/usr/bin/env bash
# tests/fm-classify-decision-key.test.sh - decision-key position tolerance in
# the open-decisions fold (bin/fm-classify-lib.sh). A "[key=<slug>]" token is
# documented between the verb and the colon (needs-decision [key=x]: note), but
# workers commonly write the colon first (needs-decision: [key=x] note); that
# stated key must be honored, never silently folded into the shared "default"
# bucket where an answer can close the wrong record (issue #2109). Also covers
# status_line_verb's bracket-tag stripping: a remote secondmate reply prepends
# a "[corr=...]" correlation tag before (or without) "[key=...]", and every
# such tag before the colon must be stripped so the leading word is the bare
# verb, regardless of order or count. These tests drive the REAL
# status_line_verb / status_open_decisions / status_open_decisions_incremental
# functions over crafted status files and assert their folded output, never the
# fold's own source text. Cross-drain cursor persistence and the incremental
# cost bound live in tests/fm-wake-drain-open-decisions-cursor.test.sh; the
# drain wiring lives in tests/fm-wake-drain-open-decisions.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-key-tests)

# Fresh per-case dir so each case's incremental cursor sidecar cannot leak into
# another case.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold of <status-file> equals <expected>, and that the
# incremental fold agrees with it on the exact same input - the two consumption
# strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_stated_key_is_honored_in_both_positions() {
  local dir before after expected
  dir=$(case_dir positions)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$dir/after.status"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')

  assert_fold "$dir/before.status" "$expected" "documented before-colon form"
  assert_fold "$dir/after.status" "$expected" "colon-first form"

  # Equivalence is byte-for-byte: both positions yield the same key AND the
  # same note (a consumed note-head token is key metadata, not note text).
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two key positions folded to different records: '$before' vs '$after'"
  pass "a stated [key=X] opens X whether it precedes or follows the verb colon"
}

test_bare_keyless_line_still_folds_to_default() {
  local dir
  dir=$(case_dir keyless)
  printf 'needs-decision: which color\n' > "$dir/bare.status"
  assert_fold "$dir/bare.status" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "bare keyless line"

  # And a bare keyless resolution still closes it - the historical
  # one-open-decision-per-task behavior is unchanged.
  printf 'resolved: went with blue\n' >> "$dir/bare.status"
  assert_fold "$dir/bare.status" "" "bare keyless resolution"
  pass "a keyless needs-decision still opens and closes the default key"
}

test_resolution_closes_across_positions() {
  local dir
  dir=$(case_dir cross-close)
  # Opened colon-first, closed in the documented form (what fm-send's
  # --resolve-key writes): the exact failure from issue #2109.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing a colon-first open"

  # And the mirror: opened documented, closed colon-first.
  printf 'needs-decision [key=seam-max-bound]: pick the bound\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "colon-first resolution closing a documented open"
  pass "a resolution closes its decision regardless of either line's key position"
}

test_blocked_is_position_tolerant_like_needs_decision() {
  local dir expected
  dir=$(case_dir blocked)
  expected=$(printf 'creds\tblocked\twaiting on the deploy token\n')
  printf 'blocked [key=creds]: waiting on the deploy token\n' > "$dir/before.status"
  printf 'blocked: [key=creds] waiting on the deploy token\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "$expected" "documented blocked form"
  assert_fold "$dir/after.status" "$expected" "colon-first blocked form"
  pass "blocked [key=X] opens X in both key positions"
}

test_two_colon_form_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir distinct)
  # The concrete hazard behind the silent collapse: two colon-form decisions on
  # one task used to share the default bucket, so answering one could close the
  # other. They must stay independently open and independently closable.
  printf 'needs-decision: [key=alpha] first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=beta] second question\n' >> "$dir/t.status"
  expected=$(printf 'alpha\tneeds-decision\tfirst question\nbeta\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two colon-form decisions"

  printf 'resolved [key=alpha]: answered: yes\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "$(printf 'beta\tneeds-decision\tsecond question\n')" \
    "closing one of two colon-form decisions"
  pass "two colon-form keyed decisions never collapse into one shared bucket"
}

test_multiple_mid_note_keys_are_not_guessed() {
  local dir
  dir=$(case_dir prose)
  # Two interior canonical tokens are ambiguous. Keep the historical default
  # record instead of choosing one key and letting an answer close the wrong
  # decision.
  printf 'needs-decision: should docs mention [key=red] or [key=blue]?\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tshould docs mention [key=red] or [key=blue]?\n')" \
    "punctuated mid-note prose mention"

  printf 'needs-decision [key=red]: which shade\n' >> "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tshould docs mention [key=red] or [key=blue]?\nred\tneeds-decision\twhich shade\n')" \
    "prose mention leaves the open set untouched"
  pass "punctuation after a complete key preserves multiple-key ambiguity"
}

test_interior_cleanup_removes_the_accepted_occurrence() {
  local dir
  dir=$(case_dir accepted-occurrence)
  printf '%s\n' \
    'needs-decision: compare x[key=route] prose, then choose [key=route]: A or B' \
    > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'route\tneeds-decision\tcompare x[key=route] prose, then choose: A or B\n')" \
    "accepted interior key occurrence"
  pass "note cleanup removes the accepted key occurrence and keeps its lookalike"
}

test_malformed_positional_key_does_not_hide_valid_mid_note_key() {
  local dir
  dir=$(case_dir malformed-positional-valid-mid-note)
  printf '%s\n' \
    'needs-decision: [key=bad key] review found [key=review-labels]: choose the labels' \
    > "$dir/head.status"
  assert_fold "$dir/head.status" \
    "$(printf 'review-labels\tneeds-decision\t[key=bad key] review found: choose the labels\n')" \
    "malformed head before one valid canonical mid-note key"
  printf '%s\n' \
    'needs-decision [key=bad key]: review found [key=review-labels]: choose the labels' \
    > "$dir/before.status"
  assert_fold "$dir/before.status" \
    "$(printf 'review-labels\tneeds-decision\treview found: choose the labels\n')" \
    "malformed before-colon key before one valid canonical mid-note key"
  pass "a malformed positional key cannot hide the only valid canonical mid-note key"
}

test_malformed_head_does_not_break_mid_note_ambiguity() {
  local dir
  dir=$(case_dir malformed-head-ambiguous-mid-note)
  printf '%s\n' \
    'needs-decision: [key=bad key] pick a [key=red] or [key=blue] theme' \
    > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\t[key=bad key] pick a [key=red] or [key=blue] theme\n')" \
    "malformed head before multiple valid canonical mid-note keys"
  pass "multiple valid mid-note keys stay ambiguous after a malformed head"
}

test_malformed_stated_key_never_collapses_to_default() {
  local dir
  dir=$(case_dir malformed)
  # A stated-but-invalid slug is rejected in BOTH positions - identically,
  # and never rewritten into the shared default bucket.
  printf 'needs-decision [key=bad key]: before-colon malformed\n' > "$dir/before.status"
  printf 'needs-decision: [key=bad key] colon-first malformed\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "" "malformed before-colon key"
  assert_fold "$dir/after.status" "" "malformed colon-first key"
  pass "a malformed stated key is rejected in both positions, never folded as default"
}

# A remote secondmate reply routinely prepends a "[corr=<hex>]" correlation
# tag ahead of "[key=...]" (issue: a remote reply's "needs-decision
# [corr=d448ea86afa4bf67] [key=x]: ..." folded to no open decision at all,
# because the verb parser only stripped a leading "[key=...]" token and left
# the corr tag glued onto the returned verb word). These cases drive the real
# status_line_verb directly, over every bracket-tag shape that precedes the
# colon, to pin the general fix: strip EVERY "[name=value]" tag there, not
# just "[key=...]", regardless of order or count.
test_status_line_verb_strips_every_bracket_tag_before_colon() {
  local v

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-then-key tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [key=loan-installment-cadence-amount] [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "key-then-corr tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-only tag: got '$v'"

  v=$(status_line_verb 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token')
  [ "$v" = "blocked" ] || fail "blocked with corr+key: got '$v'"

  v=$(status_line_verb 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated')
  [ "$v" = "resolved" ] || fail "resolved with corr+key: got '$v'"

  pass "status_line_verb strips every bracket tag before the colon, in any order, and recovers the bare verb"
}

test_corr_and_key_tags_open_and_close_under_the_stated_key() {
  local dir expected
  dir=$(case_dir corr-and-key)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$dir/t.status"
  expected=$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')
  assert_fold "$dir/t.status" "$expected" "corr-then-key opens under the stated key"

  printf 'resolved [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: answered: monthly\n' \
    >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "corr-then-key resolution closes the same stated key"
  pass "a [corr=...] tag ahead of [key=...] no longer swallows the verb: opens and closes under the stated key"
}

test_corr_only_tag_opens_as_default_like_a_bare_line() {
  local dir bare corred
  dir=$(case_dir corr-only)
  printf 'needs-decision: which vendor\n' > "$dir/bare.status"
  printf 'needs-decision [corr=d448ea86afa4bf67]: which vendor\n' > "$dir/corred.status"

  bare=$(status_open_decisions "$dir/bare.status")
  corred=$(status_open_decisions "$dir/corred.status")
  [ "$corred" = "$bare" ] \
    || fail "a corr-only tag folded differently than the bare line: '$corred' vs '$bare'"
  assert_fold "$dir/corred.status" "$(printf 'default\tneeds-decision\twhich vendor\n')" "corr-only tag"
  pass "a [corr=...] tag with no stated key opens under 'default', exactly like a bare needs-decision line"
}

test_key_only_before_colon_still_opens_no_regression() {
  local dir
  dir=$(case_dir key-only-no-corr)
  printf 'needs-decision [key=loan-installment-cadence-amount]: pick the cadence\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')" \
    "key-only before colon, no corr tag"
  pass "a [key=x] tag alone (no corr tag) still opens x - no regression from the tag-stripping fix"
}

test_blocked_and_resolved_are_tag_order_independent() {
  local dir
  dir=$(case_dir blocked-tag-order)
  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/a.status"
  assert_fold "$dir/a.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked corr-then-key"

  printf 'blocked [key=creds] [corr=aaaa1111bbbb2222]: waiting on the deploy token\n' > "$dir/b.status"
  assert_fold "$dir/b.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked key-then-corr"

  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/c.status"
  printf 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated\n' >> "$dir/c.status"
  assert_fold "$dir/c.status" "" "blocked/resolved corr+key close together regardless of tag order"
  pass "blocked/resolved parse their bare verb with any bracket-tag order preceding the colon"
}

# Item 6 regression pair (2026-08-21 captain repro in the real home): a worker
# habitually writes the key as the LAST token of the note
# (blocked: ... [key=nm-openai-credits]) or as a bare bracket token instead of
# the canonical [key=<slug>] form (needs-decision [died-resume-fold]: ...).
# Those lines opened under "default", so fm-send --resolve-key refused the key
# the drain kept printing forever - the two consumers visibly disagreed. The
# ONE fold now states the key at either position/form, so both consumers agree.
test_trailing_note_token_is_a_stated_key() {
  local dir expected
  dir=$(case_dir trailing-key)
  printf 'blocked: the pipeline daemon is out of credits and the user cannot add credits [key=nm-openai-credits]\n' > "$dir/t.status"
  expected=$(printf 'nm-openai-credits\tblocked\tthe pipeline daemon is out of credits and the user cannot add credits\n')
  assert_fold "$dir/t.status" "$expected" "trailing note-head [key=X] states and strips"

  # The canonical resolution fm-send --resolve-key writes closes it.
  printf 'resolved [key=nm-openai-credits]: answered: captain refilled\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "canonical resolution closes a trailing-key open"
  pass "a [key=X] token as the LAST token of the note states the key, never 'default'"
}

test_bare_bracket_token_is_a_stated_key() {
  local dir expected
  dir=$(case_dir bare-bracket-key)
  printf 'needs-decision [died-resume-fold]: reviewer flagged TurnDied double-render\n' > "$dir/t.status"
  expected=$(printf 'died-resume-fold\tneeds-decision\treviewer flagged TurnDied double-render\n')
  assert_fold "$dir/t.status" "$expected" "bare [slug] before the colon states the key"

  printf 'resolved [died-resume-fold]: firstmate: option A - fold suspend/resume\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "bare [slug] resolution closes a bare open"
  pass "a bare [slug] token states the key in the documented and closing forms"
}

test_unique_canonical_mid_note_key_is_stated() {
  local dir
  dir=$(case_dir unique-mid-note)
  printf '%s\n' \
    'needs-decision: fix-review found 2 new ask-user findings [key=169-noun-and-grade-labels]: choose the noun and grade labels' \
    > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf '169-noun-and-grade-labels\tneeds-decision\tfix-review found 2 new ask-user findings: choose the noun and grade labels\n')" \
    "unique canonical mid-note key"
  pass "the pto-export-window-ui mid-sentence key opens under its stated key"
}

test_blocked_unique_mid_note_key_is_stated() {
  local dir
  dir=$(case_dir blocked-unique-mid-note)
  printf 'blocked: deploy review failed [key=deploy-token]: waiting for a fresh token\n' \
    > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'deploy-token\tblocked\tdeploy review failed: waiting for a fresh token\n')" \
    "blocked unique canonical mid-note key"
  pass "a blocked line accepts one canonical key inside its note"
}

test_invalid_lookalike_before_valid_mid_note_key_is_ignored() {
  local dir
  dir=$(case_dir invalid-before-valid-mid-note)
  printf '%s\n' \
    'needs-decision: review mentions [key=bad key] before its finding [key=review-labels]: choose the labels' \
    > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'review-labels\tneeds-decision\treview mentions [key=bad key] before its finding: choose the labels\n')" \
    "invalid lookalike before one valid canonical mid-note key"
  printf 'resolved [key=review-labels]: labels chosen\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "valid key after invalid lookalike closes normally"
  pass "an invalid key lookalike cannot hide the only valid canonical key"
}

test_v7_cursor_that_skipped_valid_key_is_rebuilt() {
  local dir f cf ident size expected got
  dir=$(case_dir stale-v7-invalid-before-valid)
  f="$dir/t.status"
  cf=$(_fm_open_decisions_cursor_path "$f")
  printf '%s\n' \
    'needs-decision: [key=bad key] review found [key=review-labels]: choose the labels' \
    > "$f"
  ident=$(_fm_open_decisions_file_ident "$f")
  [ -n "$ident" ] || fail "could not read status-file identity for the planted v7 cursor"
  size=$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')
  {
    printf 'version=7\n'
    printf 'offset=%s\n' "$size"
    printf 'ident=%s\n' "$ident"
  } > "$cf"
  expected=$(printf 'review-labels\tneeds-decision\t[key=bad key] review found: choose the labels\n')
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$expected" ] \
    || fail "stale v7 cursor was kept: got '$got' want '$expected'"
  pass "a v7 cursor that skipped a valid key after a malformed head is rebuilt"
}

test_v8_cursor_that_chose_one_punctuated_key_is_rebuilt() {
  local dir f cf ident size expected got
  dir=$(case_dir stale-v8-punctuated-ambiguity)
  f="$dir/t.status"
  cf=$(_fm_open_decisions_cursor_path "$f")
  printf 'needs-decision: should docs mention [key=prose] or [key=example]?\n' > "$f"
  ident=$(_fm_open_decisions_file_ident "$f")
  [ -n "$ident" ] || fail "could not read status-file identity for the planted v8 cursor"
  size=$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')
  {
    printf 'version=8\n'
    printf 'offset=%s\n' "$size"
    printf 'ident=%s\n' "$ident"
    printf 'prose\tneeds-decision\tshould docs mention or [key=example]?\n'
  } > "$cf"
  expected=$(printf 'default\tneeds-decision\tshould docs mention [key=prose] or [key=example]?\n')
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$expected" ] \
    || fail "stale v8 cursor was kept: got '$got' want '$expected'"
  pass "a v8 cursor that chose one punctuated key is rebuilt"
}

test_v5_cursor_holding_default_for_mid_sentence_key_is_rebuilt() {
  local dir f cf ident size expected got
  dir=$(case_dir stale-v5-mid-sentence)
  f="$dir/t.status"
  cf=$(_fm_open_decisions_cursor_path "$f")
  printf '%s\n' \
    'needs-decision: fix-review found 2 new ask-user findings [key=169-noun-and-grade-labels]: choose the noun and grade labels' \
    > "$f"
  ident=$(_fm_open_decisions_file_ident "$f")
  [ -n "$ident" ] || fail "could not read status-file identity for the planted v5 cursor"
  size=$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')
  {
    printf 'version=5\n'
    printf 'offset=%s\n' "$size"
    printf 'ident=%s\n' "$ident"
    printf 'default\tneeds-decision\tfix-review found 2 new ask-user findings [key=169-noun-and-grade-labels]: choose the noun and grade labels\n'
  } > "$cf"
  expected=$(printf '169-noun-and-grade-labels\tneeds-decision\tfix-review found 2 new ask-user findings: choose the noun and grade labels\n')
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$expected" ] \
    || fail "stale v5 cursor was kept: got '$got' want '$expected'"
  pass "a v5 cursor holding the pto-export-window-ui ghost is rebuilt from its status log"
}

test_v4_cursor_holding_default_for_trailing_key_is_discarded() {
  local dir f cf ident size expected got
  dir=$(case_dir stale-v4-cursor)
  f="$dir/t.status"
  cf=$(_fm_open_decisions_cursor_path "$f")
  printf 'blocked: the pipeline daemon is out of credits and the user cannot add credits [key=nm-openai-credits]\n' > "$f"
  ident=$(_fm_open_decisions_file_ident "$f")
  [ -n "$ident" ] || fail "could not read status-file identity for the planted cursor"
  size=$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')
  # Plant the exact drain-vs-send disagreement: a version=4 cursor already at
  # EOF, so a same-version incremental fold would keep this default row and
  # never re-read the trailing-key line. After the grammar bump the cursor
  # must be discarded and rebuilt from byte 0.
  {
    printf 'version=4\n'
    printf 'offset=%s\n' "$size"
    printf 'ident=%s\n' "$ident"
    printf 'default\tblocked\tthe pipeline daemon is out of credits and the user cannot add credits [key=nm-openai-credits]\n'
  } > "$cf"
  expected=$(printf 'nm-openai-credits\tblocked\tthe pipeline daemon is out of credits and the user cannot add credits\n')
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$expected" ] \
    || fail "stale v4 cursor was kept: got '$got' want '$expected'"
  pass "a v4 cursor holding default for a trailing-key line is discarded after the fold-version bump"
}

test_incremental_agrees_with_full_fold_across_appends() {
  local dir f expected
  dir=$(case_dir incremental)
  f="$dir/t.status"
  # assert_fold already pins incremental==full per snapshot; this case pins the
  # agreement ACROSS appends, where the incremental path folds only the new
  # bytes on top of its persisted open set while the full fold re-reads
  # everything from scratch.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\n')
  assert_fold "$f" "$expected" "colon-first open, first read"

  printf 'working: routine progress note\n' >> "$f"
  printf 'needs-decision: [key=other] a second colon-form question\n' >> "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\nother\tneeds-decision\ta second colon-form question\n')
  assert_fold "$f" "$expected" "colon-first opens buried under later appends"

  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$f"
  printf 'resolved: [key=other] cleared on its own\n' >> "$f"
  assert_fold "$f" "" "cross-position resolutions close both"
  pass "the incremental fold matches the full fold across appends in both key positions"
}

# status_key_answered is affirmative answer evidence for one key: it returns true
# ONLY when an explicit resolved line closed that exact key, not when the key is
# merely absent from the open set and not for the captain-held transfer line. fm-decision-hold verify uses it
# so an answered hold trimmed out of the backlog still passes while a key that was
# never answered fails.
test_status_key_answered_requires_an_explicit_answer_line() {
  local dir
  dir=$(case_dir key-answered)

  printf 'needs-decision [key=choice]: pick A or B\n' > "$dir/resolved.status"
  printf 'resolved [key=choice]: captain picked A\n' >> "$dir/resolved.status"
  status_key_answered "$dir/resolved.status" choice \
    || fail "a resolved line was not read as an answer for its key"

  printf 'needs-decision: [key=choice] pick A or B\n' > "$dir/colon-first.status"
  printf 'resolved: [key=choice] captain picked A\n' >> "$dir/colon-first.status"
  status_key_answered "$dir/colon-first.status" choice \
    || fail "a colon-first resolved line was not read as an answer"

  # The captain-held transfer records where the decision now lives. It is written
  # for every reviewed key that is still open, so it is not answer evidence.
  printf 'needs-decision [key=choice]: pick A or B\n' > "$dir/held.status"
  printf 'captain-held [key=choice]: tracked by origin-decision-choice\n' >> "$dir/held.status"
  if status_key_answered "$dir/held.status" choice; then
    fail "a captain-held transfer alone was read as an answer"
  fi

  # Still open: no answer line for the key.
  printf 'needs-decision [key=choice]: pick A or B\ndone: report complete\n' > "$dir/open.status"
  if status_key_answered "$dir/open.status" choice; then
    fail "an open decision with a trailing done line was read as answered"
  fi

  # Never mentioned: the key does not appear in the status log at all.
  printf 'needs-decision [key=other]: pick X or Y\nresolved [key=other]: chose X\n' > "$dir/absent.status"
  if status_key_answered "$dir/absent.status" choice; then
    fail "a key that never appears in the status log was read as answered"
  fi

  # Missing status file: no evidence.
  if status_key_answered "$dir/nope.status" choice; then
    fail "a missing status file was read as answer evidence"
  fi

  # A resolved line for a different key must not answer this one.
  printf 'needs-decision [key=choice]: pick A or B\nresolved [key=elsewhere]: chose that\n' \
    > "$dir/wrong-key.status"
  if status_key_answered "$dir/wrong-key.status" choice; then
    fail "a resolved line for a different key was read as answering this one"
  fi
  pass "status_key_answered needs an explicit resolved line for the exact key"
}

# A decision key is stable and reusable, so the same key can be answered and then
# opened again for a second round on the same hold id. Only the key's final
# transition decides whether it is answered.
test_status_key_answered_follows_the_last_transition() {
  local dir
  dir=$(case_dir key-answered-reopen)

  {
    printf 'needs-decision [key=choice]: pick A or B\n'
    printf 'resolved [key=choice]: captain picked A\n'
    printf 'needs-decision [key=choice]: now pick C or D\n'
    printf 'done: report complete\n'
  } > "$dir/reopened.status"
  if status_key_answered "$dir/reopened.status" choice; then
    fail "a key re-opened after an earlier answer was still read as answered"
  fi

  {
    printf 'needs-decision [key=choice]: pick A or B\n'
    printf 'resolved [key=choice]: captain picked A\n'
    printf 'blocked [key=choice]: cannot proceed until the captain picks again\n'
  } > "$dir/reopened-blocked.status"
  if status_key_answered "$dir/reopened-blocked.status" choice; then
    fail "a key re-opened by a blocked line was still read as answered"
  fi

  {
    printf 'needs-decision [key=choice]: pick A or B\n'
    printf 'resolved [key=choice]: captain picked A\n'
    printf 'needs-decision [key=choice]: now pick C or D\n'
    printf 'resolved [key=choice]: captain picked C\n'
    printf 'done: report complete\n'
  } > "$dir/reanswered.status"
  status_key_answered "$dir/reanswered.status" choice \
    || fail "a key answered again after a re-open was not read as answered"

  # A captain-held transfer is bookkeeping: it must neither answer the key nor
  # erase an earlier real answer.
  {
    printf 'needs-decision [key=choice]: pick A or B\n'
    printf 'resolved [key=choice]: captain picked A\n'
    printf 'captain-held [key=choice]: tracked by origin-decision-choice\n'
  } > "$dir/answered-then-held.status"
  status_key_answered "$dir/answered-then-held.status" choice \
    || fail "a captain-held transfer erased an earlier real answer"

  # A re-open of a different key must not disturb this key's answered verdict.
  {
    printf 'needs-decision [key=choice]: pick A or B\n'
    printf 'resolved [key=choice]: captain picked A\n'
    printf 'needs-decision [key=elsewhere]: pick X or Y\n'
  } > "$dir/other-key-reopened.status"
  status_key_answered "$dir/other-key-reopened.status" choice \
    || fail "a re-open of a different key unset the answer for this key"
  pass "status_key_answered follows the last transition, so a re-open unanswers a key"
}

# The reserved-namespace guard the fold applies must apply here too: a resolved
# line whose note does not speak a reserved key's own vocabulary is not a valid
# transition and must not count as an answer.
test_status_key_answered_honors_the_reserved_key_guard() {
  local dir
  dir=$(case_dir key-answered-reserved)

  printf 'needs-decision [key=pending-reply-42]: pending-reply-42: awaiting the mate\n' \
    > "$dir/good.status"
  printf 'resolved [key=pending-reply-42]: pending-reply-42: the mate answered\n' \
    >> "$dir/good.status"
  status_key_answered "$dir/good.status" pending-reply-42 \
    || fail "a reserved-namespace resolution in its own vocabulary was not read as an answer"

  printf 'needs-decision [key=pending-reply-42]: pending-reply-42: awaiting the mate\n' \
    > "$dir/bad.status"
  printf 'resolved [key=pending-reply-42]: some unrelated note\n' >> "$dir/bad.status"
  if status_key_answered "$dir/bad.status" pending-reply-42; then
    fail "a reserved-key resolution with a foreign note was read as an answer"
  fi
  pass "status_key_answered applies the reserved-key namespace guard the fold uses"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_multiple_mid_note_keys_are_not_guessed
test_interior_cleanup_removes_the_accepted_occurrence
test_malformed_positional_key_does_not_hide_valid_mid_note_key
test_malformed_head_does_not_break_mid_note_ambiguity
test_malformed_stated_key_never_collapses_to_default
test_status_line_verb_strips_every_bracket_tag_before_colon
test_corr_and_key_tags_open_and_close_under_the_stated_key
test_corr_only_tag_opens_as_default_like_a_bare_line
test_key_only_before_colon_still_opens_no_regression
test_blocked_and_resolved_are_tag_order_independent
test_v5_cursor_holding_default_for_mid_sentence_key_is_rebuilt
test_v4_cursor_holding_default_for_trailing_key_is_discarded
test_incremental_agrees_with_full_fold_across_appends
test_trailing_note_token_is_a_stated_key
test_bare_bracket_token_is_a_stated_key
test_unique_canonical_mid_note_key_is_stated
test_blocked_unique_mid_note_key_is_stated
test_invalid_lookalike_before_valid_mid_note_key_is_ignored
test_v7_cursor_that_skipped_valid_key_is_rebuilt
test_v8_cursor_that_chose_one_punctuated_key_is_rebuilt
test_status_key_answered_requires_an_explicit_answer_line
test_status_key_answered_follows_the_last_transition
test_status_key_answered_honors_the_reserved_key_guard
