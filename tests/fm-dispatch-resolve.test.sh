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

test_override_ignores_disabled_tuple_outside_resolved_pool() {
  local home out
  home=$(make_home override-pool-scope)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"builder","use":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}},{"class":"tester","use":[{"harness":"claude","model":"opus","effort":"high","enabled":false},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}]}],"default":[{"harness":"claude","model":"opus","effort":"high","enabled":false},{"harness":"codex","model":"gpt-5.6-sol","effort":"medium"}]}
EOF
  out=$($RESOLVER --class builder --home "$home" \
    --override-harness claude --override-model opus --override-effort high) \
    || fail "an override matching a disabled tuple outside its pool did not resolve"
  [ "$out" = "harness=claude model=opus effort=high reason=round-robin" ] \
    || fail "cross-pool disabled tuple changed the override to '$out'"
  pass "an override checks disabled members only in its resolved pool"
}

# A model-specific window can be exhausted while the account-wide bound is
# fine (quota-axi: "A model-specific window is an additional bound"). The
# fake quota-axi below reports claude/fable's model:fable scope at 0%
# effective remaining while all_models stays healthy, so the fable rung must
# be excluded from the pool while the account-wide route (fm-route.sh)
# would still admit claude.
test_model_specific_exhaustion_excludes_only_that_model() {
  local home out fakebin
  home=$(make_home model-specific-limit)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"designer","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"claude","model":"opus","effort":"high"}]}]}
EOF
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"--provider claude"*)
    cat <<'JSON'
{
  "generatedAt": "2026-09-15T00:00:00.000Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "oauth",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 64},
          {"scope": "model:fable", "status": "known", "effectivePercentRemaining": 0}
        ]
      },
      "state": {"status": "fresh", "stale": false, "refreshedAt": "2026-09-15T00:00:00.000Z", "sourcesTried": ["oauth"]}
    }
  ]
}
JSON
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$PATH" FM_DISPATCH_QUOTA_AXI_BIN=quota-axi \
    $RESOLVER --class designer --home "$home") || fail "designer class did not resolve around the exhausted model"
  [ "$out" = "harness=claude model=opus effort=high reason=round-robin" ] \
    || fail "model-specific exhaustion did not steer the resolver away from fable, got '$out'"
  pass "a model-specific exhausted window excludes only that model, not the whole account/route"
}

# --list-candidate-routes is the single owner of "which routes can this class
# currently be served by". Every answer it gives must be a route the real
# resolve then accepts, which is the invariant the route admission caller
# depends on: a candidate it cannot resolve to becomes an --exclude-routes
# entry that switches off the pool's only usable member.
candidate_routes() {  # <home> [extra-path]
  local home=$1 class=$2 extra=${3:-}
  PATH="${extra:+$extra:}$PATH" FM_DISPATCH_QUOTA_AXI_BIN=quota-axi \
    $RESOLVER --class "$class" --home "$home" --list-candidate-routes
}

test_candidate_routes_lists_only_servable_routes() {
  local home out
  home=$(make_home candidate-basic)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"designer","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}]},{"class":"tester","use":[{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"},{"harness":"pi","model":"xai/grok-4.6","effort":"high","enabled":false}]},{"class":"builder","use":[{"harness":"pi","model":"xai/grok-4.6","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"},{"harness":"claude","model":"opus","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}],"default":[{"harness":"codex","model":"gpt-5.6-sol","effort":"high"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}]}
EOF
  out=$(candidate_routes "$home" designer | sort | tr '\n' ' ')
  [ "$out" = "claude codex " ] || fail "designer candidates wrong: $out"

  # tester's only pi member is switched off, so pi-grok is not servable.
  out=$(candidate_routes "$home" tester | sort | tr '\n' ' ')
  [ "$out" = "claude codex " ] \
    || fail "a switched-off member's route must never be a candidate: $out"

  # A pinned class always resolves to its pin, so it offers exactly that route.
  out=$(candidate_routes "$home" builder | sort | tr '\n' ' ')
  [ "$out" = "codex " ] || fail "a pinned class must offer only its pin's route: $out"

  # An unmatched class falls through to the default pool.
  out=$(candidate_routes "$home" nosuchclass | sort | tr '\n' ' ')
  [ "$out" = "codex pi-grok " ] || fail "default-pool candidates wrong: $out"
  pass "--list-candidate-routes lists only the routes a class can actually be served by"
}

# The regression this whole mode exists for: a class whose ONLY member on a
# route has an exhausted model-scoped window. The static enabled column says
# that member is fine, so any separate copy of the eligibility rules offers
# its route; the real resolve then refuses once the sibling route is
# excluded. Same fake quota-axi shape as
# test_model_specific_exhaustion_excludes_only_that_model (account 64%,
# model:fable 0%).
test_candidate_routes_drops_a_model_exhausted_only_member() {
  local home out fakebin resolved
  home=$(make_home candidate-model-exhausted)
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"class":"designer","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}]}]}
EOF
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"--provider claude"*)
    cat <<'JSON'
{"generatedAt":"2026-09-15T00:00:00.000Z","schemaVersion":3,"providers":[{"provider":"claude","label":"Claude","source":"oauth","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":64},{"scope":"model:fable","status":"known","effectivePercentRemaining":0}]},"state":{"status":"fresh","stale":false,"refreshedAt":"2026-09-15T00:00:00.000Z","sourcesTried":["oauth"]}}]}
JSON
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/quota-axi"

  out=$(candidate_routes "$home" designer "$fakebin" | sort | tr '\n' ' ')
  [ "$out" = "codex " ] \
    || fail "claude's only designer member has a dead model window, so claude must not be a candidate: $out"

  # Every listed candidate must survive the real resolve once the others are
  # excluded, which is exactly how the admission caller uses this list.
  resolved=$(PATH="$fakebin:$PATH" FM_DISPATCH_QUOTA_AXI_BIN=quota-axi \
    $RESOLVER --class designer --home "$home" --exclude-routes claude) \
    || fail "the listed candidate did not survive a real resolve"
  [ "$resolved" = "harness=codex model=gpt-5.6-sol effort=high reason=round-robin" ] \
    || fail "resolve of the listed candidate returned '$resolved'"
  pass "a route whose only class member has an exhausted model window is never a candidate"
}

test_pinned_class
test_unpinned_class_uses_fewest_live_workers
test_switched_off_pin_refuses_without_fallback
test_pin_accepts_an_enabled_duplicate_tuple
test_unknown_class_uses_default_pin
test_unknown_class_round_robins_default
test_model_specific_exhaustion_excludes_only_that_model
test_round_robin_breaks_ties_by_list_order
test_pool_without_enabled_member_refuses
test_unsupported_runtime_refuses_before_output
test_override_ignores_disabled_tuple_outside_resolved_pool
test_candidate_routes_lists_only_servable_routes
test_candidate_routes_drops_a_model_exhausted_only_member

echo "# all fm-dispatch-resolve tests passed"
