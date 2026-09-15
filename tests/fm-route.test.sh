#!/usr/bin/env bash
# Behavior tests for bin/fm-route.sh: the shared provider-availability
# admission gate (docs/provider-availability-routing.md is the interface
# contract this file exercises). Every test drives the real script through
# its public JSON stdin/stdout protocol (acquire/finish) or its flag
# subcommands (refresh/status/disable/enable/routes/group-for), with fake
# bounded provider readers substituted on PATH -- never against invented
# fixture shapes, since the probes themselves are unit-verified against live
# tool output separately (docs/provider-availability-routing.md's "Evidence
# sources").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-route)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_home() {  # <name> <crew-dispatch.json body>
  local name=$1 body=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s' "$body" > "$home/config/crew-dispatch.json"
  printf '%s\n' "$home"
}

# The four-route pool the brief requires coverage for: Claude, Codex,
# Pi/Grok, and OMP/Gateway-DeepSeek.
FOUR_ROUTE_POOL='{"rules":[{"class":"builder","use":[{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"claude","model":"opus","effort":"xhigh"},{"harness":"pi","model":"xai/grok-4.6","effort":"xhigh"},{"harness":"omp","model":"vercel-ai-gateway/deepseek/deepseek-v4.1-flash","effort":"xhigh"}]}]}'

seed_routes() {  # <home> <json-routes-object>
  local home=$1 routes=$2
  jq -n --argjson routes "$routes" '{generation:1, routes:$routes, assignments:{}}' > "$home/state/route.json"
}

acquire() {  # <home> <assignment> <owner> <gen> <routes-json-array>
  local home=$1 assignment=$2 owner=$3 gen=$4 routes=$5
  jq -cn --arg a "$assignment" --arg owner "$owner" --arg gen "$gen" --argjson routes "$routes" \
    '{assignment_id:$a, owner:{identity:$owner, generation:$gen}, routes:$routes}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" acquire
}

finish() {  # <home> <assignment> <outcome> [profile-json]
  local home=$1 assignment=$2 outcome=$3 profile=${4:-null}
  jq -cn --arg a "$assignment" --arg outcome "$outcome" --argjson profile "$profile" \
    '{assignment_id:$a, outcome:$outcome} + (if $profile != null then {profile:$profile} else {} end)' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" finish
}

result_field() {  # <json> <field>
  jq -r --arg f "$2" '.[$f] // empty' <<<"$1"
}

# ---------------------------------------------------------------------------
# All four service assignments
# ---------------------------------------------------------------------------
test_all_four_routes_derived_and_assignable() {
  local home routes out r
  home=$(make_home four-routes "$FOUR_ROUTE_POOL")
  routes=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes | sort)
  [ "$routes" = "$(printf 'claude\ncodex\npi-deepseek\npi-grok\n')" ] \
    || fail "expected all four routes derived, got: $routes"

  seed_routes "$home" '{
    "claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
    "codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
    "pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
    "pi-deepseek":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}
  }'
  for r in claude codex pi-grok pi-deepseek; do
    out=$(acquire "$home" "job-$r" "job-$r" g1 "[\"$r\"]")
    [ "$(result_field "$out" result)" = selected ] || fail "route $r did not admit: $out"
    [ "$(result_field "$out" route_id)" = "$r" ] || fail "route $r selected a different route: $out"
  done
  pass "all four approved routes are derived and independently assignable"
}

# ---------------------------------------------------------------------------
# Exhaustion / outage / auth failure exclusion
# ---------------------------------------------------------------------------
test_exhaustion_outage_auth_failure_exclude() {
  local home out
  home=$(make_home excl-states "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{
    "claude":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false},
    "codex":{"state":"outage","reason":"down","observedAt":"t","manualDisabled":false},
    "pi-grok":{"state":"auth-failed","reason":"sign-in required","observedAt":"t","manualDisabled":false},
    "pi-deepseek":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}
  }'
  out=$(acquire "$home" a1 a1 g1 '["claude","codex","pi-grok","pi-deepseek"]')
  [ "$(result_field "$out" result)" = selected ] || fail "expected the one eligible route to win: $out"
  [ "$(result_field "$out" route_id)" = pi-deepseek ] || fail "expected pi-deepseek, got: $out"

  out=$(acquire "$home" a2 a2 g1 '["claude","codex","pi-grok"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "expected deferred when every candidate excluded: $out"
  pass "exhausted, outage, and auth-failed routes are all excluded from selection"
}

# ---------------------------------------------------------------------------
# Stale / unknown inputs
# ---------------------------------------------------------------------------
test_unknown_never_selected_never_proven_unavailable() {
  local home out
  home=$(make_home unknown-state "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"claude":{"state":"unknown","reason":"stale telemetry","observedAt":"t","manualDisabled":false}}'
  out=$(acquire "$home" a1 a1 g1 '["claude"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "unknown route should defer, not select: $out"
  reason=$(result_field "$out" reason)
  case "$reason" in
    *unknown*) : ;;
    *) fail "deferred reason did not distinguish the unknown case: $reason" ;;
  esac
  pass "unknown telemetry defers explicitly and is never selected or treated as proven unavailable"
}

# ---------------------------------------------------------------------------
# Verified recovery (fresh evidence re-enables automatic eligibility)
# ---------------------------------------------------------------------------
test_verified_recovery_reenables_after_deferral() {
  local home out
  home=$(make_home recovery "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false}}'
  out=$(acquire "$home" a1 a1 g1 '["codex"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "expected initial deferral: $out"

  jq '.routes.codex.state = "eligible" | .routes.codex.reason = "fresh probe"' \
    "$home/state/route.json" > "$home/state/route.json.tmp" && mv "$home/state/route.json.tmp" "$home/state/route.json"

  out=$(acquire "$home" a1 a1 g1 '["codex"]')
  [ "$(result_field "$out" result)" = selected ] || fail "fresh eligible evidence should re-admit the retried assignment: $out"
  pass "fresh verified-eligible evidence re-enables automatic eligibility on retry"
}

# ---------------------------------------------------------------------------
# Manual disable (immediate, survives refresh, distinct from automatic state)
# ---------------------------------------------------------------------------
test_manual_disable_wins_and_survives() {
  local home out
  home=$(make_home manual-disable "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" disable --route codex >/dev/null
  out=$(acquire "$home" a1 a1 g1 '["codex"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "manually disabled route must be excluded even while state=eligible: $out"

  # Survives a state change that would otherwise re-admit it.
  jq '.routes.codex.state = "eligible"' "$home/state/route.json" > "$home/state/route.json.tmp" \
    && mv "$home/state/route.json.tmp" "$home/state/route.json"
  out=$(acquire "$home" a2 a2 g1 '["codex"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "manual disable must survive an eligible state reading: $out"

  FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" enable --route codex >/dev/null
  out=$(acquire "$home" a2 a2 g1 '["codex"]')
  [ "$(result_field "$out" result)" = selected ] || fail "explicit enable should clear the manual disable: $out"
  pass "manual disable takes effect immediately, survives eligible readings, and only explicit enable clears it"
}

# ---------------------------------------------------------------------------
# Zero prepaid Grok balance is not subscription exhaustion
# ---------------------------------------------------------------------------
test_zero_prepaid_grok_credits_not_exhaustion() {
  local home fakebin out
  home=$(make_home grok-prepaid "$FOUR_ROUTE_POOL")
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"--provider grok"*)
    cat <<'JSON'
{
  "generatedAt": "2026-09-15T00:00:00.000Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "grok",
      "label": "Grok",
      "source": "web",
      "windows": [{"id": "credits", "label": "credits", "kind": "credits", "percentUsed": 17, "percentRemaining": 83}],
      "state": {"status": "fresh", "stale": false, "refreshedAt": "2026-09-15T00:00:00.000Z", "sourcesTried": ["web"], "authStatus": "usable"},
      "credits": {"remaining": 0, "unit": "credits"},
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [{"scope": "all_products", "status": "known", "effectivePercentRemaining": 83, "boundedBy": ["credits"]}]
      }
    }
  ]
}
JSON
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null
  out=$(PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route pi-grok)
  case "$out" in
    *state=eligible*) : ;;
    *) fail "zero prepaid credits.remaining with a healthy subscription window must still read eligible: $out" ;;
  esac
  pass "zero prepaid Grok credits.remaining never overrides a healthy subscription-window reading"
}

test_zero_prepaid_grok_credits_alone_is_unknown_not_exhausted() {
  local home fakebin out
  home=$(make_home grok-prepaid-only "$FOUR_ROUTE_POOL")
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"--provider grok"*)
    cat <<'JSON'
{
  "generatedAt": "2026-09-15T00:00:00.000Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "grok",
      "label": "Grok",
      "source": "cache",
      "windows": [{"id": "credits", "label": "credits", "kind": "credits", "percentUsed": 17, "percentRemaining": 83}],
      "state": {"status": "stale", "stale": true, "refreshedAt": "2026-09-12T11:59:49.274Z", "sourcesTried": ["web","pi:xai","cache"], "error": "Grok consumer quota unavailable", "authStatus": "usable"},
      "credits": {"remaining": 0, "unit": "credits"},
      "quotaSemantics": {"status": "unknown", "effectiveAvailability": [{"scope": "all_products", "status": "unknown"}]}
    }
  ]
}
JSON
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null
  out=$(PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route pi-grok)
  case "$out" in
    *state=unknown*) : ;;
    *) fail "stale grok report with zero prepaid credits must read unknown, never exhausted: $out" ;;
  esac
  case "$out" in
    *state=exhausted*) fail "grok must never read exhausted from prepaid credits alone: $out" ;;
  esac
  pass "a stale/inconclusive grok report with zero prepaid credits reads unknown, never exhausted"
}

# ---------------------------------------------------------------------------
# Idempotent acquire/finish
# ---------------------------------------------------------------------------
test_idempotent_acquire_and_finish() {
  local home out1 out2 fin1 fin2
  home=$(make_home idempotent "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  out1=$(acquire "$home" a1 a1 g1 '["codex"]')
  out2=$(acquire "$home" a1 a1 g1 '["codex"]')
  [ "$(result_field "$out1" route_id)" = "$(result_field "$out2" route_id)" ] \
    || fail "repeated acquire for the same pending/running identity must return the same record"

  fin1=$(finish "$home" a1 success)
  fin2=$(finish "$home" a1 success)
  [ "$(result_field "$fin1" result)" = closed ] || fail "finish did not close: $fin1"
  [ "$(result_field "$fin2" result)" = closed ] || fail "repeated finish on a closed assignment must stay idempotent: $fin2"
  pass "acquire and finish are both idempotent for a repeated identity"
}

# A closed assignment record is history, never a reusable slot: acquire must
# answer already-closed with NO route_id, so a caller keying on route_id can
# never relaunch from it -- not even onto a route since proven exhausted.
test_closed_assignment_never_reauthorizes() {
  local home out
  home=$(make_home closed-contract "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  acquire "$home" a1 a1 g1 '["codex"]' >/dev/null
  finish "$home" a1 success >/dev/null

  out=$(acquire "$home" a1 a1 g2 '["codex"]')
  [ "$(result_field "$out" result)" = already-closed ] \
    || fail "a closed assignment must answer already-closed, never selected: $out"
  [ -z "$(result_field "$out" route_id)" ] \
    || fail "an already-closed answer must carry no route_id at all: $out"
  [ "$(result_field "$out" assignment_id)" = a1 ] \
    || fail "an already-closed answer must name the assignment it echoes: $out"

  # Even after the route it originally ran on is proven exhausted, the echo
  # must not hand back that route id.
  jq -c '.routes.codex.state = "exhausted"' "$home/state/route.json" > "$home/state/route.json.tmp"
  mv -f "$home/state/route.json.tmp" "$home/state/route.json"
  out=$(acquire "$home" a1 a1 g3 '["codex"]')
  [ -z "$(result_field "$out" route_id)" ] \
    || fail "a closed echo must never authorize a launch onto an exhausted route: $out"
  pass "a closed assignment answers already-closed with no route_id and never reauthorizes a launch"
}

# routes --class must narrow to exactly the pool fm-dispatch-resolve.sh would
# resolve from, so a caller never hands acquire a candidate its own class has
# no member for. Pool shape matches docs/examples/crew-dispatch.json: the
# designer class covers claude+codex while the catalog also holds pi-grok.
NARROW_CLASS_POOL='{"rules":[{"class":"designer","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}]},{"class":"builder","use":[{"harness":"pi","model":"xai/grok-4.6","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}]}],"default":[{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}]}'

test_class_scoped_routes_narrow_to_that_class_pool() {
  local home out
  home=$(make_home class-scope "$NARROW_CLASS_POOL")
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes | sort | tr '\n' ' ')
  [ "$out" = "claude codex pi-grok " ] || fail "full catalog wrong: $out"

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class designer | sort | tr '\n' ' ')
  [ "$out" = "claude codex " ] \
    || fail "designer's class-scoped routes must exclude the unrelated pi-grok: $out"

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class builder | sort | tr '\n' ' ')
  [ "$out" = "codex pi-grok " ] || fail "builder's class-scoped routes wrong: $out"

  # A class with no rule of its own falls back to the default pool, exactly
  # as fm-dispatch-resolve.sh does.
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class nosuchclass | sort | tr '\n' ' ')
  [ "$out" = "codex " ] || fail "an unmatched class must fall back to the default pool: $out"

  # Acquire scoped to that class can then only ever pick a route the class
  # actually has a member for.
  seed_routes "$home" '{
    "claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
    "codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
    "pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}
  }'
  out=$(acquire "$home" d1 d1 g1 "$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class designer | jq -R . | jq -cs .)")
  case "$(result_field "$out" route_id)" in
    claude|codex) : ;;
    *) fail "a designer acquire must never select a route outside its own pool: $out" ;;
  esac
  pass "routes --class narrows candidates to that class's own approved pool"
}

test_different_owner_reusing_assignment_id_refused() {
  local home out
  home=$(make_home owner-mismatch "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  acquire "$home" a1 owner-a g1 '["codex"]' >/dev/null
  out=$(acquire "$home" a1 owner-b g1 '["codex"]')
  [ "$(result_field "$out" result)" = error ] || fail "a different owner reusing an assignment id must be refused: $out"
  pass "a different owner reusing an existing assignment id is refused"
}

# ---------------------------------------------------------------------------
# Launch failure (finish records verified failure, excludes route immediately)
# ---------------------------------------------------------------------------
test_launch_failure_finish_excludes_route_immediately() {
  local home out
  home=$(make_home launch-fail "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  acquire "$home" a1 a1 g1 '["codex"]' >/dev/null
  finish "$home" a1 exhausted >/dev/null

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route codex)
  case "$out" in
    *state=exhausted*) : ;;
    *) fail "finish with outcome=exhausted must exclude the route immediately, without waiting for refresh: $out" ;;
  esac

  out=$(acquire "$home" a2 a2 g1 '["codex"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "the just-excluded route must not be selected for a new assignment: $out"
  pass "a launch failure's finish outcome excludes its route immediately, before any refresh runs"
}

# ---------------------------------------------------------------------------
# Abandoned-owner reconciliation (real concurrent process, not simulated)
# ---------------------------------------------------------------------------
test_abandoned_owner_does_not_block_fewest_pending() {
  local home out
  home=$(make_home abandoned "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  jq '.assignments["gone-1"] = {owner:"gone-1", ownerGeneration:"s100.1.1", status:"running", route:"codex", reason:"fewest-pending"}
    | .assignments["live-1"] = {owner:"live-1", ownerGeneration:"s200.2.2", status:"running", route:"claude", reason:"fewest-pending"}' \
    "$home/state/route.json" > "$home/state/route.json.tmp" && mv "$home/state/route.json.tmp" "$home/state/route.json"
  cat > "$home/state/live-1.meta" <<'EOF'
spawn_gen=s200.2.2
EOF
  # gone-1 has no state/gone-1.meta at all: its recorded codex assignment
  # must be reconciled away (count 0), while live-1's claude assignment
  # (matching live meta) must still count (count 1), so a new acquire prefers
  # codex.
  out=$(acquire "$home" new1 new1 g1 '["codex","claude"]')
  [ "$(result_field "$out" route_id)" = codex ] \
    || fail "an abandoned owner's assignment must not block a route from being the fewest-pending choice: $out"
  pass "an abandoned owner (no live meta) is reconciled out of the fewest-pending count, not by elapsed time"
}

test_live_owner_with_matching_generation_still_counts() {
  local home out
  home=$(make_home live-owner "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  jq '.assignments["live-2"] = {owner:"live-2", ownerGeneration:"s300.3.3", status:"running", route:"codex", reason:"fewest-pending"}' \
    "$home/state/route.json" > "$home/state/route.json.tmp" && mv "$home/state/route.json.tmp" "$home/state/route.json"
  cat > "$home/state/live-2.meta" <<'EOF'
spawn_gen=s300.3.3
EOF
  out=$(acquire "$home" new2 new2 g1 '["codex","claude"]')
  [ "$(result_field "$out" route_id)" = claude ] \
    || fail "a live owner (matching spawn_gen) must still count against its route: $out"
  pass "a live owner whose meta spawn_gen matches its assignment still counts against fewest-pending"
}

test_owner_with_mismatched_generation_is_abandoned() {
  local home out
  home=$(make_home relaunched-owner "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  jq '.assignments["relaunched-1"] = {owner:"relaunched-1", ownerGeneration:"s400.4.4", status:"running", route:"codex", reason:"fewest-pending"}' \
    "$home/state/route.json" > "$home/state/route.json.tmp" && mv "$home/state/route.json.tmp" "$home/state/route.json"
  # Live meta exists but its spawn_gen is a NEWER attempt than the one this
  # assignment recorded: the old attempt is abandoned.
  cat > "$home/state/relaunched-1.meta" <<'EOF'
spawn_gen=s999.9.9
EOF
  out=$(acquire "$home" new3 new3 g1 '["codex","claude"]')
  [ "$(result_field "$out" route_id)" = codex ] \
    || fail "an assignment whose owner meta spawn_gen no longer matches (relaunched under a new attempt) must be reconciled away: $out"
  pass "an owner relaunched under a new spawn_gen no longer counts its old assignment"
}

# ---------------------------------------------------------------------------
# Pinned researcher preserved (route admission never bypasses an existing pin)
# ---------------------------------------------------------------------------
test_pinned_researcher_route_preserved() {
  local home routes
  home=$(make_home pinned-researcher '{"rules":[{"class":"researcher","use":[{"harness":"codex","model":"gpt-6-astra","effort":"high"}],"pin":{"harness":"codex","model":"gpt-6-astra","effort":"high"}}]}')
  routes=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes)
  [ "$routes" = codex ] || fail "a single-member pinned researcher pool must derive exactly its one route: $routes"
  pass "a pinned researcher pool derives only its own approved route, never an unapproved alternative"
}

# ---------------------------------------------------------------------------
# No paid fallback: fm-route.sh never invents a route outside the config
# ---------------------------------------------------------------------------
test_unapproved_route_id_refused() {
  local home out
  home=$(make_home no-fallback "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  out=$(acquire "$home" a1 a1 g1 '["some-unapproved-paid-route"]')
  [ "$(result_field "$out" result)" = error ] || fail "an unapproved route id must be refused, never silently admitted: $out"
  pass "acquire refuses any route id outside the canonical approved catalog, with no invented paid fallback"
}

# ---------------------------------------------------------------------------
# Scheduler refresh runs with no LLM turn: refresh is a plain, bounded,
# non-interactive subcommand callable from a timer/cron/launchd context.
# ---------------------------------------------------------------------------
test_refresh_runs_standalone_with_fake_bounded_readers() {
  local home fakebin out
  home=$(make_home scheduler-refresh "$FOUR_ROUTE_POOL")
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider=claude
case "$*" in *"--provider codex"*) provider=codex ;; *"--provider grok"*) provider=grok ;; esac
scope=all_models
[ "$provider" != grok ] || scope=all_products
cat <<JSON
{"generatedAt":"2026-09-15T00:00:00.000Z","schemaVersion":3,"providers":[{"provider":"$provider","label":"$provider","source":"oauth","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"$scope","status":"known","effectivePercentRemaining":50}]},"state":{"status":"fresh","stale":false,"refreshedAt":"2026-09-15T00:00:00.000Z","sourcesTried":["oauth"]}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf '{"generatedAt":1789485834620,"reports":[],"accountsWithoutUsage":[],"disabledCredentials":[],"capacity":{}}\n'
SH
  chmod +x "$fakebin/omp"
  out=$(PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh)
  case "$out" in
    refreshed\ generation=*) : ;;
    *) fail "refresh did not run standalone with fake bounded readers: $out" ;;
  esac
  [ -f "$home/state/route.json" ] || fail "refresh did not publish state/route.json"
  pass "refresh runs standalone against fake bounded provider readers, independent of any LLM turn"
}

# ---------------------------------------------------------------------------
# Real concurrent acquisition processes (not simulated sequential calls)
# ---------------------------------------------------------------------------
test_real_concurrent_processes_split_evenly_no_lost_updates() {
  local home i pids pid n_codex n_claude
  home=$(make_home concurrent "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  pids=()
  for i in $(seq 1 20); do
    ( acquire "$home" "job-$i" "job-$i" "g$i" '["codex","claude"]' >/dev/null ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  n_codex=$(jq -r '[.assignments[] | select(.route == "codex")] | length' "$home/state/route.json")
  n_claude=$(jq -r '[.assignments[] | select(.route == "claude")] | length' "$home/state/route.json")
  [ "$((n_codex + n_claude))" -eq 20 ] || fail "expected 20 total assignments with no lost updates, got codex=$n_codex claude=$n_claude"
  [ "$n_codex" -ge 8 ] && [ "$n_claude" -ge 8 ] \
    || fail "expected a roughly even split across 20 real concurrent processes, got codex=$n_codex claude=$n_claude"
  pass "20 real concurrent acquire processes split across eligible routes with no lost updates"
}

test_all_four_routes_derived_and_assignable
test_exhaustion_outage_auth_failure_exclude
test_unknown_never_selected_never_proven_unavailable
test_verified_recovery_reenables_after_deferral
test_manual_disable_wins_and_survives
test_zero_prepaid_grok_credits_not_exhaustion
test_zero_prepaid_grok_credits_alone_is_unknown_not_exhausted
test_idempotent_acquire_and_finish
test_closed_assignment_never_reauthorizes
test_class_scoped_routes_narrow_to_that_class_pool
test_different_owner_reusing_assignment_id_refused
test_launch_failure_finish_excludes_route_immediately
test_abandoned_owner_does_not_block_fewest_pending
test_live_owner_with_matching_generation_still_counts
test_owner_with_mismatched_generation_is_abandoned
test_pinned_researcher_route_preserved
test_unapproved_route_id_refused
test_refresh_runs_standalone_with_fake_bounded_readers
test_real_concurrent_processes_split_evenly_no_lost_updates

echo "# all fm-route tests passed"
