#!/usr/bin/env bash
# Tests for bin/fm-github-health.sh: the fleet's single GitHub reachability
# probe. It owns the durable state/.github-down flag and the confirmation guard
# that stops one bad request from parking the whole fleet.
#
# Matrix:
#   (a) confirmed-down (every attempt fails) sets the flag with a first-seen line
#   (b) recovery (reachable) clears the flag
#   (c) a single transient failure does NOT set the flag (the majority guard),
#       and the probe stops early on the confirming success rather than making
#       every attempt
#   (d) setting the flag twice is idempotent: the original first-seen is kept
#   (e) the probe is bounded: a stalled endpoint cannot hang it (real curl,
#       black-hole address, tight timeouts)
#   (f) `status` reports up/down from the flag without probing
#   (g) `transition` reports the new verdict ONLY on a real down<->up change
#       (once per transition, silent otherwise), reports a first-ever down but
#       stays silent on a first-ever up baseline
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEALTH="$ROOT/bin/fm-github-health.sh"
TMP_ROOT=$(fm_test_tmproot fm-github-health-tests)

# Fresh state dir per case.
make_state() {
  local name=$1 state
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

# Run the probe with a scripted per-attempt verdict via the FM_GH_HEALTH_PROBE_CMD
# seam, so the decision logic runs offline and deterministically.
run_probe() {  # <state> <probe-cmd> [attempts]
  local state=$1 cmd=$2 attempts=${3:-3}
  FM_STATE_OVERRIDE="$state" FM_GH_HEALTH_PROBE_CMD="$cmd" \
    FM_GH_HEALTH_ATTEMPTS="$attempts" "$HEALTH" probe
}

test_confirmed_down_sets_flag() {
  local state
  state=$(make_state confirmed-down)
  run_probe "$state" 'false' || fail "confirmed-down: probe should exit 0 even when down"
  assert_present "$state/.github-down" "confirmed-down: flag was not set"
  assert_grep 'first_seen=' "$state/.github-down" \
    "confirmed-down: flag has no first-seen timestamp"
  pass "fm-github-health sets .github-down on confirmed unreachability"
}

test_recovery_clears_flag() {
  local state
  state=$(make_state recovery)
  run_probe "$state" 'false' || fail "recovery: initial down probe failed"
  assert_present "$state/.github-down" "recovery: flag should be set before recovery"
  run_probe "$state" 'true' || fail "recovery: reachable probe failed"
  assert_absent "$state/.github-down" "recovery: flag was not cleared on recovery"
  pass "fm-github-health clears .github-down when GitHub becomes reachable"
}

test_single_transient_does_not_set_flag() {
  local state counter
  state=$(make_state single-transient)
  counter="$TMP_ROOT/single-transient/counter"
  echo 0 > "$counter"
  # Fail the first attempt, succeed on the second: a single transient failure.
  # With 3 attempts the majority (2) is never reached, so no flag.
  run_probe "$state" \
    "n=\$(cat '$counter'); n=\$((n+1)); echo \$n > '$counter'; [ \$n -ge 2 ]" 3 \
    || fail "single-transient: probe should exit 0"
  assert_absent "$state/.github-down" \
    "single-transient: one bad request must not set the flag"
  # Confirming success settles the verdict early: exactly two attempts, not three.
  [ "$(cat "$counter")" = 2 ] \
    || fail "single-transient: probe did not stop on the confirming success (attempts=$(cat "$counter"))"
  pass "fm-github-health tolerates a single transient failure and stops on confirmation"
}

test_set_flag_is_idempotent() {
  local state first second
  state=$(make_state idempotent)
  run_probe "$state" 'false' || fail "idempotent: first down probe failed"
  first=$(cat "$state/.github-down")
  # A second down probe must not overwrite the original first-seen timestamp.
  run_probe "$state" 'false' || fail "idempotent: second down probe failed"
  second=$(cat "$state/.github-down")
  [ "$first" = "$second" ] \
    || fail "idempotent: first-seen changed across repeated down probes ('$first' -> '$second')"
  pass "fm-github-health keeps the original first-seen across repeated down probes"
}

test_probe_is_bounded() {
  local state start elapsed
  state=$(make_state bounded)
  start=$SECONDS
  # Real curl against a non-routable (black-hole) address with tight timeouts.
  # If the probe were unbounded this would hang; it must return quickly.
  FM_STATE_OVERRIDE="$state" \
    FM_GH_HEALTH_URL='https://10.255.255.1' \
    FM_GH_HEALTH_ATTEMPTS=1 \
    FM_GH_HEALTH_MAX_TIME=2 \
    FM_GH_HEALTH_CONNECT_TIMEOUT=1 \
    "$HEALTH" probe || fail "bounded: probe should exit 0"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -le 10 ] \
    || fail "bounded: probe took ${elapsed}s against a black-hole endpoint (should be a few seconds)"
  assert_present "$state/.github-down" \
    "bounded: an unreachable endpoint should have set the flag"
  pass "fm-github-health is bounded and cannot hang on a stalled endpoint"
}

test_status_reports_without_probing() {
  local state out
  state=$(make_state status)
  out=$(FM_STATE_OVERRIDE="$state" "$HEALTH" status)
  [ "$out" = up ] || fail "status: expected 'up' with no flag, got '$out'"
  run_probe "$state" 'false' || fail "status: down probe failed"
  out=$(FM_STATE_OVERRIDE="$state" "$HEALTH" status)
  [ "$out" = down ] || fail "status: expected 'down' with flag present, got '$out'"
  pass "fm-github-health status reports up/down from the flag"
}

# Run the transition command with a scripted verdict; echo whatever it printed.
run_transition() {  # <state> <probe-cmd>
  local state=$1 cmd=$2
  FM_STATE_OVERRIDE="$state" FM_GH_HEALTH_PROBE_CMD="$cmd" FM_GH_HEALTH_ATTEMPTS=3 \
    "$HEALTH" transition
}

test_transition_reports_once_per_change() {
  local state out
  state=$(make_state transition)
  # First-ever observation is an outage in progress: report "down" once.
  out=$(run_transition "$state" 'false')
  [ "$out" = down ] || fail "transition: first-ever down should report 'down', got '$out'"
  # Still down: silent.
  out=$(run_transition "$state" 'false')
  [ -z "$out" ] || fail "transition: a repeated down should be silent, got '$out'"
  # Recovery: report "up" once.
  out=$(run_transition "$state" 'true')
  [ "$out" = up ] || fail "transition: recovery should report 'up', got '$out'"
  # Still up: silent.
  out=$(run_transition "$state" 'true')
  [ -z "$out" ] || fail "transition: a repeated up should be silent, got '$out'"
  # Back down: report "down" again.
  out=$(run_transition "$state" 'false')
  [ "$out" = down ] || fail "transition: a new outage should report 'down', got '$out'"
  pass "fm-github-health transition reports exactly once per down<->up change"
}

test_transition_silent_on_first_up_baseline() {
  local state out
  state=$(make_state transition-first-up)
  # First-ever observation is reachable: this is the normal baseline, not a
  # transition, so it must stay silent (no spurious "GitHub is back" report).
  out=$(run_transition "$state" 'true')
  [ -z "$out" ] || fail "transition: first-ever up baseline must be silent, got '$out'"
  assert_absent "$state/.github-down" "transition-first-up: reachable must not set the flag"
  pass "fm-github-health transition stays silent on a first-ever reachable baseline"
}

test_confirmed_down_sets_flag
test_recovery_clears_flag
test_single_transient_does_not_set_flag
test_set_flag_is_idempotent
test_probe_is_bounded
test_status_reports_without_probing
test_transition_reports_once_per_change
test_transition_silent_on_first_up_baseline
