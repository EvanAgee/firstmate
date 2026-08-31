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

hold_lock() { # <home> <lock> <ready>
  local home=$1 lock=$2 ready=$3
  local FM_HOME=$home STATE="$home/state"
  export FM_HOME STATE
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$lock" || return 1
  : > "$ready"
  while :; do sleep 1; done
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

test_simultaneous_clusters_share_one_report() {
  local task=paired-loop run=run-e home rc out report
  home=$(make_home simultaneous "$task")
  record "$home" "$task" "$run" head-a "Changed both owners once." \
    "file:src/alpha.ts" --cluster "file:src/beta.ts" --threshold 2 >/dev/null

  set +e
  out=$(record "$home" "$task" "$run" head-b "Changed both owners twice." \
    "file:src/alpha.ts" --cluster "file:src/beta.ts" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "simultaneous repeated clusters must stop together"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "simultaneous repeated clusters did not write one report"
  assert_grep "file:src/alpha.ts" "$report" "shared report omitted the first cluster"
  assert_grep "file:src/beta.ts" "$report" "shared report omitted the second cluster"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "simultaneous repeated clusters surfaced more than one decision event"
  pass "review-loop stop: simultaneous clusters surface in one report"
}

test_bank_archives_stop_and_accepts_new_clusters() {
  local task=bank-loop run=run-f home rc
  home=$(make_home bank-resolution "$task")
  record "$home" "$task" "$run" head-a "First alpha fix." \
    "file:src/alpha.ts" --threshold 2 >/dev/null
  set +e
  record "$home" "$task" "$run" head-b "Second alpha fix." \
    "file:src/alpha.ts" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "alpha should stop at threshold two"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision bank >/dev/null \
    || fail "bank decision should archive the surfaced stop"
  record "$home" "$task" "$run" head-c "First beta fix." \
    "file:src/beta.ts" >/dev/null \
    || fail "banked alpha stop blocked a new beta round"

  set +e
  record "$home" "$task" "$run" head-d "Second beta fix." \
    "file:src/beta.ts" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "beta should get its own stop after banked alpha"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 2 ] \
    || fail "banked alpha and later beta did not surface once each"
  pass "review-loop stop: bank archives the stop and starts a fresh count"
}

test_dead_lock_owner_is_recovered() {
  local task=stale-lock-loop run=run-g home lock ready holder rc i
  home=$(make_home stale-lock "$task")
  lock="$home/state/review-loops/$task.lock"
  ready="$home/lock-ready"
  mkdir -p "$(dirname "$lock")"
  hold_lock "$home" "$lock" "$ready" &
  holder=$!
  i=0
  while [ ! -f "$ready" ] && kill -0 "$holder" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || break
    sleep 0.02
  done
  [ -f "$ready" ] || { kill "$holder" 2>/dev/null || true; fail "lock holder did not start"; }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  set +e
  record "$home" "$task" "$run" head-a "Recorded after a crashed writer." \
    "file:src/recovered.ts" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "a dead lock owner must not block later review rounds"
  pass "review-loop stop: dead lock owners are recovered"
}

test_third_round_surfaces_once
test_distinct_areas_do_not_trip
test_threshold_is_configurable
test_root_decision_starts_a_fresh_count
test_simultaneous_clusters_share_one_report
test_bank_archives_stop_and_accepts_new_clusters
test_dead_lock_owner_is_recovered
