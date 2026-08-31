#!/usr/bin/env bash
# Behavior tests for class-based crew dispatch resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_home() {
  local name=$1
  mkdir -p "$TMP_ROOT/$name/config" "$TMP_ROOT/$name/state"
  printf '%s\n' "$TMP_ROOT/$name"
}

write_meta() {
  local home=$1 id=$2 harness=$3 model=$4 effort=$5 kind=${6:-ship}
  cat > "$home/state/$id.meta" <<EOF
harness=$harness
model=$model
effort=$effort
kind=$kind
EOF
}

test_pinned_class() {
  local home out
  home=$(make_home pinned)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","when":"Builder work.","use":[{"harness":"pi","model":"xai/grok-4.6","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}],"default":{"harness":"claude","model":"sonnet","effort":"medium"}}
EOF
  out=$($RESOLVER --class builder --home "$home") || fail "pinned class did not resolve"
  [ "$out" = "harness=codex model=gpt-5.6-sol effort=high reason=pin" ] \
    || fail "pinned class resolved to '$out'"
  pass "a class pin selects its exact member"
}

test_unpinned_class_uses_fewest_live_workers() {
  local home out
  home=$(make_home uneven)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"tester","when":"Test work.","use":[{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}]}],"default":{"harness":"codex"}}
EOF
  write_meta "$home" worker-a claude opus high
  write_meta "$home" worker-b claude opus high
  write_meta "$home" worker-c codex gpt-5.6-sol xhigh
  write_meta "$home" secondmate-a pi xai/grok-4.6 high secondmate
  out=$($RESOLVER --class tester --home "$home") || fail "unpinned class did not resolve"
  [ "$out" = "harness=pi model=xai/grok-4.6 effort=high reason=round-robin" ] \
    || fail "uneven class resolved to '$out'"
  pass "round-robin chooses the enabled member with the fewest live workers"
}

test_switched_off_pin_refuses_without_fallback() {
  local home out status
  home=$(make_home switched-off-pin)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","when":"Builder work.","use":[{"harness":"codex","model":"gpt-5.6-sol","effort":"high","enabled":false},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}],"default":{"harness":"claude"}}
EOF
  out=$($RESOLVER --class builder --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a switched-off pin should fail"
  [ "$out" = "error: invalid config/crew-dispatch.json - pin names a switched-off member for builder: codex/gpt-5.6-sol/high" ] \
    || fail "switched-off pin returned '$out'"
  pass "a switched-off class pin refuses without fallback"
}

test_pin_accepts_an_enabled_duplicate_tuple() {
  local home out
  home=$(make_home duplicate-pin)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","when":"Builder work.","use":[{"harness":"codex","model":"gpt-5.6-sol","effort":"high","enabled":false},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}],"default":{"harness":"claude"}}
EOF
  out=$($RESOLVER --class builder --home "$home") || fail "pin with an enabled duplicate did not resolve"
  [ "$out" = "harness=codex model=gpt-5.6-sol effort=high reason=pin" ] \
    || fail "pin with an enabled duplicate resolved to '$out'"
  pass "a pin accepts an enabled duplicate exact tuple"
}

test_unknown_class_uses_default_pin() {
  local home out
  home=$(make_home default-pin)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","when":"Builder work.","use":{"harness":"pi"}}],"default":[{"harness":"claude","model":"sonnet","effort":"medium"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}],"defaultPin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}
EOF
  out=$($RESOLVER --class unknown --home "$home") || fail "default pin did not resolve"
  [ "$out" = "harness=codex model=gpt-5.6-sol effort=high reason=default-pin" ] \
    || fail "default pin resolved to '$out'"
  pass "an unknown class uses defaultPin"
}

test_unknown_class_round_robins_default() {
  local home out
  home=$(make_home default-pool)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","when":"Builder work.","use":{"harness":"pi"}}],"default":[{"harness":"claude","model":"sonnet","effort":"medium"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}]}
EOF
  write_meta "$home" worker-a claude sonnet medium
  out=$($RESOLVER --class unknown --home "$home") || fail "default pool did not resolve"
  [ "$out" = "harness=codex model=gpt-5.6-sol effort=high reason=default" ] \
    || fail "default pool resolved to '$out'"
  pass "an unknown class round-robins over default"
}

test_round_robin_breaks_ties_by_list_order() {
  local home out
  home=$(make_home tied)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"designer","when":"Design work.","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}]}],"default":{"harness":"codex"}}
EOF
  out=$($RESOLVER --class designer --home "$home") || fail "tied class did not resolve"
  [ "$out" = "harness=claude model=fable effort=xhigh reason=round-robin" ] \
    || fail "tied class resolved to '$out'"
  pass "round-robin breaks equal live-worker counts by list order"
}

test_pool_without_enabled_member_refuses() {
  local home out status
  home=$(make_home no-enabled-default)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","when":"Builder work.","use":{"harness":"pi"}}],"default":[{"harness":"codex","enabled":false}]}
EOF
  out=$($RESOLVER --class unknown --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a pool without an enabled member should fail"
  [ "$out" = "error: invalid config/crew-dispatch.json - every default rung is turned off" ] \
    || fail "empty enabled pool returned '$out'"
  pass "a pool without an enabled member refuses without fallback"
}

test_unsupported_runtime_refuses_before_output() {
  local home out status
  home=$(make_home unsupported-runtime)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","use":{"harness":"codex","model":"gpt-5.6-sol","effort":"max"}}]}
EOF
  out=$($RESOLVER --class builder --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "an unsupported configured runtime should fail"
  assert_contains "$out" "unsupported effort 'max' for class builder use profile 1 harness 'codex'" \
    "resolver did not name the unsupported configured runtime"
  assert_contains "$out" "supported efforts: low, medium, high, xhigh, or omit effort" \
    "resolver did not list the supported correction"
  assert_not_contains "$out" "harness=codex model=" \
    "resolver printed a successful runtime after validation failed"
  pass "the resolver validates runtime support before output"
}

test_pinned_class
test_unpinned_class_uses_fewest_live_workers
test_switched_off_pin_refuses_without_fallback
test_pin_accepts_an_enabled_duplicate_tuple
test_unknown_class_uses_default_pin
test_unknown_class_round_robins_default
test_round_robin_breaks_ties_by_list_order
test_pool_without_enabled_member_refuses
test_unsupported_runtime_refuses_before_output

echo "# all fm-dispatch-resolve tests passed"
