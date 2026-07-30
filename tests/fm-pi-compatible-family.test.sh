#!/usr/bin/env bash
# Contract tests for the explicit Pi-compatible harness family.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAMILY_LIB="$ROOT/bin/fm-pi-compatible-lib.sh"

assert_member() {
  local harness=$1
  FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$1"; fm_pi_compatible_harness_is_verified "$2"' _ "$FAMILY_LIB" "$harness" \
    || fail "expected exact Pi-compatible family member: $harness"
}

assert_not_member() {
  local harness=$1
  if FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$1"; fm_pi_compatible_harness_is_verified "$2"' _ "$FAMILY_LIB" "$harness"; then
    fail "inexact or unsupported harness was admitted to the Pi-compatible family: $harness"
  fi
}

test_explicit_exact_family_membership() {
  local harness
  assert_member pi
  assert_member omp
  for harness in '' Pi OMP pi-signed pi-preview omp-helper xomp '/usr/bin/omp'; do
    assert_not_member "$harness"
  done
  pass "Pi-compatible family membership is the exact pi/omp allowlist"
}

test_explicit_exact_family_membership
