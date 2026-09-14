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

test_resolved_untargeted_cluster_cannot_add_targeting_on_retry() {
  local task=resolved-targeting run=run-resolved-targeting home head rc out before after
  home=$(make_home resolved-targeting "$task")
  record_raw "$home" "$task" "$run" head-a "Aimed only at m." \
    --cluster "defect:m" --cluster "defect:n" --targeted "defect:m" >/dev/null \
    || fail "first round should continue"
  for head in head-b head-c; do
    record "$home" "$task" "$run" "$head" "Aimed at n." "defect:n" >/dev/null \
      || fail "n should continue before its third targeted round"
  done
  set +e
  record "$home" "$task" "$run" head-d "Aimed at n again." "defect:n" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "three targeted n rounds must stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root resolution should succeed"

  record_raw "$home" "$task" "$run" head-a "Aimed only at m." \
    --cluster "defect:m" --cluster "defect:n" --targeted "defect:m" >/dev/null \
    || fail "an identical retry after resolution should remain a no-op"
  before=$(cat "$home/state/review-loops/$task.json")
  set +e
  out=$(record_raw "$home" "$task" "$run" head-a "Aimed at n instead." \
    --cluster "defect:m" --cluster "defect:n" --targeted "defect:n" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "resolving n must not make it targeted on an untargeted head"
  assert_contains "$out" "record targeting for defect:n against" \
    "the retry rejection omitted the newly targeted resolved cluster"
  after=$(cat "$home/state/review-loops/$task.json")
  [ "$before" = "$after" ] || fail "a rejected resolved-cluster retry changed state"
  pass "review-loop stop: a resolved untargeted cluster cannot add targeting on retry"
}

test_retry_preserves_a_legacy_resolution_without_an_aimed_subset() {
  local task=legacy-resolved-retry run=run-legacy-resolved-retry home state before after
  home=$(make_home legacy-resolved-retry "$task")
  mkdir -p "$home/state/review-loops"
  state="$home/state/review-loops/$task.json"
  cat > "$state" <<JSON
{"version":1,"task":"$task","run":"$run","threshold":3,"generation":2,
 "rounds":[{"round":1,"head":"legacy-a","changed":"Aimed at n.",
             "clusters":[],"targeted":[],"resolved":["defect:n"]}],
 "surfaced":null,"resolution":{"choice":"root"}}
JSON
  before=$(cat "$state")
  record "$home" "$task" "$run" legacy-a "Aimed at n." "defect:n" >/dev/null \
    || fail "a legacy resolved-head retry should remain a no-op"
  after=$(cat "$state")
  [ "$before" = "$after" ] || fail "a legacy resolved-head retry changed state"
  pass "review-loop stop: legacy resolution retries preserve their prior meaning"
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

test_widening_under_one_prefix_stops() {
  local task=widening-loop run=run-widening home rc out report
  home=$(make_home widening "$task")
  # The aos-3333 shape: each round closes the previous round's cluster and the
  # review returns a fresh defect under the same module. No cluster ever repeats,
  # so the per-cluster streak never advances, but the module keeps failing.
  record "$home" "$task" "$run" head-a "Renamed the transcript writer." \
    "module:src/lib/rename:progress-count" >/dev/null \
    || fail "first widening round should continue"
  record_raw "$home" "$task" "$run" head-b "Fixed the progress count." \
    --cluster "module:src/lib/rename:replay" \
    --targeted "module:src/lib/rename:replay" >/dev/null \
    || fail "second widening round should continue"
  record_raw "$home" "$task" "$run" head-c "Fixed the replay path." \
    --cluster "module:src/lib/rename:restored-transcript" \
    --targeted "module:src/lib/rename:restored-transcript" >/dev/null \
    || fail "third widening round should continue"

  set +e
  out=$(record_raw "$home" "$task" "$run" head-d "Fixed the restored transcript." \
    --cluster "module:src/lib/rename:capture-refusal" \
    --targeted "module:src/lib/rename:capture-refusal" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "three widening rounds under one prefix must stop"
  assert_contains "$out" "widening" "the stop output did not name the widening shape"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the widening stop did not write its report"
  assert_grep "shape: widening" "$report" "the report omitted the widening shape field"
  assert_grep "module:src/lib/rename" "$report" "the report omitted the shared prefix"
  assert_grep "module:src/lib/rename:replay" "$report" \
    "the report omitted the second round's new cluster"
  assert_grep "module:src/lib/rename:capture-refusal" "$report" \
    "the report omitted the tripping round's new cluster"
  # Round one had no earlier finding for a fix to close, so it is opening context
  # and must not be presented as one of the widening rounds that tripped the rule.
  assert_grep "Round 1 reviewed \`head-a\`: Renamed the transcript writer. (first findings under this prefix)" \
    "$report" "the report presented the opening round as a widening round"
  assert_no_grep "Round 4 reviewed \`head-d\`: Fixed the restored transcript. (first findings" \
    "$report" "the report mislabeled a real widening round as opening context"
  assert_contains "$out" "Fix at root" "the widening report omitted the root-fix choice"
  assert_contains "$out" "Bank the remainder" \
    "the widening report omitted the follow-up choice"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "the widening stop did not append exactly one stop event"
  pass "review-loop stop: widening under one prefix stops the run"
}

test_widening_across_prefixes_does_not_stop() {
  local task=spread-widening run=run-spread-widening home
  home=$(make_home spread-widening "$task")
  # Each round closes the last and returns something new, but the new defects sit
  # under different modules. Nothing points at one owning design, so the run
  # continues.
  record "$home" "$task" "$run" head-a "Fixed the parser." \
    "module:src/parser:trailing-comma" >/dev/null \
    || fail "first spread round should continue"
  record_raw "$home" "$task" "$run" head-b "Fixed the trailing comma." \
    --cluster "module:src/export:column-order" \
    --targeted "module:src/export:column-order" >/dev/null \
    || fail "second spread round should continue"
  record_raw "$home" "$task" "$run" head-c "Fixed the column order." \
    --cluster "module:src/settings:default-merge" \
    --targeted "module:src/settings:default-merge" >/dev/null \
    || fail "third spread round should continue"
  record_raw "$home" "$task" "$run" head-d "Fixed the default merge." \
    --cluster "module:src/report:rounding" \
    --targeted "module:src/report:rounding" >/dev/null \
    || fail "new clusters under different prefixes must not stop"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "new clusters under different prefixes tripped the widening rule"
  pass "review-loop stop: new clusters under different prefixes do not stop"
}

test_repeated_cluster_does_not_count_as_widening() {
  local task=repeat-not-widening run=run-repeat-widening home
  home=$(make_home repeat-not-widening "$task")
  # Round two returns a genuinely new cluster, so it widens once. Rounds three
  # and four return only clusters this run has already seen, so they must not
  # advance widening even though the run keeps producing findings. A widening
  # threshold of three is never reached.
  record "$home" "$task" "$run" head-a "Fixed the import guard." \
    "module:src/lib/changelog:validation-at-import" --threshold 9 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-b "Fixed the validation." \
    --cluster "module:src/lib/changelog:optional-field-guard" \
    --targeted "module:src/lib/changelog:optional-field-guard" >/dev/null \
    || fail "second round should continue"
  record_raw "$home" "$task" "$run" head-c "Fixed the optional field guard." \
    --cluster "module:src/lib/changelog:validation-at-import" \
    --targeted "module:src/lib/changelog:validation-at-import" >/dev/null \
    || fail "a re-returned cluster should continue"
  record_raw "$home" "$task" "$run" head-d "Fixed the import guard again." \
    --cluster "module:src/lib/changelog:optional-field-guard" \
    --targeted "module:src/lib/changelog:optional-field-guard" >/dev/null \
    || fail "a second re-returned cluster must not trip widening"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "rounds returning already-seen clusters tripped the widening rule"
  pass "review-loop stop: an already-seen cluster does not advance widening"
}

test_untargeted_round_does_not_advance_widening() {
  local task=untargeted-widening run=run-untargeted-widening home
  home=$(make_home untargeted-widening "$task")
  # Each round returns a brand-new cluster under one prefix, but no round closes
  # the previous round's cluster: the earlier defect keeps coming back alongside
  # the new one. Without a closure there is no evidence a fix uncovered the next
  # defect, so widening must not advance.
  record "$home" "$task" "$run" head-a "Touched the writer." \
    "module:src/lib/queue:first" --threshold 9 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-b "Touched the writer again." \
    --cluster "module:src/lib/queue:first" --cluster "module:src/lib/queue:second" \
    --targeted "module:src/lib/queue:second" >/dev/null \
    || fail "second round should continue"
  record_raw "$home" "$task" "$run" head-c "Touched the writer a third time." \
    --cluster "module:src/lib/queue:first" --cluster "module:src/lib/queue:third" \
    --targeted "module:src/lib/queue:third" >/dev/null \
    || fail "third round should continue"
  record_raw "$home" "$task" "$run" head-d "Touched the writer a fourth time." \
    --cluster "module:src/lib/queue:first" --cluster "module:src/lib/queue:fourth" \
    --targeted "module:src/lib/queue:fourth" >/dev/null \
    || fail "rounds that never close the previous clusters must not trip widening"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "rounds without a targeted closure tripped the widening rule"
  pass "review-loop stop: a round with no targeted closure does not widen"
}

test_widening_threshold_is_configurable() {
  local task=widening-threshold run=run-widening-threshold home rc out
  home=$(make_home widening-threshold "$task")
  # A widening threshold of two trips one round earlier than the default three.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=2 record "$home" "$task" "$run" head-a \
    "Fixed the first invariant." "module:src/lib/api:first" --threshold 9 >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=2 record_raw "$home" "$task" "$run" head-b \
    "Fixed the first invariant properly." \
    --cluster "module:src/lib/api:second" \
    --targeted "module:src/lib/api:second" >/dev/null \
    || fail "second round should continue at a widening threshold of two"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=2 record_raw "$home" "$task" "$run" head-c \
    "Fixed the second invariant." \
    --cluster "module:src/lib/api:third" \
    --targeted "module:src/lib/api:third" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the configured widening threshold must stop at two"
  assert_contains "$out" "widening" "the configured stop did not name the widening shape"
  assert_grep "reached 2" "$home/state/$task.status" \
    "the stop event omitted the configured widening threshold"
  pass "review-loop stop: the widening threshold is configurable"
}

test_root_decision_resets_only_that_prefix() {
  local task=widening-root run=run-widening-root home rc out report
  home=$(make_home widening-root "$task")
  # Build a widening streak of two under alpha and one under beta, then trip
  # alpha at a widening threshold of three. A root decision must clear alpha's
  # widening count while beta's partial count survives.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-a \
    "Opened both modules." "module:src/alpha:one" --threshold 9 >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Fixed alpha one." --cluster "module:src/alpha:two" \
    --targeted "module:src/alpha:two" >/dev/null || fail "second round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed alpha two; beta appeared." --cluster "module:src/alpha:three" \
    --cluster "module:src/beta:one" --targeted "module:src/alpha:three" \
    --targeted "module:src/beta:one" >/dev/null || fail "third round should continue"

  set +e
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed alpha three and beta one." --cluster "module:src/alpha:four" \
    --cluster "module:src/beta:two" --targeted "module:src/alpha:four" \
    --targeted "module:src/beta:two" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "alpha must trip its widening threshold"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the widening stop"

  # Beta first appeared in round three, so that round cannot widen it: there was
  # no earlier beta finding for the fix to close. Round four was beta's first
  # widening round, leaving it at one when the decision landed. Alpha's count was
  # reset to zero by the decision, so alpha and beta are now one round apart and
  # each further round widens both. Beta reaches three first and must trip while
  # alpha, two rounds behind, must not.
  FM_HOME="$home" FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 "$STOP" record "$task" \
    --run "$run" --head head-e --changed "Fixed alpha four and beta two." \
    --cluster "module:src/alpha:five" --cluster "module:src/beta:three" \
    --targeted "module:src/alpha:five" --targeted "module:src/beta:three" >/dev/null \
    || fail "beta's second widening round should continue"

  set +e
  out=$(FM_HOME="$home" FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 "$STOP" record "$task" \
    --run "$run" --head head-f --changed "Fixed alpha five and beta three." \
    --cluster "module:src/alpha:six" --cluster "module:src/beta:four" \
    --targeted "module:src/alpha:six" --targeted "module:src/beta:four" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "beta's widening count must survive alpha's root decision"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "beta's preserved widening count did not write a report"
  assert_grep "module:src/beta" "$report" \
    "the second stop reported a prefix other than beta"
  assert_no_grep "Prefix: \`module:src/alpha\`" "$report" \
    "alpha re-tripped despite its root decision"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 2 ] \
    || fail "beta's preserved widening count did not surface its own stop"
  pass "review-loop stop: a root decision resets only the decided prefix"
}

test_bank_archives_a_widening_stop() {
  local task=widening-bank run=run-widening-bank home rc
  home=$(make_home widening-bank "$task")
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-a \
    "Opened the module." "module:src/lib/pack:one" --threshold 9 >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Fixed one." --cluster "module:src/lib/pack:two" \
    --targeted "module:src/lib/pack:two" >/dev/null || fail "second round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed two." --cluster "module:src/lib/pack:three" \
    --targeted "module:src/lib/pack:three" >/dev/null || fail "third round should continue"

  set +e
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed three." --cluster "module:src/lib/pack:four" \
    --targeted "module:src/lib/pack:four" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the widening rounds must stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision bank >/dev/null \
    || fail "bank should archive the widening stop"

  # Banking archives the stop the same way it does for a streak: the run keeps
  # recording instead of re-surfacing the decision it already answered.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-e \
    "Fixed four." --cluster "module:src/lib/pack:five" \
    --targeted "module:src/lib/pack:five" >/dev/null \
    || fail "a banked widening stop blocked a later round"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "a banked widening stop surfaced a second decision event"
  pass "review-loop stop: bank archives a widening stop"
}

test_defect_keys_widen_under_their_shared_namespace() {
  local task=widening-defect run=run-widening-defect home rc out report
  home=$(make_home widening-defect "$task")
  # A bare defect: key has no module segment, so every defect: cluster shares the
  # one "defect" namespace. Four rounds of fresh defect keys widen it.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-a \
    "Fixed the first defect." "defect:progress-count" --threshold 9 >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Fixed the progress count." --cluster "defect:replay" \
    --targeted "defect:replay" >/dev/null || fail "second round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed the replay." --cluster "defect:restored-transcript" \
    --targeted "defect:restored-transcript" >/dev/null || fail "third round should continue"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed the restored transcript." --cluster "defect:capture-refusal" \
    --targeted "defect:capture-refusal" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "fresh defect keys must widen their shared namespace"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the defect-namespace widening did not write its report"
  assert_grep "Prefix: \`defect\`" "$report" \
    "the report did not name the shared defect namespace"
  pass "review-loop stop: bare defect keys widen under one namespace"
}

test_a_run_predating_widening_picks_up_the_rule() {
  local task=legacy-widening run=run-legacy-widening home rc out report state
  home=$(make_home legacy-widening "$task")
  mkdir -p "$home/state/review-loops"
  state="$home/state/review-loops/$task.json"
  # State written before widening detection existed has no widening_threshold and
  # no prefix floor. A run already in flight when the helper is upgraded must pick
  # the rule up from the ambient default rather than needing a schema migration.
  cat > "$state" <<JSON
{"version":1,"task":"$task","run":"$run","threshold":9,"generation":1,
 "rounds":[
   {"round":1,"head":"h1","changed":"Opened the module.","clusters":["module:src/legacy:one"],"targeted":["module:src/legacy:one"]},
   {"round":2,"head":"h2","changed":"Fixed one.","clusters":["module:src/legacy:two"],"targeted":["module:src/legacy:two"]},
   {"round":3,"head":"h3","changed":"Fixed two.","clusters":["module:src/legacy:three"],"targeted":["module:src/legacy:three"]}
 ],
 "surfaced":null,"resolution":null}
JSON

  set +e
  out=$(record_raw "$home" "$task" "$run" h4 "Fixed three." \
    --cluster "module:src/legacy:four" --targeted "module:src/legacy:four" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "a run predating widening must still trip the rule"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the upgraded run did not write its report"
  assert_grep "shape: widening" "$report" "the upgraded run did not stop on widening"
  # The report and the status event describe the same stop, so both must name the
  # threshold the detector actually used rather than the missing state field.
  assert_grep "Threshold: 3 consecutive widening review rounds" "$report" \
    "the upgraded run's report did not name the resolved widening threshold"
  assert_no_grep "Threshold: null" "$report" \
    "the upgraded run's report printed a null widening threshold"
  assert_grep "reached 3" "$home/state/$task.status" \
    "the upgraded run's stop event omitted the resolved widening threshold"
  pass "review-loop stop: a run predating widening picks up the rule"
}

test_a_report_after_a_root_decision_omits_the_decided_rounds() {
  local task=widening-report-floor run=run-widening-report-floor home rc out report
  home=$(make_home widening-report-floor "$task")
  # Trip the prefix once, answer it at root, then widen the same prefix again.
  # The second report must describe only the rounds after the decision, because
  # the earlier rounds were already answered and no longer count toward a stop.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-a \
    "Opened the module." "module:src/gamma:one" --threshold 9 >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Fixed one." --cluster "module:src/gamma:two" \
    --targeted "module:src/gamma:two" >/dev/null || fail "second round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed two." --cluster "module:src/gamma:three" \
    --targeted "module:src/gamma:three" >/dev/null || fail "third round should continue"

  set +e
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed three." --cluster "module:src/gamma:four" \
    --targeted "module:src/gamma:four" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the first widening streak must stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the first widening stop"

  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-e \
    "Fixed four." --cluster "module:src/gamma:five" \
    --targeted "module:src/gamma:five" >/dev/null || fail "fifth round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-f \
    "Fixed five." --cluster "module:src/gamma:six" \
    --targeted "module:src/gamma:six" >/dev/null || fail "sixth round should continue"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-g \
    "Fixed six." --cluster "module:src/gamma:seven" \
    --targeted "module:src/gamma:seven" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the prefix must widen again after its root decision"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the second widening stop did not write its report"
  assert_grep "module:src/gamma:seven" "$report" \
    "the second report omitted the round that tripped the rule"
  assert_no_grep "module:src/gamma:one" "$report" \
    "the second report listed a round the root decision already answered"
  assert_no_grep "module:src/gamma:four" "$report" \
    "the second report listed a round the root decision already answered"
  pass "review-loop stop: a report after a root decision omits the decided rounds"
}

test_a_resolved_cluster_is_not_a_new_widening_frontier() {
  local task=widening-resolved run=run-widening-resolved home rc out
  home=$(make_home widening-resolved "$task")
  # A streak resolution moves the decided cluster off its rounds and onto
  # .resolved. The run has still seen it, so a later round that returns only
  # that cluster is not a fresh frontier and must not advance widening.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-a \
    "Opened the module." --cluster "module:src/delta:same" \
    --cluster "module:src/delta:one" >/dev/null || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Fixed one." --cluster "module:src/delta:same" \
    --cluster "module:src/delta:two" >/dev/null || fail "second round should continue"

  set +e
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed two." --cluster "module:src/delta:same" \
    --cluster "module:src/delta:three" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the repeated cluster must trip the streak stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the streak stop"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed the shared defect at root." --cluster "module:src/delta:same" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a cluster the run already decided must not trip widening"
  assert_contains "$out" "continue" "the resolved cluster surfaced a widening stop"
  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 1 ] \
    || fail "the resolved cluster surfaced a second decision event"
  pass "review-loop stop: a resolved cluster is not a new widening frontier"
}

test_the_report_lists_only_the_credited_widening_rounds() {
  local task=widening-credited run=run-widening-credited home rc out report
  home=$(make_home widening-credited "$task")
  # Round two leaves round one's cluster open, so the detector does not credit
  # it and the streak restarts. Round two is still fresh under the prefix and
  # sits directly before the credited window, so it is the opening-context row;
  # round one is two rounds away and must not be listed.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-a \
    "Opened the module." "module:src/eps:one" --threshold 9 >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Tried to fix one." --cluster "module:src/eps:one" \
    --cluster "module:src/eps:two" --targeted "module:src/eps:one" \
    --targeted "module:src/eps:two" >/dev/null || fail "second round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed one and two." --cluster "module:src/eps:three" \
    --targeted "module:src/eps:three" >/dev/null || fail "third round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed three." --cluster "module:src/eps:four" \
    --targeted "module:src/eps:four" >/dev/null || fail "fourth round should continue"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-e \
    "Fixed four." --cluster "module:src/eps:five" \
    --targeted "module:src/eps:five" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "three credited widening rounds must stop"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the widening stop did not write its report"
  # The event names exactly the credited rounds' clusters, so the report must
  # list the same three rounds and no others.
  assert_grep "reached 3" "$home/state/$task.status" \
    "the stop event omitted the widening threshold"
  assert_grep "Round 3 reviewed" "$report" "the report omitted a credited round"
  assert_grep "Round 4 reviewed" "$report" "the report omitted a credited round"
  assert_grep "Round 5 reviewed" "$report" "the report omitted the tripping round"
  # Round 1 already returned a cluster under this prefix, so the opening row is
  # earlier context, not the prefix's first appearance, and must not claim to be.
  assert_grep "Round 2 reviewed \`head-b\`: Tried to fix one. (earlier findings under this prefix, not counted)" \
    "$report" "the report dropped the opening row adjacent to the credited streak"
  assert_no_grep "Tried to fix one. (first findings under this prefix)" "$report" \
    "the report claimed first appearance for a round the prefix already preceded"
  # Round 1 is two rounds from the credited window, so listing it would print a
  # gapped span under a header that claims every row closed the row above it.
  assert_no_grep "Round 1 reviewed" "$report" \
    "the report listed a round separated from the credited streak by a gap"
  # The adjacent opening row plus the three credited rounds, and nothing else.
  [ "$(grep -c '^- Round ' "$report")" -eq 4 ] \
    || fail "the report listed rounds the detector never credited"
  pass "review-loop stop: the report lists only the credited widening rounds"
}

test_a_streak_resolution_does_not_delay_a_widening_stop() {
  local task=widening-after-streak run=run-widening-after-streak home rc out report
  home=$(make_home widening-after-streak "$task")
  # Three rounds of one repeated cluster trip the streak stop, and the root
  # decision moves that cluster off .clusters onto .resolved. Round three still
  # returned a finding under the prefix, so round four's aimed change closes it
  # and earns widening credit. The stop must arrive on round six, not seven.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-a \
    "Opened the module." "module:src/zeta:same" >/dev/null \
    || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-b \
    "Tried the shared defect." "module:src/zeta:same" >/dev/null \
    || fail "second round should continue"

  set +e
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-c \
    "Tried the shared defect again." "module:src/zeta:same" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the repeated cluster must trip the streak stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the streak stop"

  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-d \
    "Fixed the shared defect at root." "module:src/zeta:four" >/dev/null \
    || fail "fourth round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-e \
    "Fixed four." "module:src/zeta:five" >/dev/null \
    || fail "fifth round should continue"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record "$home" "$task" "$run" head-f \
    "Fixed five." "module:src/zeta:six" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "a resolved round must not delay the widening stop by a round"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the widening stop did not write its report"
  assert_grep "shape: widening" "$report" "the stop was not the widening shape"
  # Rounds one to three already returned a finding under this prefix, so round
  # four is a credited widening round and never the prefix's first sighting.
  assert_no_grep "Round 4 reviewed .* (first findings" "$report" \
    "the report called a credited round the prefix's first sighting"
  assert_grep "Round 4 reviewed" "$report" "the report omitted the first credited round"
  assert_grep "Round 6 reviewed" "$report" "the report omitted the tripping round"
  assert_no_grep "Round 7 reviewed" "$report" "the stop arrived a round late"
  pass "review-loop stop: a streak resolution does not delay a widening stop"
}

test_the_report_never_lists_a_gapped_round_span() {
  local task=widening-gap run=run-widening-gap home rc out report
  home=$(make_home widening-gap "$task")
  # Round one returns a module cluster it never aims at, plus a defect cluster.
  # Rounds two and three aim at the module cluster and trip the streak, which a
  # root decision answers. Round four then widens the prefix on its own. The
  # report must describe that one credited round and must not reach back past
  # the two rounds in between, because the header promises an unbroken chain.
  FM_REVIEW_LOOP_THRESHOLD=2 FM_REVIEW_LOOP_WIDENING_THRESHOLD=1 \
    record_raw "$home" "$task" "$run" head-a "Opened two areas." \
    --cluster "module:src/eta:x" --cluster "defect:z" --targeted "defect:z" \
    >/dev/null || fail "first round should continue"
  FM_REVIEW_LOOP_THRESHOLD=2 FM_REVIEW_LOOP_WIDENING_THRESHOLD=1 \
    record_raw "$home" "$task" "$run" head-b "Aimed at x." \
    --cluster "module:src/eta:x" --targeted "module:src/eta:x" >/dev/null \
    || fail "second round should continue"

  set +e
  FM_REVIEW_LOOP_THRESHOLD=2 FM_REVIEW_LOOP_WIDENING_THRESHOLD=1 \
    record_raw "$home" "$task" "$run" head-c "Aimed at x again." \
    --cluster "module:src/eta:x" --targeted "module:src/eta:x" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the repeated cluster must trip the streak stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the streak stop"

  set +e
  out=$(FM_REVIEW_LOOP_THRESHOLD=2 FM_REVIEW_LOOP_WIDENING_THRESHOLD=1 \
    record_raw "$home" "$task" "$run" head-d "Fixed x at root." \
    --cluster "module:src/eta:n4" --targeted "module:src/eta:n4" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the fresh cluster must trip the widening stop"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the widening stop did not write its report"
  # The event names one cluster over one round, so the report must agree.
  assert_grep "reached 1 rounds" "$home/state/$task.status" \
    "the stop event did not name one widening round"
  assert_grep "Round 4 reviewed" "$report" "the report omitted the tripping round"
  assert_no_grep "Round 1 reviewed" "$report" \
    "the report reached back across a gap of uncredited rounds"
  [ "$(grep -c '^- Round ' "$report")" -eq 1 ] \
    || fail "the report listed more rounds than the status event named"
  pass "review-loop stop: the report never lists a gapped round span"
}

test_a_resolve_records_which_resolved_clusters_were_aimed_at() {
  local task=widening-unaimed run=run-widening-unaimed home rc state
  home=$(make_home widening-unaimed "$task")
  # A resolution strips .targeted for every cluster it decides, whether or not
  # the round ever aimed at that cluster, so aimedness cannot be recovered from
  # .resolved afterwards. Rule 4 needs it: a round with no targeted closure must
  # never advance widening. The state file therefore records the aimed subset it
  # moved, and this asserts that persisted record against rounds that differ
  # only in whether they aimed at the resolved cluster.
  FM_REVIEW_LOOP_THRESHOLD=2 record_raw "$home" "$task" "$run" head-a \
    "Opened two areas." --cluster "module:src/theta:y" --cluster "defect:pad" \
    --targeted "defect:pad" >/dev/null || fail "first round should continue"
  FM_REVIEW_LOOP_THRESHOLD=2 record_raw "$home" "$task" "$run" head-b \
    "Aimed at y." --cluster "module:src/theta:y" \
    --targeted "module:src/theta:y" >/dev/null || fail "second round should continue"

  set +e
  FM_REVIEW_LOOP_THRESHOLD=2 record_raw "$home" "$task" "$run" head-c \
    "Aimed at y again." --cluster "module:src/theta:y" \
    --targeted "module:src/theta:y" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 20 "$rc" "the repeated cluster must trip the streak stop"
  FM_HOME="$home" "$STOP" resolve "$task" --run "$run" --decision root >/dev/null \
    || fail "root decision should resolve the streak stop"

  # The state file is this helper's own persisted record, not foreign source.
  state="$home/state/review-loops/$task.json"
  [ "$(jq -c '.rounds[0].resolved' "$state")" = '["module:src/theta:y"]' ] \
    || fail "the resolution did not move the decided cluster onto round one"
  [ "$(jq -c '.rounds[0].resolved_aimed' "$state")" = '[]' ] \
    || fail "round one never aimed at the resolved cluster but was recorded as aiming"
  [ "$(jq -c '.rounds[1].resolved_aimed' "$state")" = '["module:src/theta:y"]' ] \
    || fail "round two aimed at the resolved cluster but was not recorded as aiming"
  pass "review-loop stop: a resolve records which resolved clusters were aimed at"
}

test_the_widening_threshold_flag_pins_the_run() {
  local task=widening-flag run=run-widening-flag home rc out
  home=$(make_home widening-flag "$task")
  # The flag mirrors --threshold: it sets the widening threshold for a new run,
  # it beats the environment variable when both are set, and a later record that
  # asks for a different value is refused rather than silently re-pinning.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=9 record "$home" "$task" "$run" head-a \
    "Opened the module." "module:src/iota:one" --widening-threshold 2 >/dev/null \
    || fail "first round should continue"

  # Round one is the prefix's first sighting and never counts, so two credited
  # widening rounds land on round three. At the env var's 9 nothing would stop.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=9 record_raw "$home" "$task" "$run" head-b \
    "Fixed one." --cluster "module:src/iota:two" \
    --targeted "module:src/iota:two" >/dev/null || fail "second round should continue"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=9 record_raw "$home" "$task" "$run" head-c \
    "Fixed two." --cluster "module:src/iota:three" \
    --targeted "module:src/iota:three" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "the flag must beat the env var and stop at two"
  assert_contains "$out" "widening" "the flag-configured stop did not name the shape"
  assert_grep "reached 2 rounds" "$home/state/$task.status" \
    "the stop event did not name the flag's widening threshold"

  # A later conflicting override is refused with the same shape --threshold uses.
  set +e
  out=$(record_raw "$home" "$task" "$run" head-d "Fixed three." \
    --cluster "module:src/iota:four" --targeted "module:src/iota:four" \
    --widening-threshold 5 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a conflicting widening threshold must be refused"
  assert_contains "$out" "already uses review-loop widening threshold 2" \
    "the refusal did not name the pinned widening threshold"
  pass "review-loop stop: the widening threshold flag pins the run"
}


test_the_widening_threshold_flag_pins_a_legacy_run() {
  local task=widening-legacy-pin run=run-widening-legacy-pin home rc out state
  home=$(make_home widening-legacy-pin "$task")
  mkdir -p "$home/state/review-loops"
  state="$home/state/review-loops/$task.json"
  # State written before the widening threshold field existed. The flag must pin
  # into it on the next record exactly as --threshold pins, so an in-flight run
  # cannot drift across two widening thresholds.
  cat > "$state" <<JSON
{"version":1,"task":"$task","run":"$run","threshold":9,"generation":1,
 "rounds":[
   {"round":1,"head":"h1","changed":"Opened the module.","clusters":["module:src/mu:one"],"targeted":["module:src/mu:one"]}
 ],
 "surfaced":null,"resolution":null}
JSON

  record_raw "$home" "$task" "$run" h2 "Fixed one." \
    --cluster "module:src/mu:two" --targeted "module:src/mu:two" \
    --widening-threshold 4 >/dev/null || fail "the flag should record against legacy state"
  # The state file is this helper's own persisted record.
  [ "$(jq -r '.widening_threshold' "$state")" = 4 ] \
    || fail "the flag did not pin the widening threshold onto legacy state"

  set +e
  out=$(record_raw "$home" "$task" "$run" h3 "Fixed two." \
    --cluster "module:src/mu:three" --targeted "module:src/mu:three" \
    --widening-threshold 9 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a conflicting widening threshold must be refused on legacy state"
  assert_contains "$out" "already uses review-loop widening threshold 4" \
    "the refusal did not name the pinned widening threshold"
  pass "review-loop stop: the widening threshold flag pins a legacy run"
}

test_a_legacy_run_without_the_flag_keeps_the_ambient_default() {
  local task=widening-legacy-ambient run=run-widening-legacy-ambient home rc out state
  home=$(make_home widening-legacy-ambient "$task")
  mkdir -p "$home/state/review-loops"
  state="$home/state/review-loops/$task.json"
  # No flag, so the accepted backward-compatibility rule still holds: a run
  # recorded before this change picks the threshold up from the ambient value.
  cat > "$state" <<JSON
{"version":1,"task":"$task","run":"$run","threshold":9,"generation":1,
 "rounds":[
   {"round":1,"head":"h1","changed":"Opened the module.","clusters":["module:src/nu:one"],"targeted":["module:src/nu:one"]},
   {"round":2,"head":"h2","changed":"Fixed one.","clusters":["module:src/nu:two"],"targeted":["module:src/nu:two"]}
 ],
 "surfaced":null,"resolution":null}
JSON

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=2 record_raw "$home" "$task" "$run" h3 \
    "Fixed two." --cluster "module:src/nu:three" \
    --targeted "module:src/nu:three" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "a legacy run must pick the ambient widening threshold up"
  assert_grep "reached 2 rounds" "$home/state/$task.status" \
    "the legacy run did not stop at the ambient widening threshold"
  pass "review-loop stop: a legacy run without the flag keeps the ambient default"
}

test_the_report_keeps_an_adjacent_opening_row() {
  local task=widening-adjacent run=run-widening-adjacent home rc out report
  home=$(make_home widening-adjacent "$task")
  # Round one returns a module cluster it never aims at, so it is fresh but
  # uncredited and sits two rounds before the credited window. Round two is also
  # fresh and sits directly before that window, so round two is the opening row.
  # An earlier uncredited round must never mask a genuinely adjacent one.
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-a \
    "Opened two areas." --cluster "module:src/kappa:one" --cluster "defect:z" \
    --targeted "defect:z" >/dev/null || fail "first round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-b \
    "Fixed z; one still open." --cluster "module:src/kappa:one" \
    --cluster "module:src/kappa:two" --targeted "module:src/kappa:one" \
    --targeted "module:src/kappa:two" >/dev/null || fail "second round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-c \
    "Fixed one and two." --cluster "module:src/kappa:three" \
    --targeted "module:src/kappa:three" >/dev/null || fail "third round should continue"
  FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-d \
    "Fixed three." --cluster "module:src/kappa:four" \
    --targeted "module:src/kappa:four" >/dev/null || fail "fourth round should continue"

  set +e
  out=$(FM_REVIEW_LOOP_WIDENING_THRESHOLD=3 record_raw "$home" "$task" "$run" head-e \
    "Fixed four." --cluster "module:src/kappa:five" \
    --targeted "module:src/kappa:five" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "three credited widening rounds must stop"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the widening stop did not write its report"
  # Round 1 returned module:src/kappa:one under this same prefix, so round 2 is
  # not the prefix's first appearance and the label must not say it is.
  assert_grep "Round 2 reviewed \`head-b\`: Fixed z; one still open. (earlier findings under this prefix, not counted)" \
    "$report" "the report dropped the opening row adjacent to the credited streak"
  assert_no_grep "Fixed z; one still open. (first findings under this prefix)" "$report" \
    "the report claimed first appearance for a round the prefix already preceded"
  assert_no_grep "Round 1 reviewed" "$report" \
    "the report listed a round separated from the credited streak by a gap"
  # The adjacent opening row plus the three credited rounds, and nothing else.
  [ "$(grep -c '^- Round ' "$report")" -eq 4 ] \
    || fail "the report listed rounds the detector never credited"
  pass "review-loop stop: the report keeps an adjacent opening row"
}

test_a_fresh_cluster_beside_an_older_repeat_still_widens() {
  local task=widening-mixed run=run-widening-mixed home rc out report
  home=$(make_home widening-mixed "$task")
  # Rule 1 asks for at least one never-seen cluster, and rule 4 only excludes a
  # round returning nothing but already-seen ones. So a round that answers with a
  # new cluster still widens even when it also re-returns a cluster from an
  # earlier, non-adjacent round: the frontier moved. Only the previous round's
  # clusters have to be closed.
  record "$home" "$task" "$run" head-a "Opened the module." \
    "module:src/rho:one" --widening-threshold 2 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-b "Fixed one." \
    --cluster "module:src/rho:two" --targeted "module:src/rho:two" >/dev/null \
    || fail "second round should continue"

  set +e
  out=$(record_raw "$home" "$task" "$run" head-c "Fixed two; one came back." \
    --cluster "module:src/rho:three" --cluster "module:src/rho:one" \
    --targeted "module:src/rho:three" --targeted "module:src/rho:one" 2>&1)
  rc=$?
  set -e
  expect_code 20 "$rc" "a fresh cluster beside an older repeat must still widen"
  report=$(printf '%s' "$out" | sed -n 's/^stop: report=//p')
  assert_present "$report" "the widening stop did not write its report"
  assert_grep "module:src/rho:three" "$report" \
    "the report omitted the round's new cluster"
  # Rows list new clusters only, so the re-returned one is deliberately absent.
  # The header must therefore not claim that no cluster ever repeats.
  assert_no_grep "no single cluster ever repeats" "$report" \
    "the report claimed no cluster ever repeats while this run repeated one"
  pass "review-loop stop: a fresh cluster beside an older repeat still widens"
}

test_only_old_clusters_and_unclosed_rounds_do_not_widen() {
  local task=widening-noncredit run=run-widening-noncredit home rc
  home=$(make_home widening-noncredit "$task")
  # The two shapes rule 4 excludes, at a widening threshold of two so either one
  # counting would stop the run. First a round returning only already-seen
  # clusters, then a round that leaves the previous round's cluster open.
  record "$home" "$task" "$run" head-a "Opened the module." \
    "module:src/tau:one" --widening-threshold 2 >/dev/null \
    || fail "first round should continue"
  record_raw "$home" "$task" "$run" head-b "Fixed one." \
    --cluster "module:src/tau:two" --targeted "module:src/tau:two" >/dev/null \
    || fail "second round should continue"
  record_raw "$home" "$task" "$run" head-c "Nothing new." \
    --cluster "module:src/tau:one" --targeted "module:src/tau:one" >/dev/null \
    || fail "a round returning only already-seen clusters must not widen"
  record_raw "$home" "$task" "$run" head-d "Tried three; two still open." \
    --cluster "module:src/tau:two" --cluster "module:src/tau:three" \
    --targeted "module:src/tau:two" --targeted "module:src/tau:three" >/dev/null \
    || fail "a round leaving the previous clusters open must not widen"

  [ "$(grep -c '^needs-decision ' "$home/state/$task.status")" -eq 0 ] \
    || fail "a non-widening round surfaced a widening stop"
  pass "review-loop stop: only-old and unclosed rounds do not widen"
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
test_resolved_untargeted_cluster_cannot_add_targeting_on_retry
test_retry_preserves_a_legacy_resolution_without_an_aimed_subset
test_retry_after_a_decision_cannot_re_surface_it
test_resolving_one_cluster_keeps_a_legacy_rounds_other_streak
test_threshold_is_configurable
test_ambient_threshold_does_not_override_a_pinned_run
test_root_decision_starts_a_fresh_count
test_simultaneous_clusters_share_one_report
test_bank_archives_stop_and_accepts_new_clusters
test_resolution_preserves_other_cluster_streaks
test_widening_under_one_prefix_stops
test_widening_across_prefixes_does_not_stop
test_repeated_cluster_does_not_count_as_widening
test_untargeted_round_does_not_advance_widening
test_widening_threshold_is_configurable
test_root_decision_resets_only_that_prefix
test_bank_archives_a_widening_stop
test_defect_keys_widen_under_their_shared_namespace
test_a_run_predating_widening_picks_up_the_rule
test_a_report_after_a_root_decision_omits_the_decided_rounds
test_a_resolved_cluster_is_not_a_new_widening_frontier
test_the_report_lists_only_the_credited_widening_rounds
test_a_streak_resolution_does_not_delay_a_widening_stop
test_the_report_never_lists_a_gapped_round_span
test_a_resolve_records_which_resolved_clusters_were_aimed_at
test_the_widening_threshold_flag_pins_the_run
test_the_widening_threshold_flag_pins_a_legacy_run
test_a_legacy_run_without_the_flag_keeps_the_ambient_default
test_the_report_keeps_an_adjacent_opening_row
test_a_fresh_cluster_beside_an_older_repeat_still_widens
test_only_old_clusters_and_unclosed_rounds_do_not_widen
test_dead_lock_owner_is_recovered
