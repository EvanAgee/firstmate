#!/usr/bin/env bash
# Behavior tests for the durable ordinary-builder split selector.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-builder-split-tests)
SCRIPT="$ROOT/bin/fm-builder-split.sh"

write_config() {
  local home=$1 split=$2
  mkdir -p "$home/config" "$home/state"
  printf '{"rules":[{"when":"ordinary builder","use":[{"harness":"codex"},{"harness":"pi"},{"harness":"claude"}]%s}]}\n' \
    "$split" > "$home/config/crew-dispatch.json"
}

select_builder() {
  local home=$1
  shift
  FM_HOME="$home" "$SCRIPT" --rule-index 0 "$@"
}

test_default_split_stays_even_and_alternates() {
  local home out i codex_count=0 pi_count=0 previous=
  home="$TMP_ROOT/default-even"
  write_config "$home" ''

  for ((i = 0; i < 100; i++)); do
    out=$(select_builder "$home" --healthy codex --healthy pi 2>/dev/null)
    [ "$out" != "$previous" ] || fail "50/50 split repeated $out at assignment $i"
    previous=$out
    case "$out" in
      codex) codex_count=$((codex_count + 1)) ;;
      pi) pi_count=$((pi_count + 1)) ;;
      *) fail "50/50 split returned unexpected rung: $out" ;;
    esac
  done

  [ "$codex_count" -eq 50 ] || fail "50/50 split selected codex $codex_count times"
  [ "$pi_count" -eq 50 ] || fail "50/50 split selected pi $pi_count times"
  [ "$(cat "$home/state/.builder-dispatch-counter")" -eq 100 ] \
    || fail "50/50 split did not persist all 100 assignments"
  pass "ordinary builders alternate evenly with the default split"
}

test_unhealthy_preference_degrades_and_advances() {
  local home first second
  home="$TMP_ROOT/degrade"
  write_config "$home" ',"split":{"codex":50,"pi":50}'

  first=$(select_builder "$home" --healthy pi)
  [ "$first" = pi ] || fail "unhealthy codex did not degrade to pi: $first"
  [ "$(cat "$home/state/.builder-dispatch-counter")" -eq 1 ] \
    || fail "degraded selection did not advance the counter"

  second=$(select_builder "$home" --healthy codex --healthy pi)
  [ "$second" = pi ] \
    || fail "counter did not advance through the degraded codex slot: $second"
  [ "$(cat "$home/state/.builder-dispatch-counter")" -eq 2 ] \
    || fail "healthy selection after degradation did not advance the counter"
  pass "an unhealthy preferred rung degrades to the other tool and advances"
}

test_both_split_rungs_unhealthy_reaches_fallback_and_advances() {
  local home out
  home="$TMP_ROOT/both-down"
  write_config "$home" ',"split":{"codex":50,"pi":50}'

  out=$(select_builder "$home")
  [ "$out" = fallback ] || fail "two unhealthy split rungs did not return fallback: $out"
  [ "$(cat "$home/state/.builder-dispatch-counter")" -eq 1 ] \
    || fail "lower-ladder fallback did not advance the counter"
  pass "two unhealthy split rungs hand control to the lower ladder"
}

test_high_tier_bypasses_without_touching_counter() {
  local home out
  home="$TMP_ROOT/high-tier"
  write_config "$home" ',"split":{"codex":50,"pi":50}'
  printf '7\n' > "$home/state/.builder-dispatch-counter"

  out=$(select_builder "$home" --high-tier --healthy codex --healthy pi)
  [ "$out" = bypass ] || fail "high-tier builder did not bypass the split: $out"
  [ "$(cat "$home/state/.builder-dispatch-counter")" -eq 7 ] \
    || fail "high-tier builder changed the ordinary-builder counter"
  pass "high-tier builders bypass the split"
}

test_configured_weight_changes_the_ratio() {
  local home out i codex_count=0 pi_count=0
  home="$TMP_ROOT/weighted"
  write_config "$home" ',"split":{"codex":70,"pi":30}'

  for ((i = 0; i < 100; i++)); do
    out=$(select_builder "$home" --healthy codex --healthy pi)
    case "$out" in
      codex) codex_count=$((codex_count + 1)) ;;
      pi) pi_count=$((pi_count + 1)) ;;
      *) fail "70/30 split returned unexpected rung: $out" ;;
    esac
  done

  [ "$codex_count" -eq 70 ] || fail "70/30 config selected codex $codex_count times"
  [ "$pi_count" -eq 30 ] || fail "70/30 config selected pi $pi_count times"
  pass "the selector reads non-default weights from the matched config rule"
}

test_malformed_split_falls_back_with_a_note() {
  local home out err
  home="$TMP_ROOT/malformed"
  write_config "$home" ',"split":{"codex":70,"pi":"thirty"}'
  err="$home/stderr"

  out=$(select_builder "$home" --healthy codex --healthy pi 2> "$err")
  [ "$out" = codex ] || fail "malformed split did not use the 50/50 first slot: $out"
  assert_contains "$(cat "$err")" \
    "BUILDER_DISPATCH: split malformed for rule 0; using codex=50, pi=50" \
    "malformed split fallback was silent"
  pass "malformed weights use the documented 50/50 fallback with a note"
}

test_absent_split_falls_back_with_a_note() {
  local home out err
  home="$TMP_ROOT/absent"
  write_config "$home" ''
  err="$home/stderr"

  out=$(select_builder "$home" --healthy codex --healthy pi 2> "$err")
  [ "$out" = codex ] || fail "absent split did not use the 50/50 first slot: $out"
  assert_contains "$(cat "$err")" \
    "BUILDER_DISPATCH: split absent for rule 0; using codex=50, pi=50" \
    "absent split fallback was silent"
  pass "absent weights use the documented 50/50 fallback with a note"
}

test_missing_counter_starts_cleanly() {
  local home out
  home="$TMP_ROOT/missing-counter"
  write_config "$home" ',"split":{"codex":50,"pi":50}'

  out=$(select_builder "$home" --healthy codex --healthy pi)
  [ "$out" = codex ] || fail "missing counter did not start from the first slot: $out"
  [ "$(cat "$home/state/.builder-dispatch-counter")" -eq 1 ] \
    || fail "missing counter did not initialize to one completed assignment"
  pass "a missing counter resets the schedule cleanly"
}

test_default_split_stays_even_and_alternates
test_unhealthy_preference_degrades_and_advances
test_both_split_rungs_unhealthy_reaches_fallback_and_advances
test_high_tier_bypasses_without_touching_counter
test_configured_weight_changes_the_ratio
test_malformed_split_falls_back_with_a_note
test_absent_split_falls_back_with_a_note
test_missing_counter_starts_cleanly
