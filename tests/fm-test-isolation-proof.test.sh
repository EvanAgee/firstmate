#!/usr/bin/env bash
# Behavioral tests for the isolation-proof and test-run public interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-test-isolation-proof.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$PROOF" "bin/fm-test-isolation-proof.sh is missing"
[ -x "$PROOF" ] || fail "bin/fm-test-isolation-proof.sh must be executable"

test_list_candidates_nonempty_and_stable() {
  local listed count sorted
  listed=$("$PROOF" --list)
  [ -n "$listed" ] || fail "--list printed nothing"
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 10 ] || fail "expected a bounded non-trivial candidate set, got $count"
  sorted=$(printf '%s\n' "$listed" | LC_ALL=C sort)
  [ "$listed" = "$sorted" ] || fail "--list must be sorted for a stable matrix"
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = "$count" ] \
    || fail "--list must not duplicate candidates"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) [ -f "$ROOT/$line" ] || fail "listed missing script: $line" ;;
      *) fail "non-test candidate path: $line" ;;
    esac
  done <<<"$listed"
  pass "candidate --list is non-empty, sorted, unique, and real"
}

test_candidates_exclude_serial_classes() {
  local listed
  listed=$("$PROOF" --list)
  for banned in \
    tests/fm-test-isolation-proof.test.sh \
    tests/fm-backend-tmux-smoke.test.sh \
    tests/fm-watcher-lock.test.sh \
    tests/fm-wake-queue.test.sh \
    tests/fm-backend-herdr-smoke.test.sh \
    tests/fm-afk-inject-e2e.test.sh \
    tests/fm-pi-primary-live-e2e.test.sh \
    tests/fm-pr-check-security.test.sh \
    tests/fm-backend-cmux-smoke.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$banned" \
      && fail "serial-class script must not be a parallel candidate: $banned"
  done
  pass "serial classes remain excluded from the parallel candidate set"
}

test_extra_hermetic_candidates_present() {
  local listed
  listed=$("$PROOF" --list)
  for want in \
    tests/fm-backend-herdr.test.sh \
    tests/fm-send-strict.test.sh \
    tests/fm-spawn-batch.test.sh \
    tests/fm-pr-merge.test.sh \
    tests/fm-review-diff.test.sh \
    tests/fm-x-mode.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$want" \
      || fail "extra hermetic candidate missing: $want"
  done
  pass "audited fake-backend and stub-network extras are candidates"
}

test_list_exclusions_documents_reasons() {
  local out
  out=$("$PROOF" --list-exclusions)
  [ -n "$out" ] || fail "--list-exclusions printed nothing"
  printf '%s\n' "$out" | grep -Fq 'fm-watcher-lock.test.sh' \
    || fail "exclusions must document watcher-lock serial reason"
  printf '%s\n' "$out" | grep -Fq 'fm-backend-herdr-smoke.test.sh' \
    || fail "exclusions must document real-herdr serial reason"
  pass "exclusion list documents serial reasons"
}

test_family_map_labels_this_contract() {
  local fam
  fam=$("$RUNNER" --list --family pure-contract-unit)
  printf '%s\n' "$fam" | grep -Fq 'tests/fm-test-isolation-proof.test.sh' \
    || fail "fm-test-isolation-proof.test.sh must map to pure-contract-unit"
  pass "isolation-proof contract test is family-mapped"
}

test_parallel_shards_consume_the_proven_set() {
  local proven shards
  proven=$("$PROOF" --list | LC_ALL=C sort -u)
  shards=$(
    {
      "$RUNNER" --list --lane portable-parallel-1
      "$RUNNER" --list --lane portable-parallel-2
    } | LC_ALL=C sort -u
  )
  [ "$proven" = "$shards" ] \
    || fail "portable parallel shards must equal isolation-proof --list exactly"
  pass "parallel shards consume the proven-isolated set only"
}

# A test file run directly, outside the runner, must not inherit a crewmate's
# FM_HOME or override variables, or a test that forgets to set one reads and
# writes the live home. Sourcing tests/lib.sh gives it the runner's clean slate.
test_lib_clears_ambient_home_selection() {
  local out var
  # shellcheck disable=SC2016 # the child shell expands its own variables after sourcing.
  out=$(env FM_HOME=/ambient/home FM_STATE_OVERRIDE=/ambient/state FM_DATA_OVERRIDE=/ambient/data \
    FM_ROOT_OVERRIDE=/ambient/root FM_PROJECTS_OVERRIDE=/ambient/projects \
    FM_CONFIG_OVERRIDE=/ambient/config FM_BACKEND=ambient \
    bash -c '. "$1"; for v in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND; do printf "%s=%s\n" "$v" "${!v-unset}"; done' \
    _ "$ROOT/tests/lib.sh")
  for var in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND; do
    assert_contains "$out" "$var=unset" "sourcing tests/lib.sh kept ambient $var"
  done
  pass "tests/lib.sh clears ambient home selection the same way the runner does"
}

test_list_candidates_nonempty_and_stable
test_candidates_exclude_serial_classes
test_extra_hermetic_candidates_present
test_list_exclusions_documents_reasons
test_family_map_labels_this_contract
test_parallel_shards_consume_the_proven_set
test_lib_clears_ambient_home_selection
