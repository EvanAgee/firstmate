#!/usr/bin/env bash
# Behavior tests for the availability/pause/quarantine filters in
# bin/fm-dispatch-resolve.sh and bin/fm-dispatch-validate.sh.
#
# The contract these tests pin: a rung dispatches only when it is available,
# not paused, and not quarantined. Availability is a live route reading owned
# by bin/fm-route.sh, so no capacity fact lives in the config; a pause and a
# quarantine are the two explicit human reasons that do.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-dispatch-resolve.sh"
VALIDATOR="$ROOT/bin/fm-dispatch-validate.sh"
ROUTE="$ROOT/bin/fm-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve-availability)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_home() {  # <name> <crew-dispatch.json body>
  local name=$1 body=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state"
  printf '%s' "$body" > "$home/config/crew-dispatch.json"
  printf '%s\n' "$home"
}

seed_routes() {  # <home> <json-routes-object>
  local home=$1 routes=$2
  jq -n --argjson routes "$routes" '{generation:1, routes:$routes, assignments:{}}' \
    > "$home/state/route.json"
}

acquire() {  # <home> <assignment> <gen> <routes-json-array>
  local home=$1 assignment=$2 gen=$3 routes=$4
  jq -cn --arg a "$assignment" --arg owner "$assignment" --arg gen "$gen" --argjson routes "$routes" \
    '{assignment_id:$a, owner:{identity:$owner, generation:$gen}, routes:$routes}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" acquire
}

# A probe that reports every provider fully healthy, including each model
# scope. Substituting it proves a clean probe alone never changes a pause or a
# quarantine verdict.
write_clean_quota_axi() {  # <fakebin>
  cat > "$1/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider=unknown
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) provider=${2:-unknown}; shift 2 ;;
    *) shift ;;
  esac
done
cat <<JSON
{"generatedAt":"2026-09-18T00:00:00.000Z","schemaVersion":3,"providers":[{"provider":"$provider","label":"$provider","source":"oauth","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":100},{"scope":"model:fable","status":"known","effectivePercentRemaining":100},{"scope":"model:opus","status":"known","effectivePercentRemaining":100},{"scope":"model:gpt-5","status":"known","effectivePercentRemaining":100}]},"state":{"status":"fresh","stale":false,"refreshedAt":"2026-09-18T00:00:00.000Z","sourcesTried":["oauth"]}}]}
JSON
SH
  chmod +x "$1/quota-axi"
}

test_paused_rung_never_dispatches_while_its_route_reads_eligible() {
  local home out
  home=$(make_home paused "$(cat <<'EOF'
{"rules":[{"class":"builder","use":[
  {"harness":"codex","model":"gpt-5","effort":"high"},
  {"harness":"pi","model":"xai/grok-4.6","effort":"high","paused":{"reason":"captain is preserving the Grok subscription"}}
]}]}
EOF
)")
  # The paused rung's own route reads eligible; only the pause removes it.
  [ "$("$ROUTE" group-for --harness pi --model xai/grok-4.6)" = pi-grok ] \
    || fail "test setup: grok should map to the pi-grok route"
  out=$("$RESOLVER" --class builder --home "$home" --list-candidate-routes | sort | tr '\n' ' ')
  [ "$out" = "codex " ] || fail "a paused rung's route must never be a candidate: $out"
  out=$("$RESOLVER" --class builder --home "$home") || fail "builder did not resolve around the paused rung"
  [ "$out" = "harness=codex model=gpt-5 effort=high reason=round-robin" ] \
    || fail "a paused rung was selectable: $out"
  pass "a paused rung never dispatches while its own route reads eligible"
}

test_pause_reason_shows_in_the_resolver_refusal() {
  local home out status
  home=$(make_home paused-only "$(cat <<'EOF'
{"rules":[{"class":"solo","use":[
  {"harness":"pi","model":"xai/grok-4.6","effort":"high","paused":{"reason":"captain is preserving the Grok subscription"}}
]}]}
EOF
)")
  out=$("$RESOLVER" --class solo --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a pool with only a paused rung should refuse"
  assert_contains "$out" "paused: captain is preserving the Grok subscription" \
    "the resolver refusal did not show the pause reason"
  pass "a pause reason is visible in the resolver's refusal"
}

test_expired_until_ends_a_pause_on_its_own() {
  local home out status
  home=$(make_home pause-future "$(cat <<'EOF'
{"rules":[{"class":"solo","use":[
  {"harness":"codex","model":"gpt-5","effort":"high","paused":{"reason":"preserve subscription","until":"2099-01-01"}}
]}]}
EOF
)")
  out=$("$RESOLVER" --class solo --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a pause with a future until date should still hold"
  assert_contains "$out" "paused: preserve subscription" "future-until pause did not hold"

  home=$(make_home pause-past "$(cat <<'EOF'
{"rules":[{"class":"solo","use":[
  {"harness":"codex","model":"gpt-5","effort":"high","paused":{"reason":"preserve subscription","until":"2000-01-01"}}
]}]}
EOF
)")
  out=$("$RESOLVER" --class solo --home "$home") \
    || fail "an expired until date did not end the pause"
  [ "$out" = "harness=codex model=gpt-5 effort=high reason=round-robin" ] \
    || fail "expired-until rung resolved to '$out'"
  pass "a passed until date ends a pause on its own"
}

test_quarantined_rung_never_dispatches_even_after_a_clean_probe() {
  local home out fakebin
  home=$(make_home quarantined "$(cat <<'EOF'
{"rules":[{"class":"designer","use":[
  {"harness":"claude","model":"fable","effort":"xhigh","quarantined":{"evidence":"died with 13 rate-limit errors on a real brief","release":"a probe that sends a real 20k-token brief"}},
  {"harness":"claude","model":"opus","effort":"high"}
]}]}
EOF
)")
  fakebin=$(fm_fakebin "$home")
  write_clean_quota_axi "$fakebin"
  out=$(PATH="$fakebin:$PATH" FM_DISPATCH_QUOTA_AXI_BIN=quota-axi \
    "$RESOLVER" --class designer --home "$home") \
    || fail "designer did not resolve around the quarantined rung"
  [ "$out" = "harness=claude model=opus effort=high reason=round-robin" ] \
    || fail "a clean probe readmitted the quarantined rung: $out"
  pass "a quarantined rung stays out even when its own route probes clean"
}

test_glm_plain_is_quarantined_and_out() {
  local home out status
  home=$(make_home glm "$(cat <<'EOF'
{"rules":[{"class":"builder","use":[
  {"harness":"pi","model":"phala/z-ai/glm-5.3","effort":"xhigh","quarantined":{"evidence":"second 429 storm on a builder first turn minutes after a clean probe","release":"a probe that sends a real 20k-token brief"}},
  {"harness":"pi","model":"phala/moonshotai/kimi-k3","effort":"high"}
]}]}
EOF
)")
  out=$("$RESOLVER" --class builder --home "$home") || fail "builder did not resolve around the quarantined GLM rung"
  [ "$out" = "harness=pi model=phala/moonshotai/kimi-k3 effort=high reason=round-robin" ] \
    || fail "the quarantined GLM rung was selectable: $out"

  home=$(make_home glm-only "$(cat <<'EOF'
{"rules":[{"class":"solo","use":[
  {"harness":"pi","model":"phala/z-ai/glm-5.3","effort":"xhigh","quarantined":{"evidence":"second 429 storm on a builder first turn","release":"a probe that sends a real 20k-token brief"}}
]}]}
EOF
)")
  out=$("$RESOLVER" --class solo --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a pool with only a quarantined rung should refuse"
  assert_contains "$out" "quarantined: second 429 storm on a builder first turn" \
    "the resolver refusal did not show the quarantine evidence"
  pass "pi/phala/z-ai/glm-5.3 is quarantined and never dispatches"
}

test_quarantined_pin_refuses_and_names_the_release() {
  local home out status
  home=$(make_home quarantined-pin "$(cat <<'EOF'
{"rules":[{"class":"builder","use":[
  {"harness":"pi","model":"phala/z-ai/glm-5.3","effort":"xhigh","quarantined":{"evidence":"429 storm on a real brief","release":"a probe that sends a real 20k-token brief"}},
  {"harness":"pi","model":"phala/moonshotai/kimi-k3","effort":"high"}
],"pin":{"harness":"pi","model":"phala/z-ai/glm-5.3","effort":"xhigh"}}]}
EOF
)")
  out=$("$RESOLVER" --class builder --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a quarantined pin should refuse without fallback"
  assert_contains "$out" "names a switched-off member (quarantined: 429 storm on a real brief)" \
    "the pin refusal did not carry the quarantine evidence"
  pass "a quarantined pin refuses without fallback and names its evidence"
}

test_route_availability_decides_with_no_config_edit() {
  local home route_home out picked
  home=$(make_home route-availability '{"rules":[{"class":"builder","use":[{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}]}]}')
  route_home="$TMP_ROOT/route-canonical"
  mkdir -p "$route_home/state" "$route_home/config"
  cp "$home/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"

  seed_routes "$route_home" '{"codex":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  picked=$(acquire "$route_home" a1 g1 '["codex","pi-grok"]' | jq -r '.route_id')
  [ "$picked" = pi-grok ] || fail "an exhausted route was still acquired: $picked"
  out=$("$RESOLVER" --class builder --home "$home" --exclude-routes codex) \
    || fail "resolver failed after route admission steered away from codex"
  [ "$out" = "harness=pi model=xai/grok-4.6 effort=high reason=round-robin" ] \
    || fail "exhausted codex did not yield to grok: $out"

  seed_routes "$route_home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false}}'
  picked=$(acquire "$route_home" a2 g1 '["codex","pi-grok"]' | jq -r '.route_id')
  [ "$picked" = codex ] || fail "returned capacity did not readmit codex: $picked"
  out=$("$RESOLVER" --class builder --home "$home" --exclude-routes pi-grok) \
    || fail "resolver failed after route admission chose codex"
  [ "$out" = "harness=codex model=gpt-5 effort=high reason=round-robin" ] \
    || fail "returned codex capacity did not dispatch codex: $out"
  pass "route capacity decides dispatch in both directions with no config edit"
}

test_malformed_pause_quarantine_and_history_refuse() {
  local home out status
  for body in \
    '{"rules":[{"class":"b","use":[{"harness":"codex","paused":"soon"}]}]}' \
    '{"rules":[{"class":"b","use":[{"harness":"codex","paused":{}}]}]}' \
    '{"rules":[{"class":"b","use":[{"harness":"codex","paused":{"reason":"x","until":"tomorrow"}}]}]}' \
    '{"rules":[{"class":"b","use":[{"harness":"codex","quarantined":{"evidence":"x"}}]}]}' \
    '{"rules":[{"class":"b","use":[{"harness":"codex","history":["a"]}]}]}' \
    ; do
    home=$(make_home malformed "$body")
    out=$("$VALIDATOR" --file "$home/config/crew-dispatch.json" 2>&1)
    status=$?
    expect_code 1 "$status" "malformed dispatch config should refuse: $body"
    [ -n "$out" ] || fail "malformed config refusal printed no reason: $body"
  done

  home=$(make_home malformed-json '{bad')
  out=$("$RESOLVER" --class b --home "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "malformed JSON should refuse the resolve"
  assert_contains "$out" "malformed JSON" "malformed JSON refusal lost its reason"
  pass "malformed pause, quarantine, history, and JSON all refuse"
}

test_valid_pause_quarantine_and_history_validate() {
  local home
  home=$(make_home valid "$(cat <<'EOF'
{"rules":[{"class":"builder","use":[
  {"harness":"codex","model":"gpt-5","effort":"high","history":"codex burned a weekly window"},
  {"harness":"pi","model":"xai/grok-4.6","effort":"high","paused":{"reason":"preference"},"history":"captain prefers Astra"},
  {"harness":"pi","model":"phala/z-ai/glm-5.3","effort":"xhigh","quarantined":{"evidence":"429 storm","release":"real 20k probe"},"history":"two 429 storms"}
]}]}
EOF
)")
  "$VALIDATOR" --file "$home/config/crew-dispatch.json" \
    || fail "a valid pause/quarantine/history config should validate"
  pass "a valid pause, quarantine, and history config validates"
}

test_paused_rung_never_dispatches_while_its_route_reads_eligible
test_pause_reason_shows_in_the_resolver_refusal
test_expired_until_ends_a_pause_on_its_own
test_quarantined_rung_never_dispatches_even_after_a_clean_probe
test_glm_plain_is_quarantined_and_out
test_quarantined_pin_refuses_and_names_the_release
test_route_availability_decides_with_no_config_edit
test_malformed_pause_quarantine_and_history_refuse
test_valid_pause_quarantine_and_history_validate

echo "# all fm-dispatch-resolve-availability tests passed"