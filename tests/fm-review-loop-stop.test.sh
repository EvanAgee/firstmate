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

record_raw() { # <home> <task-id> <run-id> <head> <changed> [args...]
  local home=$1 task=$2 run=$3 head=$4 changed=$5
  shift 5
  FM_HOME="$home" "$STOP" record "$task" --run "$run" --head "$head" \
    --changed "$changed" "$@"
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

test_identical_same_head_retry_is_a_no_op() {
  local task=same-head-noop run=run-same-head-noop home out before after
  home=$(make_home same-head-noop "$task")
  record "$home" "$task" "$run" head-a "Round one." "defect:m" \
    --cluster "defect:n" --targeted "defect:m" --threshold 2 >/dev/null \
    || fail "first round should continue"
  before=$(cat "$home/state/review-loops/$task.json")

  # A replay of the same head with the same payload must change nothing.
  out=$(record "$home" "$task" "$run" head-a "Round one." "defect:m" \
    --cluster "defect:n" --targeted "defect:m" 2>&1) \
    || fail "an identical same-head retry should exit zero"
  assert_contains "$out" "already recorded" "the no-op did not report the replay"
  after=$(cat "$home/state/review-loops/$task.json")
  [ "$before" = "$after" ] || fail "an identical same-head retry changed the state"
  pass "review-loop stop: an identical same-head retry is a no-op"
}

test_expanded_same_head_retry_is_rejected() {
  local task=same-head-reject run=run-same-head-reject home out rc before after
  home=$(make_home same-head-reject "$task")
  record "$home" "$task" "$run" head-a "Round one." "defect:m" --threshold 2 >/dev/null \
    || fail "first round should continue"
  before=$(cat "$home/state/review-loops/$task.json")

  # A retry that adds a cluster must be refused, not absorbed and not dropped.
  set +e
  out=$(record "$home" "$task" "$run" head-a "Round one, plus another defect." \
    "defect:m" --cluster "defect:o" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an expanded same-head retry must be rejected"
  assert_contains "$out" "cluster defect:o" \
    "the rejection did not name the cluster that was new"
  assert_contains "$out" "against the current head" \
    "the rejection did not tell the caller what to do"
  after=$(cat "$home/state/review-loops/$task.json")
  [ "$before" = "$after" ] || fail "a rejected retry still mutated the round"

  # Targeting the round already carries stays idempotent.
  set +e
  record "$home" "$task" "$run" head-a "Round one." "defect:m" \
    --targeted "defect:m" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "targeting already recorded must stay idempotent"
  pass "review-loop stop: an expanded same-head retry is rejected"
}

test_targeting_only_same_head_expansion_is_rejected() {
  local task=targeting-reject run=run-targeting-reject home out rc before after
  home=$(make_home targeting-reject "$task")
  record "$home" "$task" "$run" head-a "Round one, aimed at x." "defect:x" \
    --cluster "defect:y" --targeted "defect:x" --threshold 3 >/dev/null \
    || fail "first round should continue"
  before=$(cat "$home/state/review-loops/$task.json")

  # The cluster set is unchanged and only the targeting grows, so the error must
  # name the targeting rather than claim the clusters differ.
  set +e
  out=$(record "$home" "$task" "$run" head-a "Round one, aimed at x." "defect:x" \
    --cluster "defect:y" --targeted "defect:x" --targeted "defect:y" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a targeting-only same-head expansion must be rejected"
  assert_contains "$out" "record targeting for defect:y against" \
    "the rejection did not name the targeting that was new"
  after=$(cat "$home/state/review-loops/$task.json")
  [ "$before" = "$after" ] || fail "a rejected retry still mutated the round"
  pass "review-loop stop: a targeting-only same-head expansion is rejected"
}

test_untargeted_same_head_widening_is_rejected_too() {
  local task=untargeted-widen run=run-untargeted-widen home out rc before after
  home=$(make_home untargeted-widen "$task")
  record "$home" "$task" "$run" head-a "Round one, aimed at a." "defect:a" \
    --cluster "defect:b" --targeted "defect:a" --threshold 3 >/dev/null \
    || fail "first round should continue"
  before=$(cat "$home/state/review-loops/$task.json")

  # Omitting --targeted asks to target every cluster this call names, so this is
  # the same request as naming defect:b explicitly and must get the same answer.
  set +e
  out=$(record "$home" "$task" "$run" head-a "Round one." "defect:a" \
    --cluster "defect:b" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an untargeted same-head widening must reject like the explicit one"
  assert_contains "$out" "record targeting for defect:b against" \
    "the rejection did not name the targeting the untargeted call implied"
  after=$(cat "$home/state/review-loops/$task.json")
  [ "$before" = "$after" ] || fail "a rejected retry still mutated the round"
  pass "review-loop stop: an untargeted same-head widening is rejected too"
}

test_retry_after_a_decision_cannot_re_surface_it() {
  local task=post-resolve run=run-post-resolve home rc
  home=$(make_home post-resolve "$task")
  record "$home" "$task" "$run" head-a "Round one." "defect:x" --threshold 2 >/dev/null \
    || fail "first round should continue"
  set +e
  record "$home" "$task" "$run" head-b "Round two." "defect:x" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "two targeted rounds must stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root resolution should succeed"

  # Replaying both decided heads must not revive the cluster or re-surface it.
  record "$home" "$task" "$run" head-a "Round one." "defect:x" >/dev/null \
    || fail "a replay of a decided head should be a no-op"
  set +e
  record "$home" "$task" "$run" head-b "Round two." "defect:x" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "replaying decided rounds must not re-surface the stop"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "a replay after a decision appended a duplicate needs-decision event"
  pass "review-loop stop: replaying decided heads cannot re-surface a stop"
}

test_resolving_one_cluster_keeps_a_legacy_rounds_other_streak() {
  local task=legacy-round run=run-legacy home rc out report state
  home=$(make_home legacy-round "$task")
  mkdir -p "$home/state/review-loops"
  state="$home/state/review-loops/$task.json"
  # Rounds recorded before the targeted field existed carry only clusters. Their
  # implicit meaning is that every returned cluster was targeted, which the
  # trailing count honors through the `.targeted // .clusters` fallback. Two such
  # legacy rounds each returned x and y, so both clusters carry a streak of two
  # under a threshold of three.
  cat > "$state" <<JSON
{"version":1,"task":"$task","run":"$run","threshold":3,"generation":1,
 "rounds":[
   {"round":1,"head":"legacy-a","changed":"Legacy round one.","clusters":["defect:x","defect:y"]},
   {"round":2,"head":"legacy-b","changed":"Legacy round two.","clusters":["defect:x","defect:y"]}
 ],
 "surfaced":{"clusters":["defect:x"],"report":"$home/state/review-loops/legacy.md"}}
JSON

  # Resolve only x. The bug: resolve turned the missing targeted field into an
  # empty set, wiping y's implicit targeting in both legacy rounds so y's streak
  # restarted from zero. y must instead keep its streak of two.
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "resolving x should succeed"

  # One more targeted y round is y's third, so it must trip. If the legacy
  # targeting had been wiped this would only be y's first and would continue.
  set +e
  out=$(record "$home" "$task" "$run" head-c "Aimed at y a third time." "defect:y" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "y's streak from the legacy rounds must survive resolving x"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "y's preserved streak did not write its report"
  assert_grep "defect:y" "$report" "the report omitted the cluster whose streak survived"
  pass "review-loop stop: resolving one cluster keeps a legacy round's other streak"
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

test_ambient_threshold_does_not_override_a_pinned_run() {
  local task=pinned-loop run=run-pinned home rc
  home=$(make_home pinned-threshold "$task")
  record "$home" "$task" "$run" head-a "Added the first state guard." \
    "module:src/state:settings-write" --threshold 4 >/dev/null \
    || fail "explicit threshold should initialize the run"
  FM_REVIEW_LOOP_THRESHOLD=3 record "$home" "$task" "$run" head-b \
    "Covered the second writer." "module:src/state:settings-write" >/dev/null \
    || fail "ambient threshold should not conflict with a pinned run"
  FM_REVIEW_LOOP_THRESHOLD=3 record "$home" "$task" "$run" head-c \
    "Covered the third writer." "module:src/state:settings-write" >/dev/null \
    || fail "ambient threshold should not lower the pinned threshold"

  set +e
  FM_REVIEW_LOOP_THRESHOLD=3 record "$home" "$task" "$run" head-d \
    "Covered the final writer." "module:src/state:settings-write" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the pinned fourth round must stop"
  pass "review-loop stop: ambient threshold cannot override a pinned run"
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

test_resolution_preserves_other_cluster_streaks() {
  local task=overlap-loop run=run-g home rc out report
  home=$(make_home overlapping "$task")
  record "$home" "$task" "$run" head-a "Changed alpha first." \
    "file:src/alpha.ts" >/dev/null
  record "$home" "$task" "$run" head-b "Changed alpha and beta once." \
    "file:src/alpha.ts" --cluster "file:src/beta.ts" >/dev/null

  set +e
  record "$home" "$task" "$run" head-c "Changed alpha and beta twice." \
    "file:src/alpha.ts" --cluster "file:src/beta.ts" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "alpha should stop after three rounds"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve alpha"

  set +e
  out=$(record "$home" "$task" "$run" head-d "Changed beta a third time." \
    "file:src/beta.ts" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "beta's open streak must survive alpha's resolution"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "preserved beta streak did not write its report"
  assert_grep "Changed alpha and beta once" "$report" \
    "beta report omitted its first active round"
  assert_grep "Changed alpha and beta twice" "$report" \
    "beta report omitted its second active round"
  assert_grep "Changed beta a third time" "$report" \
    "beta report omitted its tripping round"
  pass "review-loop stop: resolving one cluster preserves other active streaks"
}

test_dead_lock_owner_is_recovered() {
  local task=stale-lock-loop run=run-h home lock ready holder rc i
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

test_distinct_defects_in_one_file_do_not_trip() {
  local task=onefile-loop run=run-onefile home
  home=$(make_home distinct-defects "$task")
  # Three different defects, each fixed once, all living in the same file. The
  # file is constant; only the defect identity should decide the count.
  record "$home" "$task" "$run" head-a "Fixed root resolution." \
    "defect:root-resolution" >/dev/null \
    || fail "first distinct defect should continue"
  record "$home" "$task" "$run" head-b "Fixed cluster grouping." \
    "defect:cluster-grouping" >/dev/null \
    || fail "second distinct defect should continue"
  record "$home" "$task" "$run" head-c "Fixed lock recovery." \
    "defect:lock-recovery" >/dev/null \
    || fail "third distinct defect should continue"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "three different defects in one file tripped the rule"
  pass "review-loop stop: different defects in one file do not trip"
}

test_same_defect_across_files_trips() {
  local task=moving-loop run=run-moving home rc out report
  home=$(make_home moving-symptom "$task")
  # One defect whose symptom moves to a different file each round, each round
  # aimed at closing that same defect.
  record "$home" "$task" "$run" head-a "Fixed the model-memory leak in loader.ts." \
    "defect:model-memory-leak" --targeted "defect:model-memory-leak" >/dev/null \
    || fail "first targeted round should continue"
  record "$home" "$task" "$run" head-b "Fixed the same leak surfacing in cache.ts." \
    "defect:model-memory-leak" --targeted "defect:model-memory-leak" >/dev/null \
    || fail "second targeted round should continue"

  set +e
  out=$(record "$home" "$task" "$run" head-c "Fixed the same leak surfacing in serve.ts." \
    "defect:model-memory-leak" --targeted "defect:model-memory-leak" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the same defect surviving three targeted fixes must stop"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the moving-symptom defect did not write its report"
  assert_grep "defect:model-memory-leak" "$report" \
    "report omitted the moving-symptom defect"
  pass "review-loop stop: same defect trips even as symptoms move across files"
}

test_untargeted_recurrence_does_not_advance_count() {
  local task=untargeted-loop run=run-untargeted home rc
  home=$(make_home untargeted-recurrence "$task")
  # The defect keeps reappearing, but each round is aimed at a different one.
  # An unfixed defect that merely reappears must not advance toward a stop.
  record_raw "$home" "$task" "$run" head-a "Fixed defect alpha." \
    --cluster "defect:alpha" --cluster "defect:beta" \
    --targeted "defect:alpha" --threshold 2 >/dev/null \
    || fail "first mixed round should continue"
  record_raw "$home" "$task" "$run" head-b "Fixed defect gamma; beta still reported." \
    --cluster "defect:beta" --cluster "defect:gamma" \
    --targeted "defect:gamma" >/dev/null \
    || fail "an untargeted recurrence must not trip at threshold two"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "an untargeted recurring defect tripped the rule"

  # Now aim two consecutive rounds at beta: it must trip at threshold two.
  set +e
  record_raw "$home" "$task" "$run" head-c "Aimed at beta." \
    --cluster "defect:beta" --targeted "defect:beta" >/dev/null 2>&1
  record_raw "$home" "$task" "$run" head-d "Aimed at beta again." \
    --cluster "defect:beta" --targeted "defect:beta" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "two consecutive targeted beta rounds must stop"
  pass "review-loop stop: untargeted recurrence does not advance the count"
}

test_multiple_severities_all_recorded() {
  local task=severity-loop run=run-severity home rc out report
  home=$(make_home multi-severity "$task")
  # A gate returning findings at different severities must record every cluster,
  # not only the blocking one. Both survive two targeted rounds and both surface.
  record_raw "$home" "$task" "$run" head-a "Round one touched both defects." \
    --cluster "defect:blocking-null-deref" --cluster "defect:advisory-naming" \
    --targeted "defect:blocking-null-deref" --targeted "defect:advisory-naming" \
    --threshold 2 >/dev/null || fail "first severity round should continue"

  set +e
  out=$(record_raw "$home" "$task" "$run" head-b "Round two touched both defects." \
    --cluster "defect:blocking-null-deref" --cluster "defect:advisory-naming" \
    --targeted "defect:blocking-null-deref" --targeted "defect:advisory-naming" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "both severities repeated twice must stop"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "multi-severity round did not write its report"
  assert_grep "defect:blocking-null-deref" "$report" \
    "report omitted the blocking-severity cluster"
  assert_grep "defect:advisory-naming" "$report" \
    "report omitted the advisory-severity cluster"
  pass "review-loop stop: every returned severity is recorded"
}

test_third_round_surfaces_once
test_distinct_areas_do_not_trip
test_distinct_defects_in_one_file_do_not_trip
test_same_defect_across_files_trips
test_untargeted_recurrence_does_not_advance_count
test_multiple_severities_all_recorded
test_identical_same_head_retry_is_a_no_op
test_expanded_same_head_retry_is_rejected
test_targeting_only_same_head_expansion_is_rejected
test_untargeted_same_head_widening_is_rejected_too
test_retry_after_a_decision_cannot_re_surface_it
test_resolving_one_cluster_keeps_a_legacy_rounds_other_streak
test_threshold_is_configurable
test_ambient_threshold_does_not_override_a_pinned_run
test_root_decision_starts_a_fresh_count
test_simultaneous_clusters_share_one_report
test_bank_archives_stop_and_accepts_new_clusters
test_resolution_preserves_other_cluster_streaks
test_dead_lock_owner_is_recovered
