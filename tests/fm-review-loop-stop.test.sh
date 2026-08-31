#!/usr/bin/env bash
# Behavior tests for the repeated no-mistakes Review stop rule.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STOP="$ROOT/bin/fm-review-loop-stop.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-loop-stop)

make_home() { # <name> <task-id>
  local home="$TMP_ROOT/$1" task=$2
  mkdir -p "$home/state"
  : > "$home/state/$task.status"
  printf '%s\n' "$home"
}

record() { # <home> <task-id> <run-id> <head> <changed> <cluster> [extra args...]
  local home=$1 task=$2 run=$3 head=$4 changed=$5 cluster=$6
  shift 6
  FM_HOME="$home" "$STOP" record "$task" --run "$run" --head "$head" \
    --changed "$changed" --cluster "$cluster" "$@"
}

test_third_round_surfaces_once() {
  local task=sample-loop run=run-a home rc out report
  home=$(make_home tripping "$task")
  record "$home" "$task" "$run" head-a "Added the first approval replay fix." \
    "file:src/lib/serve/exec-bridge.ts" >/dev/null \
    || fail "first clustered round should continue"
  record "$home" "$task" "$run" head-b "Preserved replay identity across requests." \
    "file:src/lib/serve/exec-bridge.ts" >/dev/null \
    || fail "second clustered round should continue"

  set +e
  out=$(record "$home" "$task" "$run" head-c "Moved approval settlement before replay." \
    "file:src/lib/serve/exec-bridge.ts" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "third clustered round must stop"
  assert_contains "$out" "Fix at root" "surfaced output omitted the root-fix choice"
  assert_contains "$out" "Bank the remainder" "surfaced output omitted the follow-up choice"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "third clustered round did not write its report"
  assert_grep "file:src/lib/serve/exec-bridge.ts" "$report" \
    "surfaced report omitted the cluster"
  assert_grep "Added the first approval replay fix" "$report" \
    "surfaced report omitted round one"
  assert_grep "Preserved replay identity across requests" "$report" \
    "surfaced report omitted round two"
  assert_grep "Moved approval settlement before replay" "$report" \
    "surfaced report omitted round three"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "third clustered round did not append exactly one stop event"

  set +e
  record "$home" "$task" "$run" head-d "Tried another edge fix." \
    "file:src/lib/serve/exec-bridge.ts" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "a surfaced loop must stay stopped"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "a later round repeated the stop event"
  pass "review-loop stop: third clustered round surfaces exactly once"
}

test_distinct_areas_do_not_trip() {
  local task=spread-loop run=run-b home
  home=$(make_home spread "$task")
  record "$home" "$task" "$run" head-a "Changed the request parser." \
    "file:src/request.ts" >/dev/null || fail "first distinct round should continue"
  record "$home" "$task" "$run" head-b "Changed the export formatter." \
    "file:src/export.ts" >/dev/null || fail "second distinct round should continue"
  record "$home" "$task" "$run" head-c "Changed the settings writer." \
    "file:src/settings.ts" >/dev/null || fail "third distinct round should continue"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "distinct review areas triggered a stop"
  pass "review-loop stop: distinct finding areas remain independent"
}

test_threshold_is_configurable() {
  local task=sensitive-loop run=run-c home rc
  home=$(make_home threshold "$task")
  FM_REVIEW_LOOP_THRESHOLD=4 record "$home" "$task" "$run" head-a \
    "Added the initial state guard." "module:src/state:settings-write" >/dev/null \
    || fail "configured round one should continue"
  record "$home" "$task" "$run" head-b "Covered the second writer." \
    "module:src/state:settings-write" >/dev/null \
    || fail "stored threshold should apply without another override"
  record "$home" "$task" "$run" head-c "Covered the third writer." \
    "module:src/state:settings-write" >/dev/null \
    || fail "configured threshold should not trip at the default"

  set +e
  record "$home" "$task" "$run" head-d "Made settings preservation unconditional." \
    "module:src/state:settings-write" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "configured fourth round must stop"
  assert_grep "reached 4 rounds" "$home/state/$task.status" \
    "stop event omitted the configured threshold"
  pass "review-loop stop: threshold is configurable and pinned per run"
}

test_root_decision_starts_a_fresh_count() {
  local task=root-loop run=run-d home rc
  home=$(make_home root-resolution "$task")
  record "$home" "$task" "$run" head-a "First fix." "file:src/root.ts" --threshold 2 >/dev/null
  set +e
  record "$home" "$task" "$run" head-b "Second fix." "file:src/root.ts" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "second round should stop at threshold two"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the stop"
  record "$home" "$task" "$run" head-c "Applied the root fix." "file:src/root.ts" >/dev/null \
    || fail "root decision did not start a fresh count"
  pass "review-loop stop: explicit root decision resets the cluster count"
}

test_third_round_surfaces_once
test_distinct_areas_do_not_trip
test_threshold_is_configurable
test_root_decision_starts_a_fresh_count
