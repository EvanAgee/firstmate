#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: firstmate's guarded local fast-forward merge.
# It lands a local-only task as before, and additionally lands a normally-PR-bound
# task onto the local default branch ONLY while GitHub is unreachable
# (state/.github-down present), recording each such landing in the outage-landings
# reconciliation ledger.
#
# Matrix:
#   (a) a PR-bound (mode=no-mistakes) task is REFUSED when the outage flag is
#       ABSENT, and the message points to the normal PR flow
#   (b) a PR-bound yolo=on task is ACCEPTED (fast-forward only) when the outage
#       flag is PRESENT and an adversarial review is recorded, the lane branch is
#       resolved from the task worktree, and a ledger line records the landing
#       with before/after SHAs, deferred checks, and the review evidence
#   (c) a diverged branch ESCALATES (REFUSED) rather than forcing, leaving the
#       default branch untouched - even during an outage
#   (d) a local-only task still lands by a clean fast-forward (back-compat) and
#       writes NO ledger entry (it never owed GitHub a round-trip)
#   (e) a yolo=on outage auto-land is REFUSED without the adversarial-review proof
#       (the second-review gate), and the default branch is left untouched
#   (f) a yolo=off outage landing is captain-approved and lands WITHOUT the review
#       gate (the captain is the authority for a yolo=off landing)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# Point the tangle/watcher guard at an inert non-git dir so fm-guard.sh's banners
# stay silent during these merges (same trick the wake suites use). fm-merge-local
# still resolves the real bin/ via SCRIPT_DIR, independent of FM_ROOT_OVERRIDE.
INERT_ROOT=$(fm_test_tmproot fm-merge-local-inert)

# Build a project repo whose default branch is `main` with one commit and a lane
# branch that is a clean fast-forward ahead of it. Echoes "PROJ<TAB>LANE".
make_project_ff() {  # <name> <lane-branch>
  local name=$1 lane=$2 proj
  proj="$TMP_ROOT/$name/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
  git -C "$proj" branch -M main
  git -C "$proj" checkout -q -b "$lane"
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m lanework
  git -C "$proj" checkout -q main
  printf '%s\t%s\n' "$proj" "$lane"
}

run_merge() {  # <state> [args...]
  local state=$1; shift
  FM_ROOT_OVERRIDE="$INERT_ROOT" FM_STATE_OVERRIDE="$state" "$MERGE" "$@"
}

test_pr_bound_refused_without_outage_flag() {
  local state proj lane
  state="$TMP_ROOT/pr-no-flag/state"
  mkdir -p "$state"
  IFS=$(printf '\t') read -r proj lane < <(make_project_ff pr-no-flag ticket-1)
  fm_write_meta "$state/t1.meta" "project=$proj" "mode=no-mistakes" "yolo=on"

  set +e
  run_merge "$state" t1 "$lane" > "$TMP_ROOT/pr-no-flag/out" 2> "$TMP_ROOT/pr-no-flag/err"
  local rc=$?
  set -e
  expect_code 1 "$rc" "pr-no-flag: a PR-bound task must be refused when GitHub is up"
  assert_grep 'lands locally only while GitHub is unreachable' "$TMP_ROOT/pr-no-flag/err" \
    "pr-no-flag: refusal did not explain the outage condition"
  assert_grep 'fm-pr-merge.sh' "$TMP_ROOT/pr-no-flag/err" \
    "pr-no-flag: refusal did not point to the normal PR merge"
  # The default branch must be untouched.
  git -C "$proj" merge-base --is-ancestor "$lane" main 2>/dev/null \
    && fail "pr-no-flag: the lane was merged into main despite the refusal"
  pass "fm-merge-local refuses a PR-bound task when the outage flag is absent"
}

test_pr_bound_accepted_during_outage_records_ledger() {
  local state proj lane before after
  state="$TMP_ROOT/pr-outage/state"
  mkdir -p "$state"
  IFS=$(printf '\t') read -r proj lane < <(make_project_ff pr-outage ticket-2)
  # Worktree checked out on the lane branch, so the lane resolves from meta with
  # no explicit branch argument.
  local wt="$TMP_ROOT/pr-outage/wt"
  git -C "$proj" worktree add -q "$wt" "$lane"
  fm_write_meta "$state/t2.meta" "project=$proj" "mode=no-mistakes" "yolo=on" "worktree=$wt"
  touch "$state/.github-down"
  before=$(git -C "$proj" rev-parse main)

  run_merge "$state" t2 --deferred-checks 'a11y.yml,smoke.yml' \
    --adversarial-review-passed 'report:data/adversarial-t2/report.md' \
    > "$TMP_ROOT/pr-outage/out" 2> "$TMP_ROOT/pr-outage/err" \
    || fail "pr-outage: outage landing failed: $(cat "$TMP_ROOT/pr-outage/err")"

  after=$(git -C "$proj" rev-parse main)
  [ "$before" != "$after" ] || fail "pr-outage: main did not advance"
  git -C "$proj" merge-base --is-ancestor "$lane" main \
    || fail "pr-outage: the lane branch is not on main after the landing"

  local ledger="$state/outage-landings/proj.log"
  assert_present "$ledger" "pr-outage: no reconciliation ledger was written"
  assert_grep "$after" "$ledger" "pr-outage: ledger is missing the after SHA"
  assert_grep 'a11y.yml,smoke.yml' "$ledger" "pr-outage: ledger is missing the deferred checks"
  assert_grep "$lane" "$ledger" "pr-outage: ledger is missing the lane branch"
  assert_grep 'report:data/adversarial-t2/report.md' "$ledger" \
    "pr-outage: ledger is missing the adversarial review evidence"
  pass "fm-merge-local lands a PR-bound task during an outage and records the ledger"
}

test_yolo_on_auto_land_refused_without_review() {
  local state proj lane wt main_before rc
  state="$TMP_ROOT/no-review/state"
  mkdir -p "$state"
  IFS=$(printf '\t') read -r proj lane < <(make_project_ff no-review ticket-9)
  wt="$TMP_ROOT/no-review/wt"
  git -C "$proj" worktree add -q "$wt" "$lane"
  fm_write_meta "$state/t9.meta" "project=$proj" "mode=no-mistakes" "yolo=on" "worktree=$wt"
  touch "$state/.github-down"
  main_before=$(git -C "$proj" rev-parse main)

  set +e
  run_merge "$state" t9 > "$TMP_ROOT/no-review/out" 2> "$TMP_ROOT/no-review/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-review: a yolo=on auto-land must be refused without an adversarial review"
  assert_grep 'adversarial review' "$TMP_ROOT/no-review/err" \
    "no-review: refusal did not name the missing adversarial review"
  [ "$(git -C "$proj" rev-parse main)" = "$main_before" ] \
    || fail "no-review: main advanced despite the missing-review refusal"
  assert_absent "$state/outage-landings/proj.log" \
    "no-review: a refused auto-land should write no ledger entry"
  pass "fm-merge-local refuses a yolo=on outage auto-land without the adversarial-review proof"
}

test_yolo_off_lands_without_review_gate() {
  local state proj lane wt before after
  state="$TMP_ROOT/yolo-off/state"
  mkdir -p "$state"
  IFS=$(printf '\t') read -r proj lane < <(make_project_ff yolo-off ticket-10)
  wt="$TMP_ROOT/yolo-off/wt"
  git -C "$proj" worktree add -q "$wt" "$lane"
  # yolo=off: firstmate only calls this after the captain approves, so the review
  # gate does not apply and the landing proceeds with no review flag.
  fm_write_meta "$state/t10.meta" "project=$proj" "mode=no-mistakes" "yolo=off" "worktree=$wt"
  touch "$state/.github-down"
  before=$(git -C "$proj" rev-parse main)

  run_merge "$state" t10 > "$TMP_ROOT/yolo-off/out" 2> "$TMP_ROOT/yolo-off/err" \
    || fail "yolo-off: captain-approved landing failed: $(cat "$TMP_ROOT/yolo-off/err")"

  after=$(git -C "$proj" rev-parse main)
  [ "$before" != "$after" ] || fail "yolo-off: main did not advance"
  assert_present "$state/outage-landings/proj.log" \
    "yolo-off: an outage landing should still record the ledger"
  pass "fm-merge-local lands a yolo=off captain-approved outage landing without the review gate"
}

test_diverged_branch_escalates_not_forces() {
  local state proj
  state="$TMP_ROOT/diverged/state"
  mkdir -p "$state"
  proj="$TMP_ROOT/diverged/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
  git -C "$proj" branch -M main
  # Lane branches off, commits; then main advances separately -> divergence.
  git -C "$proj" checkout -q -b fm/div
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m lane
  git -C "$proj" checkout -q main
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m mainmoved
  local main_before
  main_before=$(git -C "$proj" rev-parse main)
  fm_write_meta "$state/tdiv.meta" "project=$proj" "mode=no-mistakes" "yolo=on"
  touch "$state/.github-down"

  # Pass the review proof so the merge reaches the divergence check rather than
  # stopping earlier at the adversarial-review gate; this test targets divergence.
  set +e
  run_merge "$state" tdiv fm/div --adversarial-review-passed 'report:ok' \
    > "$TMP_ROOT/diverged/out" 2> "$TMP_ROOT/diverged/err"
  local rc=$?
  set -e
  expect_code 1 "$rc" "diverged: a diverged branch must be refused"
  assert_grep 'has diverged' "$TMP_ROOT/diverged/err" "diverged: refusal did not name the divergence"
  [ "$(git -C "$proj" rev-parse main)" = "$main_before" ] \
    || fail "diverged: main was moved despite the divergence refusal (should never force)"
  assert_absent "$state/outage-landings/proj.log" \
    "diverged: a refused merge should not write a ledger entry"
  pass "fm-merge-local escalates a diverged branch during an outage rather than forcing"
}

test_local_only_still_lands_no_ledger() {
  local state proj lane before after
  state="$TMP_ROOT/local-only/state"
  mkdir -p "$state"
  # A local-only task's lane is the legacy fm/<id> name.
  IFS=$(printf '\t') read -r proj lane < <(make_project_ff local-only fm/tloc)
  fm_write_meta "$state/tloc.meta" "project=$proj" "mode=local-only"
  before=$(git -C "$proj" rev-parse main)

  run_merge "$state" tloc > "$TMP_ROOT/local-only/out" 2> "$TMP_ROOT/local-only/err" \
    || fail "local-only: merge failed: $(cat "$TMP_ROOT/local-only/err")"

  after=$(git -C "$proj" rev-parse main)
  [ "$before" != "$after" ] || fail "local-only: main did not advance"
  assert_absent "$state/outage-landings/proj.log" \
    "local-only: a local-only landing must not write an outage ledger entry"
  pass "fm-merge-local still lands a local-only task with no ledger entry (back-compat)"
}

test_pr_bound_refused_without_outage_flag
test_pr_bound_accepted_during_outage_records_ledger
test_diverged_branch_escalates_not_forces
test_local_only_still_lands_no_ledger
test_yolo_on_auto_land_refused_without_review
test_yolo_off_lands_without_review_gate
