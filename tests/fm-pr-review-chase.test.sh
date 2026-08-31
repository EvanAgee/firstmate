#!/usr/bin/env bash
# Behavior tests for the bounded stale-review request chase that runs inside
# the existing per-task PR watcher pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHASE="$ROOT/bin/fm-pr-review-chase.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-chase-tests)
NOW=1788192000
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OLD_HEAD=cccccccccccccccccccccccccccccccccccccccc
URL=https://github.com/acme/widgets/pull/42

make_case() {
  local name=$1 case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-} ${2:-} ${3:-}" = "api POST /graphql" ]; then
  encoded=$(jq -c '.data.repository.pullRequest' "$FM_TEST_GRAPHQL_RESPONSE" | jq -Rr '@base64')
  printf 'api_response:\n  body: %s\n  truncated: false\n' "$encoded"
  exit 0
fi
case "${1:-} ${2:-}" in
  "api DELETE") exit "${FM_TEST_DELETE_RC:-0}" ;;
  "api POST") exit "${FM_TEST_POST_RC:-0}" ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

write_response() {
  local file=$1 head=$2 age=$3 check_state=$4 unresolved=$5 reviewer=$6 review_head=$7
  local head_epoch=$((NOW - age)) review_epoch=$((NOW - age - 60)) requests reviews
  if [ -n "$reviewer" ]; then
    requests=$(jq -cn --arg login "$reviewer" '[{requestedReviewer:{__typename:"User",login:$login}}]')
    reviews=$(jq -cn --arg login "$reviewer" --arg oid "$review_head" --argjson at "$review_epoch" \
      '[{author:{login:$login},state:"CHANGES_REQUESTED",submittedAt:($at|todateiso8601),commit:{oid:$oid}}]')
  else
    requests='[]'
    reviews='[]'
  fi
  jq -n \
    --arg url "$URL" \
    --arg head "$head" \
    --argjson head_epoch "$head_epoch" \
    --arg check_state "$check_state" \
    --argjson unresolved "$unresolved" \
    --argjson requests "$requests" \
    --argjson reviews "$reviews" \
    '{data:{repository:{pullRequest:{
      state:"OPEN",
      url:$url,
      headRefOid:$head,
      commits:{nodes:[{commit:{oid:$head,committedDate:($head_epoch|todateiso8601),statusCheckRollup:{state:$check_state}}}]},
      reviewThreads:{totalCount:$unresolved,nodes:[range(0;$unresolved)|{isResolved:false}]},
      reviewRequests:{totalCount:($requests|length),nodes:$requests},
      reviews:{nodes:$reviews}
    }}}}' > "$file"
}

run_chase() {
  local case_dir=$1 now=$2
  FM_PR_REVIEW_CHASE_NOW="$now" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GRAPHQL_RESPONSE="$case_dir/response.json" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CHASE" --validated "$case_dir/state" task-a github "$URL" github.com acme/widgets 42
}

request_count() {
  local method=$1 log=$2
  grep -c "^api $method repos/acme/widgets/pulls/42/requested_reviewers --field reviewers\[\]=aos-tester1$" "$log" 2>/dev/null || true
}

test_one_request_per_interval() {
  local case_dir out
  case_dir=$(make_case one-per-interval)
  write_response "$case_dir/response.json" "$HEAD_A" 25200 SUCCESS 0 aos-tester1 "$OLD_HEAD"
  out=$(run_chase "$case_dir" "$NOW") || fail "eligible chase failed"
  [ -z "$out" ] || fail "a successful chase woke firstmate: $out"
  [ "$(request_count DELETE "$case_dir/gh.log")" -eq 1 ] || fail "eligible reviewer was not deleted exactly once"
  [ "$(request_count POST "$case_dir/gh.log")" -eq 1 ] || fail "eligible reviewer was not posted exactly once"

  run_chase "$case_dir" "$((NOW + 300))" >/dev/null || fail "same-interval repeat failed"
  [ "$(request_count DELETE "$case_dir/gh.log")" -eq 1 ] || fail "watcher poll repeated the request inside six hours"

  run_chase "$case_dir" "$((NOW + 21601))" >/dev/null || fail "next-interval chase failed"
  [ "$(request_count DELETE "$case_dir/gh.log")" -eq 2 ] || fail "next six-hour interval did not allow one request"
  [ "$(request_count POST "$case_dir/gh.log")" -eq 2 ] || fail "next six-hour interval did not complete its request pair"
  pass "an eligible reviewer is re-requested once per six-hour interval"
}

test_new_head_resets_count() {
  local case_dir
  case_dir=$(make_case head-reset)
  write_response "$case_dir/response.json" "$HEAD_A" 25200 SUCCESS 0 aos-tester1 "$OLD_HEAD"
  run_chase "$case_dir" "$NOW" >/dev/null || fail "first-head chase failed"

  write_response "$case_dir/response.json" "$HEAD_B" 25200 SUCCESS 0 aos-tester1 "$HEAD_A"
  run_chase "$case_dir" "$NOW" >/dev/null || fail "new-head chase failed"
  [ "$(request_count DELETE "$case_dir/gh.log")" -eq 2 ] || fail "new head inherited the old head's request interval"
  awk -F '\t' -v head="$HEAD_B" 'NR == 2 && $0 == head {ok=1} END {exit !ok}' \
    "$case_dir/state/task-a.pr-review-chase" || fail "new head did not replace the chase record"
  awk -F '\t' '$1 == "aos-tester1" && $2 == 1 {ok=1} END {exit !ok}' \
    "$case_dir/state/task-a.pr-review-chase" || fail "new head did not reset the request count"
  pass "a new head starts a fresh bounded chase"
}

test_escalates_once_at_twenty_four_hours() {
  local case_dir out
  case_dir=$(make_case escalation)
  write_response "$case_dir/response.json" "$HEAD_A" 86400 SUCCESS 0 aos-tester1 "$OLD_HEAD"
  out=$(run_chase "$case_dir" "$NOW") || fail "24-hour escalation failed"
  case "$out" in
    *"$URL"*"24.0 hours"*) ;;
    *) fail "24-hour escalation omitted the PR URL or wait: $out" ;;
  esac
  [ "$(request_count DELETE "$case_dir/gh.log")" -eq 0 ] || fail "24-hour escalation re-fired the reviewer"

  out=$(run_chase "$case_dir" "$((NOW + 300))") || fail "repeat escalation check failed"
  [ -z "$out" ] || fail "24-hour blocker escalated more than once: $out"
  pass "a 24-hour reviewer wait escalates once and stops chasing"
}

test_chase_is_bounded_before_escalation() {
  local case_dir offset
  case_dir=$(make_case bounded)
  write_response "$case_dir/response.json" "$HEAD_A" 25200 SUCCESS 0 aos-tester1 "$OLD_HEAD"
  for offset in 0 21601 43202 64803; do
    run_chase "$case_dir" "$((NOW + offset))" >/dev/null || fail "bounded chase failed at offset $offset"
  done
  [ "$(request_count DELETE "$case_dir/gh.log")" -eq 3 ] || fail "reviewer chase exceeded its three-request cap"
  [ "$(request_count POST "$case_dir/gh.log")" -eq 3 ] || fail "bounded request pairs were incomplete"
  pass "one PR head can trigger at most three reviewer requests"
}

test_ineligible_prs_are_never_touched() {
  local case_dir kind
  for kind in red unresolved no-request current-review; do
    case_dir=$(make_case "$kind")
    case "$kind" in
      red) write_response "$case_dir/response.json" "$HEAD_A" 25200 FAILURE 0 aos-tester1 "$OLD_HEAD" ;;
      unresolved) write_response "$case_dir/response.json" "$HEAD_A" 25200 SUCCESS 1 aos-tester1 "$OLD_HEAD" ;;
      no-request) write_response "$case_dir/response.json" "$HEAD_A" 25200 SUCCESS 0 '' "$OLD_HEAD" ;;
      current-review) write_response "$case_dir/response.json" "$HEAD_A" 25200 SUCCESS 0 aos-tester1 "$HEAD_A" ;;
    esac
    run_chase "$case_dir" "$NOW" >/dev/null || fail "$kind check failed"
    [ "$(request_count DELETE "$case_dir/gh.log")" -eq 0 ] || fail "$kind PR deleted a reviewer request"
    [ "$(request_count POST "$case_dir/gh.log")" -eq 0 ] || fail "$kind PR posted a reviewer request"
  done
  pass "red, unresolved, unrequested, and current-review PRs are untouched"
}

test_one_request_per_interval
test_new_head_resets_count
test_escalates_once_at_twenty_four_hours
test_chase_is_bounded_before_escalation
test_ineligible_prs_are_never_touched
