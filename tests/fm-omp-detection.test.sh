#!/usr/bin/env bash
# tests/fm-omp-detection.test.sh - detection matrix for the omp (Oh My Pi) adapter.
#
# omp sets OMPCODE=1 alongside CLAUDECODE=1 on its child/tool processes (verified
# omp 17.3.3). The detection precedence hazard is identical to cursor's: omp does
# NOT clear an inherited CLAUDECODE, so whichever marker is tested first wins.
# This suite pins the LOGIC with env markers only, NO omp binary required, so CI
# enforces it everywhere.
#
# The load-bearing contracts:
#   1. OMPCODE=1 outranks CLAUDECODE=1 (omp is Pi-family, not Claude).
#   2. OMPCODE=1 outranks PI_CODING_AGENT=true (omp is a distinct fork).
#   3. CLAUDECODE=1 alone (no OMPCODE) is still claude.
#   4. PI_CODING_AGENT=true alone (no OMPCODE) is still pi.
#   5. Cursor markers still win over everything (unchanged precedence).
#   6. Grok marker still detected (unchanged precedence).
#   7. No markers: unknown (ancestry walk, no omp process to match). This one
#      reads the live parent-process chain, so it only holds when no harness
#      launched the run. Under an ambient harness (a developer running the suite
#      from inside claude/pi) the test skips loudly instead - but only on
#      independent evidence: the detector ran cleanly AND a separate ancestry walk
#      confirms a harness process is present, so a genuine detector regression on
#      clean CI still fails rather than passing as a skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"

# An empty config dir so crew resolution reads no crew-harness file regardless of
# the ambient FM_HOME this suite happens to run under (a developer's real home
# carries a config/crew-harness; CI's does not). FM_CONFIG_OVERRIDE points
# fm-harness.sh's config lookup here, making "no crew config" a fact of the test
# rather than a fact of the machine.
EMPTY_CONFIG_ROOT=$(fm_test_tmproot fm-omp-detection) ||
  fail "could not create a temp root for the empty config dir"
EMPTY_CONFIG="$EMPTY_CONFIG_ROOT/config"
mkdir -p "$EMPTY_CONFIG" || fail "could not create the empty config dir at $EMPTY_CONFIG"

# Run fm-harness.sh with a clean slate plus the given env markers.
detect_with() {
  env -u CLAUDECODE -u OMPCODE -u PI_CODING_AGENT -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_PI_HARNESS \
      "$@" "$HARNESS"
}

# Independent evidence for the no-marker skip below: walk THIS test's own parent
# process chain and report the first harness process found, or nothing. This
# reads the live ancestry directly (ps + ppid) rather than asking the detector
# under test, so it is not fooled by a detector regression: it is a separate
# witness that a real harness process launched the run.
#
# It proves only one thing: that SOME harness process sits in this run's
# ancestry, so the "no harness launched this run" premise the no-marker
# assertion depends on is false. It deliberately does NOT prove launch validity.
# It matches presence by the same names and patterns bin/fm-harness.sh detect_own
# layer 2 recognizes, and nothing stricter, so it cannot drift finding by
# finding as OMP's identity proofs change.
#
# Cursor is the one shape whose name alone cannot decide it, so cursor reuses the
# shared bin/fm-cursor-lib.sh primitives the detector itself uses. The witness
# never calls the detector under test, so it stays an independent second signal.
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"

ambient_harness_in_ancestry() {
  local pid=$$ comm bc args argv0
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    if fm_cursor_process_matches "$comm" '' "$argv0"; then
      printf '%s\n' cursor
      return 0
    fi
    bc=$(basename -- "$comm")
    case "$bc" in
      *claude*|*codex*|*opencode*|*grok*|kimi|muse|muse-bin-*|pi|pi-signed|omp|bun)
        printf '%s\n' "$bc"
        return 0 ;;
      node*|python*)
        # Bare interpreter: the harness name lives in the script path instead.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*|*codex*|*opencode*|*grok*|*" pi "*|*/pi|*" omp "*|*/omp)
            printf '%s\n' "$bc"
            return 0 ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

test_ompcodes_outranks_claudecode() {
  local result
  result=$(detect_with OMPCODE=1 CLAUDECODE=1)
  expect_code 0 $? "omp detection should succeed"
  assert_contains "$result" "omp" "OMPCODE=1 + CLAUDECODE=1 should detect omp, got: $result"
}

test_ompcodes_outranks_pi_marker() {
  local result
  result=$(detect_with OMPCODE=1 PI_CODING_AGENT=true)
  assert_contains "$result" "omp" "OMPCODE=1 + PI_CODING_AGENT=true should detect omp, got: $result"
}

test_claudecode_alone_is_claude() {
  local result
  result=$(detect_with CLAUDECODE=1)
  assert_contains "$result" "claude" "CLAUDECODE=1 alone should detect claude, got: $result"
}

test_pi_marker_alone_is_pi() {
  local result
  result=$(detect_with PI_CODING_AGENT=true)
  assert_contains "$result" "pi" "PI_CODING_AGENT=true alone should detect pi, got: $result"
}

test_cursor_marker_still_wins() {
  local result
  result=$(detect_with CURSOR_AGENT=1 OMPCODE=1 CLAUDECODE=1)
  assert_contains "$result" "cursor" "CURSOR_AGENT=1 should outrank omp, got: $result"
}

test_grok_marker_still_detected() {
  local result
  result=$(detect_with GROK_AGENT=1 OMPCODE=1)
  assert_contains "$result" "grok" "GROK_AGENT=1 should outrank omp, got: $result"
}

test_no_markers_is_unknown() {
  local result status ambient
  result=$(detect_with)
  status=$?
  # With every env marker cleared, detection falls through to the layer-2 process
  # ancestry walk (bin/fm-harness.sh detect_own). That walk climbs this test's own
  # parent chain, so it only reads "unknown" when no harness process launched the
  # run - true in CI (a bare shell) but false when a developer runs the suite from
  # inside an ambient harness (claude, pi, ...), whose process sits in the ancestry
  # regardless of the cleared markers.
  #
  # Skip this one assertion ONLY on independent evidence that a harness really is in
  # the ancestry: the detector command must have succeeded, and a separate ancestry
  # walk (ambient_harness_in_ancestry) must itself find a harness process. That way a
  # genuine detector regression on clean CI - which would return "claude" or empty
  # from a broken or crashed detector with no harness actually present - still fails
  # here instead of masquerading as a skip. Every other test in this suite sets an
  # explicit marker that short-circuits before the walk, so they stay fully assertive.
  ambient=$(ambient_harness_in_ancestry || true)
  if [ "$status" -eq 0 ] && [ -n "$ambient" ] && [ "$result" != "unknown" ]; then
    echo "skip: ambient harness ($ambient) confirmed in this run's process ancestry; the no-marker walk cannot bottom out at unknown here"
    return 0
  fi
  assert_contains "$result" "unknown" "no markers should detect unknown, got: $result"
}

test_crew_resolution_defaults_to_own() {
  local result
  result=$(env -u CLAUDECODE -u OMPCODE -u PI_CODING_AGENT -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_PI_HARNESS \
      FM_CONFIG_OVERRIDE="$EMPTY_CONFIG" \
      OMPCODE=1 CLAUDECODE=1 "$HARNESS" crew)
  assert_contains "$result" "omp" "crew resolution with no config should mirror own (omp), got: $result"
}

test_ompcodes_outranks_claudecode
test_ompcodes_outranks_pi_marker
test_claudecode_alone_is_claude
test_pi_marker_alone_is_pi
test_cursor_marker_still_wins
test_grok_marker_still_detected
test_no_markers_is_unknown
test_crew_resolution_defaults_to_own
