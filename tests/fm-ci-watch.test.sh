#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-watch.sh: arming a GraphQL CI watch, running it
# the way the watcher does (a hash-validated private snapshot), and its
# one-shot result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

WATCH="$ROOT/bin/fm-ci-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-watch-tests)
REPO=acme/widgets
SHA=0123456789abcdef0123456789abcdef01234567
RUN=4242

# The fake gh answers `api graphql` by applying the caller's --jq program to
# $FM_TEST_RESPONSE with the real jq, but only when owner, name, and sha arrive
# as the expected GraphQL variables; any other query sees a null repository.
make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  fm_fakebin "$dir" >/dev/null
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-} ${2:-}" = "workflow run" ]; then
  printf '%s\n' "${FM_TEST_DISPATCH_OUT:-}"
  exit "${FM_TEST_DISPATCH_RC:-0}"
fi
[ "${1:-} ${2:-}" = "api graphql" ] || exit 1
[ "${FM_TEST_GH_RC:-0}" = 0 ] || exit "$FM_TEST_GH_RC"
shift 2
owner= name= sha= program=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|-F)
      case "$2" in
        owner=*) owner=${2#owner=} ;;
        name=*) name=${2#name=} ;;
        sha=*) sha=${2#sha=} ;;
      esac
      shift 2
      ;;
    --jq) program=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$owner/$name@$sha" = "$FM_TEST_EXPECT" ]; then
  jq -r "$program" "$FM_TEST_RESPONSE"
else
  printf '%s\n' '{"data":{"repository":null}}' | jq -r "$program"
fi
SH
  chmod +x "$dir/fakebin/gh"
  printf '%s\n' "$dir"
}

# respond <case-dir> <suite-json>...: the commit's Actions check suites.
respond() {
  local dir=$1
  shift
  printf '{"data":{"repository":{"object":{"checkSuites":{"nodes":[%s]}}}}}\n' \
    "$(IFS=,; printf '%s' "$*")" > "$dir/response.json"
}

suite() {  # <run-id> <status> <conclusion|null> [<check-runs-json>]
  local conclusion=$3
  [ "$conclusion" = null ] || conclusion="\"$conclusion\""
  printf '{"status":"%s","conclusion":%s,"workflowRun":{"databaseId":%s},"checkRuns":{"nodes":[%s]}}' \
    "$2" "$conclusion" "$1" "${4:-}"
}

in_case() {  # <case-dir> <command> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_RESPONSE="$dir/response.json" FM_TEST_EXPECT="${FM_TEST_EXPECT:-$REPO@$SHA}" "$@"
}

# Run the registered check exactly as bin/fm-watch.sh does: through a private
# snapshot validated against the trust record.
watcher_run() {  # <case-dir> <task-id>
  local dir=$1 id=$2 out
  fm_custom_check_snapshot_prepare "$dir/home/state" "$id" \
    || fail "watcher would reject the registered check for $id"
  out=$(in_case "$dir" bash "$FM_CUSTOM_CHECK_SNAPSHOT")
  fm_custom_check_snapshot_cleanup
  printf '%s' "$out"
}

test_invalid_arguments_arm_nothing() {
  local dir rc args
  dir=$(make_case invalid)
  for args in "t1 acme/widgets;id $SHA $RUN" "t1 $REPO 0123abc $RUN" "t1 $REPO $SHA 0" \
    "../t1 $REPO $SHA $RUN" "t1 $REPO $SHA"; do
    # shellcheck disable=SC2086 # Word splitting builds each argument list.
    in_case "$dir" "$WATCH" $args >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "invalid arguments '$args'"
  done
  in_case "$dir" "$WATCH" --dispatch -x t1 "$REPO" "$SHA" >/dev/null 2>&1
  expect_code 2 $? "a branch that reads as a flag"
  [ -z "$(ls -A "$dir/home/state")" ] || fail "an invalid request wrote state"
  pass "invalid task, repo, sha, run, and branch arguments are refused before anything is written"
}

test_pending_run_stays_silent_and_armed() {
  local dir out err
  dir=$(make_case pending)
  respond "$dir" "$(suite 99 COMPLETED FAILURE)" "$(suite "$RUN" IN_PROGRESS null)"
  out=$(in_case "$dir" "$WATCH" t1 "$REPO" "$SHA" "$RUN" 2> "$dir/err") || fail "arming failed"
  err=$(cat "$dir/err")
  assert_contains "$out" "armed: state/t1.check.sh watching https://github.com/$REPO/actions/runs/$RUN" "arm line"
  [ -z "$err" ] || fail "a visible run produced a warning: $err"
  [ "$(fm_pr_file_mode "$dir/home/state/t1.check.sh")" = 700 ] || fail "check is not mode 0700"
  fm_custom_check_registered "$dir/home/state" t1 || fail "check is not registered"
  out=$(watcher_run "$dir" t1)
  [ -z "$out" ] || fail "an in-progress run woke firstmate: $out"
  assert_present "$dir/home/state/t1.check.sh" "a pending watch retired itself"
  pass "an in-progress run stays silent and armed while another run on the commit has finished"
}

test_green_run_wakes_once_and_retires() {
  local dir out
  dir=$(make_case green)
  respond "$dir" "$(suite "$RUN" QUEUED null)"
  in_case "$dir" "$WATCH" t1 "$REPO" "$SHA" "$RUN" >/dev/null 2>&1 || fail "arming failed"
  respond "$dir" "$(suite "$RUN" COMPLETED SUCCESS '{"name":"Lint","status":"COMPLETED","conclusion":"SUCCESS"}')"
  out=$(watcher_run "$dir" t1)
  [ "$out" = "CI green - https://github.com/$REPO/actions/runs/$RUN" ] || fail "green line: $out"
  assert_absent "$dir/home/state/t1.check.sh" "a finished watch kept its check"
  assert_absent "$dir/home/state/t1.check-trust" "a finished watch kept its trust record"
  pass "a green run prints one line with its URL and retires its own check"
}

test_red_run_names_only_failing_jobs() {
  local dir out
  dir=$(make_case red)
  respond "$dir" "$(suite "$RUN" COMPLETED FAILURE \
    '{"name":"Lint","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"Tests 1","status":"COMPLETED","conclusion":"FAILURE"},{"name":"Docs","status":"COMPLETED","conclusion":"SKIPPED"},{"name":"Tests 2","status":"COMPLETED","conclusion":"CANCELLED"}')"
  in_case "$dir" "$WATCH" t1 "$REPO" "$SHA" "$RUN" >/dev/null 2>&1 || fail "arming failed"
  out=$(watcher_run "$dir" t1)
  [ "$out" = "CI red failure: Tests 1 failure, Tests 2 cancelled - https://github.com/$REPO/actions/runs/$RUN" ] \
    || fail "red line: $out"
  assert_absent "$dir/home/state/t1.check.sh" "a finished red watch kept its check"
  pass "a red run names its conclusion and only the jobs that did not pass"
}

test_read_errors_and_unseen_runs_stay_silent() {
  local dir out err
  dir=$(make_case unseen)
  respond "$dir" "$(suite 99 COMPLETED SUCCESS)"
  out=$(in_case "$dir" "$WATCH" t1 "$REPO" "$SHA" "$RUN" 2> "$dir/err") || fail "arming an unseen run failed"
  err=$(cat "$dir/err")
  assert_contains "$err" "warning: run $RUN is not visible" "unseen-run warning"
  assert_contains "$out" "armed: state/t1.check.sh" "an unseen run was not armed"
  out=$(watcher_run "$dir" t1)
  [ -z "$out" ] || fail "an unseen run woke firstmate: $out"
  respond "$dir" "$(suite "$RUN" COMPLETED SUCCESS)"
  out=$(FM_TEST_GH_RC=1 watcher_run "$dir" t1)
  [ -z "$out" ] || fail "a failed read woke firstmate: $out"
  assert_present "$dir/home/state/t1.check.sh" "a failed read retired the watch"
  out=$(FM_TEST_EXPECT="other/repo@$SHA" watcher_run "$dir" t1)
  [ -z "$out" ] || fail "the query ignored the watched repository: $out"
  assert_present "$dir/home/state/t1.check.sh" "a null repository retired the watch"
  out=$(watcher_run "$dir" t1)
  assert_contains "$out" "CI green" "the same watch did not report once reads succeed"
  pass "a run not yet on the commit warns at arm time, and read errors never wake or retire"
}

test_rearm_rules_protect_other_checks() {
  local dir out rc before
  dir=$(make_case rearm)
  respond "$dir" "$(suite 1 IN_PROGRESS null)" "$(suite 2 IN_PROGRESS null)"
  printf '#!/usr/bin/env bash\necho merged\n' > "$dir/home/state/t2.check.sh"
  chmod 0700 "$dir/home/state/t2.check.sh"
  before=$(cat "$dir/home/state/t2.check.sh")
  in_case "$dir" "$WATCH" t2 "$REPO" "$SHA" 1 >/dev/null 2> "$dir/err"
  rc=$?
  expect_code 1 "$rc" "arming over another check"
  [ "$(cat "$dir/home/state/t2.check.sh")" = "$before" ] || fail "another check was replaced"

  in_case "$dir" "$WATCH" t1 "$REPO" "$SHA" 1 >/dev/null 2>&1 || fail "first arm failed"
  fm_custom_check_snapshot_prepare "$dir/home/state" t1 || fail "first watch is not runnable"
  in_case "$dir" "$WATCH" t1 "$REPO" "$SHA" 2 >/dev/null 2>&1 || fail "re-arm over a CI watch failed"
  respond "$dir" "$(suite 1 COMPLETED SUCCESS)" "$(suite 2 IN_PROGRESS null)"
  out=$(in_case "$dir" bash "$FM_CUSTOM_CHECK_SNAPSHOT")
  fm_custom_check_snapshot_cleanup
  assert_contains "$out" "CI green - https://github.com/$REPO/actions/runs/1" "stale snapshot result"
  fm_custom_check_registered "$dir/home/state" t1 || fail "a stale snapshot retired the re-armed watch"
  out=$(watcher_run "$dir" t1)
  [ -z "$out" ] || fail "the re-armed watch reported early: $out"
  pass "arming refuses another check, re-arms a CI watch, and a stale run never retires the new one"
}

test_dispatch_arms_the_created_run() {
  local dir out rc
  dir=$(make_case dispatch)
  respond "$dir" "$(suite 777 QUEUED null)"
  out=$(FM_TEST_DISPATCH_OUT="Created workflow_dispatch event for ci.yml at fm/x
https://github.com/$REPO/actions/runs/777" in_case "$dir" "$WATCH" --dispatch fm/x t1 "$REPO" "$SHA" 2>&1) \
    || fail "dispatch arm failed: $out"
  assert_contains "$out" "watching https://github.com/$REPO/actions/runs/777" "dispatched run id"
  assert_grep "workflow run ci.yml --ref fm/x -R $REPO" "$dir/gh.log" "dispatch command"
  respond "$dir" "$(suite 777 COMPLETED SUCCESS)"
  out=$(watcher_run "$dir" t1)
  [ "$out" = "CI green - https://github.com/$REPO/actions/runs/777" ] || fail "dispatched run result: $out"

  dir=$(make_case dispatch-no-url)
  out=$(FM_TEST_DISPATCH_OUT="Created workflow_dispatch event" in_case "$dir" "$WATCH" --dispatch fm/x t1 "$REPO" "$SHA" 2>&1)
  rc=$?
  expect_code 1 "$rc" "dispatch without a run URL"
  assert_contains "$out" "no run URL" "missing-URL error"
  assert_absent "$dir/home/state/t1.check.sh" "a dispatch without a run URL armed a watch"

  dir=$(make_case dispatch-fail)
  out=$(FM_TEST_DISPATCH_RC=1 FM_TEST_DISPATCH_OUT="HTTP 403" in_case "$dir" "$WATCH" --dispatch fm/x t1 "$REPO" "$SHA" 2>&1)
  rc=$?
  expect_code 1 "$rc" "failed dispatch"
  assert_contains "$out" "dispatch failed: HTTP 403" "dispatch error"
  assert_absent "$dir/home/state/t1.check.sh" "a failed dispatch armed a watch"
  pass "dispatch arms the run gh reports and arms nothing when it cannot name one"
}

test_invalid_arguments_arm_nothing
test_pending_run_stays_silent_and_armed
test_green_run_wakes_once_and_retires
test_red_run_names_only_failing_jobs
test_read_errors_and_unseen_runs_stay_silent
test_rearm_rules_protect_other_checks
test_dispatch_arms_the_created_run
