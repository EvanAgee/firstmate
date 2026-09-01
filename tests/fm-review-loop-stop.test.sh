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

test_resolved_round_carries_no_stale_targeting() {
  local task=resolve-residue run=run-resolve-residue home rc
  home=$(make_home resolve-residue "$task")
  record "$home" "$task" "$run" head-a "Round one." "defect:x" --threshold 2 >/dev/null \
    || fail "first round should continue"
  set +e
  record "$home" "$task" "$run" head-b "Round two." "defect:x" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "two targeted rounds must stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root resolution should succeed"

  # Both resolved heads are retried. The retries re-report the resolved cluster
  # but aim elsewhere, so the resolved rounds must contribute no targeting for it.
  record_raw "$home" "$task" "$run" head-a "Retry of head-a, aimed at z." \
    --cluster "defect:x" --cluster "defect:z" --targeted "defect:z" >/dev/null \
    || fail "a retry of the first resolved head should continue"
  set +e
  record_raw "$home" "$task" "$run" head-b "Retry of head-b, aimed at x." \
    --cluster "defect:x" --targeted "defect:x" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "a resolved cluster must get a full fresh count after root"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "a resolved round's stale targeting re-surfaced the same cluster"
  pass "review-loop stop: a resolved round carries no stale targeting"
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

test_expanded_same_head_retry_keeps_new_cluster() {
  local task=reconcile-loop run=run-reconcile home rc out report
  home=$(make_home reconcile-head "$task")
  # First record head-a with one cluster.
  record "$home" "$task" "$run" head-a "Recorded alpha only." \
    "defect:alpha" --threshold 2 >/dev/null \
    || fail "first record should continue"
  # A same-head retry that adds a cluster must not silently drop it. An
  # identical retry stays idempotent.
  record "$home" "$task" "$run" head-a "Same head, alpha again." \
    "defect:alpha" >/dev/null \
    || fail "identical same-head retry should be idempotent"
  record "$home" "$task" "$run" head-a "Same head now also carries beta." \
    "defect:alpha" --cluster "defect:beta" --targeted "defect:beta" >/dev/null \
    || fail "expanded same-head retry should be accepted"

  # beta now has one targeted round on head-a; a second targeted beta round trips.
  set +e
  out=$(record "$home" "$task" "$run" head-b "Aimed at beta again." \
    "defect:beta" --targeted "defect:beta" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the reconciled beta cluster must survive and trip"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "reconciled retry did not surface beta"
  assert_grep "defect:beta" "$report" \
    "expanded same-head retry lost the added cluster"
  pass "review-loop stop: expanded same-head retry keeps the new cluster"
}

test_untargeted_retry_keeps_stored_untargeted_cluster() {
  local task=stored-untargeted run=run-stored-untargeted home rc
  home=$(make_home stored-untargeted "$task")
  # head-a returned X and Y but only aimed at Y, so X has no targeted round yet.
  record_raw "$home" "$task" "$run" head-a "Aimed at Y." \
    --cluster "defect:X" --cluster "defect:Y" \
    --targeted "defect:Y" --threshold 2 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-b "Aimed at X." \
    --cluster "defect:X" --targeted "defect:X" >/dev/null \
    || fail "one targeted X round must not trip at threshold two"

  # An untargeted retry of head-a re-names X. head-a's stored decision that X was
  # untargeted must stand, so X still has one targeted round and cannot stop.
  set +e
  record_raw "$home" "$task" "$run" head-a "Retry: the gate also returned Z." \
    --cluster "defect:X" --cluster "defect:Y" --cluster "defect:Z" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "a retry must not retroactively target a stored cluster"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "an untargeted retry retroactively targeted a stored cluster"
  pass "review-loop stop: a retry keeps a stored cluster untargeted"
}

test_same_head_retry_updates_the_changed_summary() {
  local task=changed-retry run=run-changed-retry home rc out report
  home=$(make_home changed-retry "$task")
  record "$home" "$task" "$run" head-a "Stale summary." "defect:q" --threshold 2 >/dev/null \
    || fail "first round should continue"
  record "$home" "$task" "$run" head-a "Corrected summary: rewrote the parser." \
    "defect:q" --cluster "defect:r" >/dev/null \
    || fail "expanded same-head retry should be accepted"

  # The report prints each round's summary, so the corrected one must win.
  set +e
  out=$(record "$home" "$task" "$run" head-b "Round two." "defect:q" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "two targeted rounds must stop"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the tripping round did not write a report"
  assert_grep "Corrected summary" "$report" \
    "a same-head retry dropped its corrected --changed summary"
  grep -Fq "Stale summary." "$report" \
    && fail "the report still prints the superseded summary"
  pass "review-loop stop: a same-head retry updates the changed summary"
}

test_untargeted_reconcile_does_not_retroactively_target() {
  local task=untargeted-reconcile run=run-untargeted-reconcile home rc
  home=$(make_home untargeted-reconcile "$task")
  # head-a returned epsilon and zeta but only aimed at zeta.
  record_raw "$home" "$task" "$run" head-a "Aimed at zeta only." \
    --cluster "defect:epsilon" --cluster "defect:zeta" \
    --targeted "defect:zeta" --threshold 2 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-b "Aimed at epsilon." \
    --cluster "defect:epsilon" --targeted "defect:epsilon" >/dev/null \
    || fail "one targeted epsilon round must not trip at threshold two"

  # A same-head retry targets only the clusters it names. It must not reach back
  # and target epsilon, which head-a deliberately left untargeted.
  set +e
  record_raw "$home" "$task" "$run" head-a "Same head now also carries eta." \
    --cluster "defect:zeta" --cluster "defect:eta" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "an untargeted reconcile must not fabricate a stop"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "a reconcile retroactively targeted a cluster it did not name"
  pass "review-loop stop: a reconcile targets only the clusters it names"
}

test_untargeted_retry_counts_like_one_combined_call() {
  local task=backcompat run=run-backcompat home_one home_split rc_one rc_split
  home_one=$(make_home backcompat-one "$task")
  home_split=$(make_home backcompat-split "$task")
  # No --targeted anywhere. A legacy caller must reach the same outcome whether
  # both clusters arrive in one call or the second arrives on a same-head retry.
  record_raw "$home_one" "$task" "$run" head-a "Round one." \
    --cluster "defect:a" --cluster "defect:b" --threshold 2 >/dev/null \
    || fail "combined first round should continue"
  set +e
  record_raw "$home_one" "$task" "$run" head-b "Round two." \
    --cluster "defect:b" >/dev/null 2>&1
  rc_one=$?
  set -e

  record_raw "$home_split" "$task" "$run" head-a "Round one." \
    --cluster "defect:a" --threshold 2 >/dev/null \
    || fail "split first round should continue"
  record_raw "$home_split" "$task" "$run" head-a "Retry: the gate also returned b." \
    --cluster "defect:a" --cluster "defect:b" >/dev/null \
    || fail "untargeted same-head retry should be accepted"
  set +e
  record_raw "$home_split" "$task" "$run" head-b "Round two." \
    --cluster "defect:b" >/dev/null 2>&1
  rc_split=$?
  set -e

  expect_code 20 "$rc_one" "the combined untargeted call must trip at threshold two"
  expect_code "$rc_one" "$rc_split" \
    "an untargeted retry must count like one combined call"
  pass "review-loop stop: an untargeted retry counts like one combined call"
}

test_same_head_retry_keeps_added_targeting() {
  local task=targeting-reconcile run=run-targeting-reconcile home rc out report
  home=$(make_home targeting-reconcile "$task")
  # head-a returned alpha and aimed at it. A retry adds beta and aims at beta.
  record_raw "$home" "$task" "$run" head-a "Aimed at alpha." \
    --cluster "defect:alpha" --targeted "defect:alpha" --threshold 2 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-a "Same head also aimed at beta." \
    --cluster "defect:alpha" --cluster "defect:beta" \
    --targeted "defect:alpha" --targeted "defect:beta" >/dev/null \
    || fail "a retry that adds a targeted cluster should be accepted"

  set +e
  out=$(record_raw "$home" "$task" "$run" head-b "Aimed at beta again." \
    --cluster "defect:beta" --targeted "defect:beta" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the added beta targeting must survive and trip"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the reconciled targeting did not surface beta"
  assert_grep "defect:beta" "$report" "same-head retry lost the added targeting"
  pass "review-loop stop: a same-head retry keeps added targeting"
}

test_third_round_surfaces_once
test_distinct_areas_do_not_trip
test_distinct_defects_in_one_file_do_not_trip
test_same_defect_across_files_trips
test_untargeted_recurrence_does_not_advance_count
test_multiple_severities_all_recorded
test_expanded_same_head_retry_keeps_new_cluster
test_untargeted_reconcile_does_not_retroactively_target
test_untargeted_retry_keeps_stored_untargeted_cluster
test_same_head_retry_updates_the_changed_summary
test_untargeted_retry_counts_like_one_combined_call
test_same_head_retry_keeps_added_targeting
test_resolved_round_carries_no_stale_targeting
test_threshold_is_configurable
test_ambient_threshold_does_not_override_a_pinned_run
test_root_decision_starts_a_fresh_count
test_simultaneous_clusters_share_one_report
test_bank_archives_stop_and_accepts_new_clusters
test_resolution_preserves_other_cluster_streaks
test_dead_lock_owner_is_recovered
