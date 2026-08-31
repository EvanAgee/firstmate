#!/usr/bin/env bash
# Behavior tests for the bounded reviewer chase inside the authenticated watcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

CHASE="$ROOT/bin/fm-pr-review-chase.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-chase-tests)
NOW=1788192000
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OLD_HEAD=cccccccccccccccccccccccccccccccccccccccc
URL=https://github.com/acme/widgets/pull/42

make_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/wt" "$case_dir/fakebin" "$case_dir/fake-root/bin"
  printf '0\n' > "$case_dir/base-count"
  printf '0\n' > "$case_dir/state-count"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
graphql_output() {
  encoded=$(printf '%s\n' "$1" | jq -Rr '@base64')
  printf 'api_response:\n  body: %s\n  truncated: false\n' "$encoded"
}
if [ "${1:-} ${2:-} ${3:-}" = "api POST /graphql" ]; then
  if [[ "$*" == *"reviews(first:100,"* ]]; then
    base_index=$(cat "$FM_TEST_BASE_COUNT")
    [ "$base_index" -gt 0 ] && base_index=$((base_index - 1))
    page_index=0
    [[ "$*" == *'after:"cursor-1"'* ]] && page_index=1
    body=$(jq -c --argjson base "$base_index" --argjson page "$page_index" \
      '.snapshots[$base].reviewPages[$page] // .snapshots[-1].reviewPages[$page]' \
      "$FM_TEST_GRAPHQL_RESPONSE")
    graphql_output "$body"
    exit 0
  fi
  base_index=$(cat "$FM_TEST_BASE_COUNT")
  snapshot_count=$(jq '.snapshots | length' "$FM_TEST_GRAPHQL_RESPONSE")
  next_index=$((base_index + 1))
  printf '%s\n' "$next_index" > "$FM_TEST_BASE_COUNT"
  [ "$base_index" -lt "$snapshot_count" ] || base_index=$((snapshot_count - 1))
  body=$(jq -c --argjson base "$base_index" '.snapshots[$base]' "$FM_TEST_GRAPHQL_RESPONSE")
  graphql_output "$body"
  exit 0
fi
case "${1:-} ${2:-}" in
  "api DELETE") exit "${FM_TEST_DELETE_RC:-0}" ;;
  "api POST") exit "${FM_TEST_POST_RC:-0}" ;;
esac
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  *"--json headRefOid"*)
    printf '%s\n' "$FM_TEST_HEAD"
    ;;
  *"--json state"*)
    index=$(cat "$FM_TEST_STATE_COUNT")
    value=$(sed -n "$((index + 1))p" "$FM_TEST_STATE_SEQUENCE")
    [ -n "$value" ] || value=$(tail -1 "$FM_TEST_STATE_SEQUENCE")
    printf '%s\n' "$((index + 1))" > "$FM_TEST_STATE_COUNT"
    printf '%s\n' "$value"
    ;;
  "pr edit "*|"label create "*)
    exit 0
    ;;
esac
SH
  cat > "$case_dir/fake-root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh" \
    "$case_dir/fake-root/bin/fm-guard.sh"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

write_response() {
  local file=$1 head=$2 check_state=$3 unresolved=$4 reviewers=$5 review_head=$6
  local is_draft=${7:-false} mergeable=${8:-MERGEABLE}
  local merge_state=${9:-BLOCKED} review_decision=${10:-REVIEW_REQUIRED}
  jq -n \
    --arg url "$URL" \
    --arg head "$head" \
    --arg check_state "$check_state" \
    --argjson unresolved "$unresolved" \
    --arg reviewers "$reviewers" \
    --arg review_head "$review_head" \
    --argjson is_draft "$is_draft" \
    --arg mergeable "$mergeable" \
    --arg merge_state "$merge_state" \
    --arg review_decision "$review_decision" \
    --arg submitted "2030-01-01T00:00:00Z" \
    '($reviewers | if length == 0 then [] else split(",") end) as $logins
    | ($logins | map({requestedReviewer:{__typename:"User",login:.}})) as $requests
    | (if ($logins | length) == 0 then []
       else [{author:{login:$logins[0]},submittedAt:$submitted,commit:{oid:$review_head}}]
       end) as $reviews
    | {snapshots:[{
        state:"OPEN",
        url:$url,
        headRefOid:$head,
        isDraft:$is_draft,
        mergeable:$mergeable,
        mergeStateStatus:$merge_state,
        reviewDecision:$review_decision,
        commits:{nodes:[{commit:{oid:$head,statusCheckRollup:{state:$check_state}}}]},
        reviewThreads:{totalCount:$unresolved,nodes:[range(0;$unresolved)|{isResolved:false}]},
        reviewRequests:{totalCount:($requests|length),nodes:$requests},
        reviewPages:[{nodes:$reviews,pageInfo:{hasNextPage:false,endCursor:null}}]
      }]}' > "$file"
}

reset_graphql() {
  printf '0\n' > "$1/base-count"
}

run_chase() {
  local case_dir=$1 now=$2
  FM_PR_REVIEW_CHASE_NOW="$now" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GRAPHQL_RESPONSE="$case_dir/response.json" \
  FM_TEST_BASE_COUNT="$case_dir/base-count" \
  FM_TEST_DELETE_RC="${FM_TEST_DELETE_RC:-0}" \
  FM_TEST_POST_RC="${FM_TEST_POST_RC:-0}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CHASE" --validated "$case_dir/home/state" task-a github \
      "$URL" github.com acme/widgets 42
}

request_count() {
  local method=$1 log=$2 reviewer=${3:-aos-tester1}
  grep -c "^api $method repos/acme/widgets/pulls/42/requested_reviewers --field reviewers\[\]=$reviewer$" \
    "$log" 2>/dev/null || true
}

assert_state() {
  local file=$1 count=$2 escalated=$3 in_flight=$4
  [ "$(sed -n '4p' "$file")" = "$count" ] || fail "chase state stored the wrong completed count"
  [ "$(sed -n '6p' "$file")" = "$escalated" ] || fail "chase state stored the wrong escalation flag"
  [ "$(sed -n '7p' "$file")" = "$in_flight" ] || fail "chase state stored the wrong in-flight reviewer"
}

observe_head() {
  local case_dir=$1 now=$2 out
  reset_graphql "$case_dir"
  out=$(run_chase "$case_dir" "$now") || fail "head observation failed"
  [ -z "$out" ] || fail "head observation woke firstmate: $out"
}

test_quiet_clock_starts_at_observation() {
  local case_dir
  case_dir=$(make_case observed-clock)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  observe_head "$case_dir" "$NOW"
  run_chase "$case_dir" "$((NOW + 21599))" >/dev/null || fail "under-six-hour pass failed"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 0 ] \
    || fail "a newly observed old commit was chased before six hours"
  run_chase "$case_dir" "$((NOW + 21600))" >/dev/null || fail "six-hour chase failed"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "six quiet hours did not trigger one reviewer removal"
  [ "$(request_count POST "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "six quiet hours did not restore the reviewer"
  assert_state "$case_dir/home/state/task-a.pr-review-chase" 1 0 -
  pass "quiet time starts when firstmate observes the head"
}

test_new_head_resets_observation_and_count() {
  local case_dir
  case_dir=$(make_case head-reset)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  observe_head "$case_dir" "$NOW"
  run_chase "$case_dir" "$((NOW + 21600))" >/dev/null || fail "first-head chase failed"

  write_response "$case_dir/response.json" "$HEAD_B" SUCCESS 0 aos-tester1 "$HEAD_A"
  observe_head "$case_dir" "$((NOW + 21601))"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "a new head inherited the old head's quiet time"
  run_chase "$case_dir" "$((NOW + 43201))" >/dev/null || fail "new-head chase failed"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "the new head did not start its own chase"
  [ "$(sed -n '2p' "$case_dir/home/state/task-a.pr-review-chase")" = "$HEAD_B" ] \
    || fail "the chase state did not move to the new head"
  assert_state "$case_dir/home/state/task-a.pr-review-chase" 1 0 -
  pass "a new head resets its quiet clock and request count"
}

test_head_limits_survive_reviewer_replacement() {
  local case_dir out
  case_dir=$(make_case reviewer-replacement)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 reviewer-a "$OLD_HEAD"
  observe_head "$case_dir" "$NOW"
  run_chase "$case_dir" "$((NOW + 21600))" >/dev/null || fail "first reviewer chase failed"

  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 reviewer-b "$OLD_HEAD"
  reset_graphql "$case_dir"
  run_chase "$case_dir" "$((NOW + 43200))" >/dev/null || fail "replacement reviewer chase failed"
  run_chase "$case_dir" "$((NOW + 64800))" >/dev/null || fail "third head chase failed"
  out=$(run_chase "$case_dir" "$((NOW + 86400))") || fail "head escalation failed"
  case "$out" in
    *"$URL"*"24.0 hours"*) ;;
    *) fail "head escalation omitted the URL or elapsed wait: $out" ;;
  esac
  [ "$(request_count DELETE "$case_dir/gh-axi.log" reviewer-a)" -eq 1 ] \
    || fail "the first reviewer was not chased once"
  [ "$(request_count DELETE "$case_dir/gh-axi.log" reviewer-b)" -eq 2 ] \
    || fail "reviewer replacement reset or broke the head cap"
  assert_state "$case_dir/home/state/task-a.pr-review-chase" 3 1 -
  out=$(run_chase "$case_dir" "$((NOW + 90000))") || fail "repeat escalation pass failed"
  [ -z "$out" ] || fail "the same head escalated twice: $out"
  pass "request and escalation limits belong to the head"
}

test_only_the_review_blocker_is_eligible() {
  local case_dir kind
  for kind in red unresolved no-request multiple draft conflict behind current-review; do
    case_dir=$(make_case "ineligible-$kind")
    case "$kind" in
      red) write_response "$case_dir/response.json" "$HEAD_A" FAILURE 0 aos-tester1 "$OLD_HEAD" ;;
      unresolved) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 1 aos-tester1 "$OLD_HEAD" ;;
      no-request) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 '' "$OLD_HEAD" ;;
      multiple) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 reviewer-a,reviewer-b "$OLD_HEAD" ;;
      draft) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD" true ;;
      conflict) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD" false CONFLICTING DIRTY ;;
      behind) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD" false MERGEABLE BEHIND ;;
      current-review) write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$HEAD_A" ;;
    esac
    observe_head "$case_dir" "$NOW"
    run_chase "$case_dir" "$((NOW + 25200))" >/dev/null || fail "$kind eligibility pass failed"
    [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 0 ] \
      || fail "$kind pull request lost a reviewer request"
  done
  pass "drafts, conflicts, red checks, extra blockers, and invalid review states are untouched"
}

test_review_history_is_paginated() {
  local case_dir fixture_tmp
  case_dir=$(make_case paginated-reviews)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  fixture_tmp="$case_dir/response.tmp"
  jq --arg old "$OLD_HEAD" '
    .snapshots[0].reviewPages = [
      {
        nodes:[{author:{login:"aos-tester1"},submittedAt:"2029-12-01T00:00:00Z",commit:{oid:$old}}],
        pageInfo:{hasNextPage:true,endCursor:"cursor-1"}
      },
      {
        nodes:[{author:{login:"aos-tester1"},submittedAt:"2030-01-01T00:00:00Z",commit:{oid:$old}}],
        pageInfo:{hasNextPage:false,endCursor:null}
      }
    ]
  ' "$case_dir/response.json" > "$fixture_tmp" && mv "$fixture_tmp" "$case_dir/response.json"
  observe_head "$case_dir" "$NOW"
  run_chase "$case_dir" "$((NOW + 21600))" >/dev/null || fail "paginated review chase failed"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "the reviewer's later history page was ignored"
  [ "$(grep -c 'after:"cursor-1"' "$case_dir/gh-axi.log")" -ge 1 ] \
    || fail "the review history did not fetch its next page"
  pass "the pending reviewer's full history determines eligibility"
}

test_mutation_revalidation_rejects_a_new_red_state() {
  local case_dir green red combined
  case_dir=$(make_case mutation-race)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  observe_head "$case_dir" "$NOW"
  green="$case_dir/green.json"
  red="$case_dir/red.json"
  combined="$case_dir/combined.json"
  write_response "$green" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  write_response "$red" "$HEAD_A" FAILURE 0 aos-tester1 "$OLD_HEAD"
  jq -s '{snapshots:[.[0].snapshots[0],.[1].snapshots[0]]}' "$green" "$red" > "$combined"
  mv "$combined" "$case_dir/response.json"
  reset_graphql "$case_dir"
  run_chase "$case_dir" "$((NOW + 21600))" >/dev/null || fail "race revalidation failed"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 0 ] \
    || fail "a pull request that turned red was mutated"
  assert_state "$case_dir/home/state/task-a.pr-review-chase" 0 0 -
  pass "eligibility is rechecked at the reviewer mutation"
}

test_interrupted_request_is_restored_before_state_advances() {
  local case_dir out
  case_dir=$(make_case interrupted-request)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  observe_head "$case_dir" "$NOW"
  out=$(FM_TEST_POST_RC=1 run_chase "$case_dir" "$((NOW + 21600))") \
    || fail "interrupted request pass failed"
  case "$out" in
    *"while restoring the request"*) ;;
    *) fail "failed restoration was not surfaced: $out" ;;
  esac
  assert_state "$case_dir/home/state/task-a.pr-review-chase" 0 0 aos-tester1

  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 '' "$OLD_HEAD"
  reset_graphql "$case_dir"
  out=$(run_chase "$case_dir" "$((NOW + 21900))") || fail "restoration retry failed"
  [ -z "$out" ] || fail "successful restoration woke firstmate: $out"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "recovery repeated the reviewer removal"
  [ "$(request_count POST "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "recovery did not restore the missing reviewer"
  assert_state "$case_dir/home/state/task-a.pr-review-chase" 1 0 -
  pass "an interrupted request is restored before its count advances"
}

run_watcher_bounded() {
  local case_dir=$1
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
      FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_PR_REVIEW_CHASE_NOW="$((NOW + 21600))" \
      FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
      FM_TEST_GH_LOG="$case_dir/gh.log" \
      FM_TEST_GRAPHQL_RESPONSE="$case_dir/response.json" \
      FM_TEST_BASE_COUNT="$case_dir/base-count" \
      FM_TEST_HEAD="$HEAD_A" \
      FM_TEST_STATE_SEQUENCE="$case_dir/state-sequence" \
      FM_TEST_STATE_COUNT="$case_dir/state-count" \
      PATH="$case_dir/fakebin:$PATH" "$WATCH"
}

test_authenticated_watcher_runs_only_the_request_pair() {
  local case_dir rc
  case_dir=$(make_case watcher-integration)
  write_response "$case_dir/response.json" "$HEAD_A" SUCCESS 0 aos-tester1 "$OLD_HEAD"
  observe_head "$case_dir" "$NOW"
  fm_write_meta "$case_dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  FM_ROOT_OVERRIDE="$case_dir/fake-root" \
  FM_HOME="$case_dir/home" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_HEAD="$HEAD_A" \
  FM_TEST_STATE_SEQUENCE="$case_dir/state-sequence" \
  FM_TEST_STATE_COUNT="$case_dir/state-count" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-a "$URL" >/dev/null 2>&1 || fail "authenticated PR watch did not arm"
  fm_pr_poll_artifacts_valid "$case_dir/home/state" task-a "$POLL" \
    || fail "the watcher integration did not use an authenticated poll"

  printf 'OPEN\nMERGED\n' > "$case_dir/state-sequence"
  printf '0\n' > "$case_dir/state-count"
  reset_graphql "$case_dir"
  set +e
  run_watcher_bounded "$case_dir" > "$case_dir/watch.out" 2> "$case_dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "authenticated watcher pass failed: $(cat "$case_dir/watch.err")"
  [ "$(request_count DELETE "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "the authenticated watcher did not remove the stale request once"
  [ "$(request_count POST "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "the authenticated watcher did not restore the stale request once"
  if grep -E '^api (PUT|PATCH|POST|DELETE) .*pulls/[0-9]+/(merge|reviews)( |$)' \
    "$case_dir/gh-axi.log" >/dev/null 2>&1; then
    fail "the reviewer chase approved, merged, or dismissed a review"
  fi
  if grep -E '^pr (merge|review) ' "$case_dir/gh.log" >/dev/null 2>&1; then
    fail "the watcher used a merge or review command"
  fi
  pass "the authenticated watcher only re-requests the stale reviewer"
}

test_quiet_clock_starts_at_observation
test_new_head_resets_observation_and_count
test_head_limits_survive_reviewer_replacement
test_only_the_review_blocker_is_eligible
test_review_history_is_paginated
test_mutation_revalidation_rejects_a_new_red_state
test_interrupted_request_is_restored_before_state_advances
test_authenticated_watcher_runs_only_the_request_pair
