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

release() {  # <home> <assignment> <owner>
  local home=$1 assignment=$2 owner=$3
  jq -cn --arg a "$assignment" --arg owner "$owner" \
    '{assignment_id:$a, owner:{identity:$owner}}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" release
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
# No-probe routes (captain's word, 2026-09-16): eligible until a launch or
# worker failure proves them unavailable, never unknown.
# ---------------------------------------------------------------------------
NO_PROBE_POOL='{"rules":[{"class":"builder","use":[{"harness":"omp","model":"glm-5.3-flash","effort":"high"},{"harness":"pi","model":"kimi-k3","effort":"high"}]}]}'

test_refresh_marks_no_probe_route_eligible_with_reason() {
  local home fakebin out
  home=$(make_home no-probe-refresh "$NO_PROBE_POOL")
  fakebin=$(fm_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh)
  case "$out" in
    refreshed\ generation=*) : ;;
    *) fail "refresh did not run for the no-probe pool: $out" ;;
  esac
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route omp)
  case "$out" in
    *state=eligible*"no probe for route omp; eligible until a launch or worker failure proves otherwise"*) : ;;
    *) fail "a route with no probe source must record eligible with the no-probe reason, not unknown: $out" ;;
  esac
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route pi)
  case "$out" in
    *state=eligible*"no probe for route pi; eligible until a launch or worker failure proves otherwise"*) : ;;
    *) fail "a route with no probe source must record eligible with the no-probe reason, not unknown: $out" ;;
  esac
  pass "refresh marks a no-probe route eligible with the no-probe reason"
}

test_acquire_selects_a_no_probe_route() {
  local home out
  home=$(make_home no-probe-acquire "$NO_PROBE_POOL")
  seed_routes "$home" '{
    "omp":{"state":"eligible","reason":"no probe for route omp; eligible until a launch or worker failure proves otherwise","observedAt":"t","manualDisabled":false},
    "pi":{"state":"eligible","reason":"no probe for route pi; eligible until a launch or worker failure proves otherwise","observedAt":"t","manualDisabled":false}
  }'
  out=$(acquire "$home" a1 a1 g1 '["omp","pi"]')
  [ "$(result_field "$out" result)" = selected ] || fail "acquire must select a no-probe route recorded eligible: $out"
  pass "acquire selects a no-probe route once refresh has recorded it eligible"
}

test_no_probe_route_verified_failure_excludes_then_recovers() {
  local home out
  home=$(make_home no-probe-failure "$NO_PROBE_POOL")
  seed_routes "$home" '{
    "omp":{"state":"eligible","reason":"no probe for route omp; eligible until a launch or worker failure proves otherwise","observedAt":"t","manualDisabled":false}
  }'
  out=$(acquire "$home" a1 a1 g1 '["omp"]')
  [ "$(result_field "$out" result)" = selected ] || fail "expected initial selection of the no-probe route: $out"
  finish "$home" a1 launch-failed >/dev/null

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route omp)
  case "$out" in
    *state=launch-failed*) : ;;
    *) fail "a verified launch failure must exclude the no-probe route immediately: $out" ;;
  esac
  out=$(acquire "$home" a2 a2 g1 '["omp"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "the just-excluded no-probe route must not be selected for a new assignment: $out"

  # A real refresh must NOT silently clear the verified failure with its own
  # synthetic eligible reading: only a later verified success does.
  FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route omp)
  case "$out" in
    *state=launch-failed*) : ;;
    *) fail "refresh must preserve a no-probe route's verified failure, not overwrite it with a synthetic eligible reading: $out" ;;
  esac
  out=$(acquire "$home" a2 a2 g1 '["omp"]')
  [ "$(result_field "$out" result)" = deferred ] || fail "the excluded no-probe route must still defer after a refresh alone: $out"

  # finish's success path only clears a prior failure for an assignment that
  # actually holds the excluded route (route:null on a deferred record
  # carries no route to clear), so seed a running record directly the same
  # way test_abandoned_owner_does_not_block_fewest_pending does.
  jq '.assignments["a3"] = {owner:"a3", ownerGeneration:"g1", status:"running", route:"omp", reason:"fewest-pending"}' \
    "$home/state/route.json" > "$home/state/route.json.tmp" && mv "$home/state/route.json.tmp" "$home/state/route.json"
  finish "$home" a3 success >/dev/null
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route omp)
  case "$out" in
    *state=eligible*) : ;;
    *) fail "a verified success finish should clear the no-probe route's prior failure: $out" ;;
  esac
  out=$(acquire "$home" a4 a4 g1 '["omp"]')
  [ "$(result_field "$out" result)" = selected ] || fail "a later verified-success finish should re-admit the no-probe route: $out"
  pass "a verified failure excludes a no-probe route until a later verified success re-admits it"
}

test_route_with_erroring_probe_still_records_unknown() {
  local home fakebin out
  home=$(make_home probe-error "$FOUR_ROUTE_POOL")
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/omp"
  # claude and codex now read a pool reader before quota-axi, so shadow any
  # real proxy on PATH with an unreadable stub: the pool falls back to the
  # erroring quota-axi above, and the route still has to record unknown.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/teamclaude"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/teamcodex"
  chmod +x "$fakebin/teamclaude" "$fakebin/teamcodex"
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null \
    || fail "refresh failed against an erroring probe"
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route claude)
  case "$out" in
    *state=unknown*) : ;;
    *) fail "a route with a real probe that errors must still record unknown, not eligible: $out" ;;
  esac
  pass "a route with a probe source that errors still records unknown, never eligible"
}

# ---------------------------------------------------------------------------
# Pooled route admission (claude and codex): both services sit behind a local
# proxy pool holding several accounts, so one blocked account must never
# speak for the whole pool. Admission is eligible when ANY account is usable
# (disabled false, unavailable absent or "none") and exhausted only when
# every account is blocked. A pool command that is missing, fails, returns
# unparseable JSON, reports zero accounts, or carries no usable probe
# timestamp falls back to the existing quota-axi reader and says so, so a
# broken pool is never worse than the pre-pool behavior.
# ---------------------------------------------------------------------------
POOLED_ONLY_POOL='{"rules":[{"class":"builder","use":[{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"claude","model":"opus","effort":"high"}]}]}'

fake_pool_reader() {  # <fakebin> <name> <json-body>
  local fakebin=$1 name=$2 body=$3
  {
    printf '#!/usr/bin/env bash\n'
    printf "cat <<'POOLJSON'\n"
    printf '%s\n' "$body"
    printf 'POOLJSON\n'
  } > "$fakebin/$name"
  chmod +x "$fakebin/$name"
}

fake_pool_reader_fails() {  # <fakebin> <name> <exit-code>
  local fakebin=$1 name=$2 rc=$3
  printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$fakebin/$name"
  chmod +x "$fakebin/$name"
}

# A fake quota-axi that reports the requested provider eligible at 50%, so a
# fallback is observable and distinguishable from the pool reading.
fake_quota_axi_eligible() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider=claude
case "$*" in *"--provider codex"*) provider=codex ;; *"--provider grok"*) provider=grok ;; esac
scope=all_models
[ "$provider" != grok ] || scope=all_products
cat <<JSON
{"schemaVersion":3,"providers":[{"provider":"$provider","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"$scope","status":"known","effectivePercentRemaining":50}]},"state":{"status":"fresh","stale":false,"refreshedAt":"2026-09-15T00:00:00.000Z"}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
}

pool_refresh() {  # <home> <fakebin>
  PATH="$2:$PATH" FM_ROUTE_HOME_OVERRIDE="$1" "$ROUTE" refresh >/dev/null
}

test_pooled_codex_admits_on_one_usable_account_of_five() {
  local home fakebin out expected
  home=$(make_home pooled-codex-any "$POOLED_ONLY_POOL")
  fakebin=$(fm_fakebin "$home")
  fake_pool_reader "$fakebin" teamcodex '{
    "probe":{"lastRunFinishedAt":1789742664900},
    "accounts":[
      {"disabled":false,"unavailable":"quota"},
      {"disabled":true,"unavailable":"disabled"},
      {"disabled":false,"unavailable":"quota"},
      {"disabled":false,"unavailable":"quota"},
      {"disabled":false,"unavailable":"none"}]}'
  fake_pool_reader_fails "$fakebin" teamclaude 1
  fake_quota_axi_eligible "$fakebin"
  pool_refresh "$home" "$fakebin"
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route codex)
  case "$out" in
    *state=eligible*"teamcodex pool: 1 of 5 accounts usable"*) : ;;
    *) fail "one usable account of five must admit the pooled route: $out" ;;
  esac
  expected=$(date -u -r "$((1789742664900 / 1000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$((1789742664900 / 1000))" +%Y-%m-%dT%H:%M:%SZ)
  case "$out" in
    *"observed_at=$expected"*) : ;;
    *) fail "a pooled probe's observed_at must come from the pool's own timestamp ($expected): $out" ;;
  esac
  pass "one usable account of five admits codex, with the usable count and the pool's own timestamp"
}

test_pooled_codex_all_accounts_blocked_is_exhausted() {
  local home fakebin out
  home=$(make_home pooled-codex-none "$POOLED_ONLY_POOL")
  fakebin=$(fm_fakebin "$home")
  fake_pool_reader "$fakebin" teamcodex '{
    "probe":{"lastRunFinishedAt":1789742664900},
    "accounts":[
      {"disabled":false,"unavailable":"quota"},
      {"disabled":true},
      {"disabled":false,"unavailable":"quota"},
      {"disabled":false,"unavailable":"quota"},
      {"disabled":false,"unavailable":"quota"}]}'
  fake_pool_reader_fails "$fakebin" teamclaude 1
  fake_quota_axi_eligible "$fakebin"
  pool_refresh "$home" "$fakebin"
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route codex)
  case "$out" in
    *state=exhausted*"teamcodex pool: 0 of 5 accounts usable"*) : ;;
    *) fail "every account blocked must read exhausted with a zero count: $out" ;;
  esac
  pass "a pool with every account blocked reads exhausted with a zero usable count"
}

test_pooled_claude_reads_the_probe_accounts_location() {
  local home fakebin out
  home=$(make_home pooled-claude-probe-loc "$POOLED_ONLY_POOL")
  fakebin=$(fm_fakebin "$home")
  # teamclaude's shape in the wild can carry the account list at
  # .probe.accounts rather than .accounts; both must be accepted.
  fake_pool_reader "$fakebin" teamclaude '{
    "probe":{"lastRunFinishedAt":1789742665000,"accounts":[
      {"disabled":false,"unavailable":"none"},
      {"disabled":false,"unavailable":"error"},
      {"disabled":true,"unavailable":"disabled"}]}}'
  fake_pool_reader_fails "$fakebin" teamcodex 1
  fake_quota_axi_eligible "$fakebin"
  pool_refresh "$home" "$fakebin"
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route claude)
  case "$out" in
    *state=eligible*"teamclaude pool: 1 of 3 accounts usable"*) : ;;
    *) fail "the .probe.accounts location must be read the same as .accounts: $out" ;;
  esac
  pass "a claude pool whose accounts live at .probe.accounts is admitted on its one usable account"
}

test_pooled_missing_command_falls_back_to_quota_axi_and_says_so() {
  local home fakebin out
  home=$(make_home pooled-missing "$POOLED_ONLY_POOL")
  fakebin=$(fm_fakebin "$home")
  fake_quota_axi_eligible "$fakebin"
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" \
    FM_ROUTE_TEAMCODEX_BIN="fm-no-such-teamcodex" FM_ROUTE_TEAMCLAUDE_BIN="fm-no-such-teamclaude" \
    "$ROUTE" refresh >/dev/null
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route codex)
  case "$out" in
    *state=eligible*"teamcodex unreadable"*"fell back to quota-axi"*"codex effective remaining 50%"*) : ;;
    *) fail "a missing pool command must fall back to quota-axi and name the fallback: $out" ;;
  esac
  pass "a missing pool command falls back to quota-axi and reports the fallback in the reason"
}

test_pooled_reader_failures_fall_back_to_quota_axi() {
  local home fakebin out label kind

  while IFS=$'\t' read -r label kind; do
    [ -n "$label" ] || continue
    home=$(make_home "pooled-fallback-$kind" "$POOLED_ONLY_POOL")
    fakebin=$(fm_fakebin "$home")
    fake_quota_axi_eligible "$fakebin"
    fake_pool_reader_fails "$fakebin" teamclaude 1
    case "$kind" in
      nonzero) fake_pool_reader_fails "$fakebin" teamcodex 3 ;;
      malformed) fake_pool_reader "$fakebin" teamcodex 'this is not json' ;;
      zero) fake_pool_reader "$fakebin" teamcodex '{"probe":{"lastRunFinishedAt":1789742664900},"accounts":[]}' ;;
      nots) fake_pool_reader "$fakebin" teamcodex '{"accounts":[{"disabled":false,"unavailable":"none"}]}' ;;
    esac
    pool_refresh "$home" "$fakebin"
    out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route codex)
    case "$out" in
      *state=eligible*"teamcodex $label"*"fell back to quota-axi"*"codex effective remaining 50%"*) : ;;
      *) fail "a pool that $label must fall back to quota-axi and say so: $out" ;;
    esac
  done <<'EOF'
unreadable (exit 3)	nonzero
returned unparseable JSON	malformed
reported no accounts	zero
reported no usable probe timestamp	nots
EOF

  pass "a non-zero exit, unparseable JSON, zero accounts, or missing timestamp all fall back to quota-axi"
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

# release is the pre-launch give-back: it deletes an open record outright -
# no outcome, no route exclusion - so the freed id's next acquire is a fresh
# attempt. closed history and foreign owners are out of its reach, and a
# second release of the same id is an idempotent no-op.
test_release_deletes_a_running_record_and_leaves_routes_untouched() {
  local home out routes_before routes_after next
  home=$(make_home release-running "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  acquire "$home" a1 a1 g1 '["codex"]' >/dev/null
  routes_before=$(jq -c '.routes' "$home/state/route.json")

  out=$(release "$home" a1 a1)
  [ "$(result_field "$out" result)" = released ] || fail "release did not release a running record: $out"
  [ "$(jq --arg a a1 '.assignments | has($a)' "$home/state/route.json")" = false ] \
    || fail "release did not delete the running record: $(cat "$home/state/route.json")"
  routes_after=$(jq -c '.routes' "$home/state/route.json")
  [ "$routes_before" = "$routes_after" ] \
    || fail "release touched route state: $routes_before -> $routes_after"

  out=$(release "$home" a1 a1)
  [ "$(result_field "$out" result)" = released ] \
    || fail "a second release of the same id must stay idempotent: $out"

  next=$(acquire "$home" a1 a1 g2 '["codex"]')
  [ "$(result_field "$next" result)" = selected ] \
    || fail "a released id's next acquire must be a fresh attempt, never already-closed: $next"
  pass "release deletes a running record, leaves routes untouched, and frees the id"
}

test_release_refuses_a_foreign_owner() {
  local home out status
  home=$(make_home release-foreign "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  acquire "$home" a1 a1 g1 '["codex"]' >/dev/null

  out=$(release "$home" a1 someone-else 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "release by a foreign owner must be refused: $out"
  [ "$(result_field "$out" result)" = error ] || fail "foreign release did not answer error: $out"
  [ "$(result_field "$out" error)" != "" ] || fail "foreign release gave no reason: $out"
  [ "$(jq --arg a a1 '.assignments | has($a)' "$home/state/route.json")" = true ] \
    || fail "a refused release must leave the record untouched: $(cat "$home/state/route.json")"
  pass "release refuses a foreign owner and leaves the record untouched"
}

test_release_never_deletes_closed_history() {
  local home out
  home=$(make_home release-closed "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  acquire "$home" a1 a1 g1 '["codex"]' >/dev/null
  finish "$home" a1 success >/dev/null

  out=$(release "$home" a1 a1)
  [ "$(result_field "$out" result)" = already-closed ] \
    || fail "release of a closed record must answer already-closed: $out"
  [ "$(jq -r '.assignments.a1.status' "$home/state/route.json")" = closed ] \
    || fail "release must never delete closed history: $(cat "$home/state/route.json")"

  out=$(release "$home" never-existed a1)
  [ "$(result_field "$out" result)" = released ] \
    || fail "release of a missing id must be an idempotent no-op: $out"
  [ "$(jq '.assignments | length' "$home/state/route.json")" = 1 ] \
    || fail "a missing-id release must write nothing: $(cat "$home/state/route.json")"
  pass "release never deletes closed history and is a no-op for a missing id"
}

test_release_refuses_malformed_requests_before_any_write() {
  local home out status before after
  home=$(make_home release-malformed "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  before=$(cat "$home/state/route.json")

  out=$(jq -cn '{assignment_id:null, owner:{identity:"a1"}}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" release 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a release with a null assignment_id must be refused: $out"
  [ "$(result_field "$out" result)" = error ] || fail "malformed release did not answer error: $out"

  out=$(jq -cn '{assignment_id:"a1"}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" release 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a release with no owner must be refused: $out"

  after=$(cat "$home/state/route.json")
  [ "$before" = "$after" ] || fail "malformed releases must never write: $before -> $after"
  pass "release refuses malformed requests before writing anything"
}

# state/route.json is this store's own persisted document. A corrupt one
# must never be silently replaced: every command feeds what it read straight
# back into jq and writes the result, so accepting corrupt bytes publishes a
# destroyed store over a real one and wipes every live assignment record.
# Each case asserts the file's bytes are byte-for-byte unchanged afterwards.
corrupt_store_refuses() {  # <label> <home> <raw-route-json-bytes>
  local label=$1 home=$2 body=$3 before after out status

  printf '%s' "$body" > "$home/state/route.json"
  before=$(cksum < "$home/state/route.json")

  out=$(acquire "$home" A1 w1 r1.1.1 '["claude"]' 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "$label: acquire must refuse a corrupt store, got exit 0"
  case "$out" in
    *"corrupt or unparseable"*) ;;
    *) fail "$label: acquire did not name the corruption, got: [$out]" ;;
  esac
  [ "$(jq -r '.result' <<<"$out" 2>/dev/null)" = error ] \
    || fail "$label: acquire's refusal is not a JSON error object: [$out]"

  status=
  out=$(printf '%s' '{"assignment_id":"A1","outcome":"exhausted"}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" finish 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "$label: finish must refuse a corrupt store, got exit 0"
  case "$out" in
    *"corrupt or unparseable"*) ;;
    *) fail "$label: finish reported success and dropped the exclusion: [$out]" ;;
  esac

  status=
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "$label: status must refuse a corrupt store, got exit 0"

  status=
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "$label: refresh must refuse a corrupt store, got exit 0"

  after=$(cksum < "$home/state/route.json")
  [ "$before" = "$after" ] \
    || fail "$label: a refused call changed the store ($before -> $after)"
}

test_corrupt_store_is_refused_and_left_intact() {
  local home

  home=$(make_home corrupt-truncated "$FOUR_ROUTE_POOL")
  corrupt_store_refuses truncated "$home" \
    '{"generation":9,"tieCursor":3,"routes":{"claude":{"state":"eligi'

  home=$(make_home corrupt-shape "$FOUR_ROUTE_POOL")
  corrupt_store_refuses wrong-shape "$home" '{"generation":9,"hello":"world"}'

  home=$(make_home corrupt-empty "$FOUR_ROUTE_POOL")
  corrupt_store_refuses empty-file "$home" ''

  pass "a corrupt route store is refused loudly by every reader and never overwritten"
}

# The read check must test value TYPES, not just key presence. A document whose
# keys are all there but wrongly typed passes a presence-only check, then the
# acquire-side jq fails on it and the empty result gets published over the real
# store while acquire still answers "selected".
test_wrongly_typed_store_is_refused_and_left_intact() {
  local home before after out status

  home=$(make_home wrong-typed-store "$FOUR_ROUTE_POOL")
  printf '%s' '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":[]}' \
    > "$home/state/route.json"
  before=$(cksum < "$home/state/route.json")

  out=$(acquire "$home" A1 w1 r1.1.1 '["codex"]' 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "acquire must refuse a wrongly-typed store, got exit 0: $out"
  [ "$(result_field "$out" result)" = error ] \
    || fail "acquire answered something other than an error for a wrongly-typed store: $out"
  case "$out" in
    *"corrupt or unparseable"*) ;;
    *) fail "the refusal did not name the corruption: $out" ;;
  esac

  after=$(cksum < "$home/state/route.json")
  [ "$before" = "$after" ] \
    || fail "a refused acquire changed the store ($before -> $after)"

  # The same applies to a wrongly-typed routes value.
  printf '%s' '{"generation":1,"routes":[],"assignments":{}}' > "$home/state/route.json"
  before=$(cksum < "$home/state/route.json")
  status=
  out=$(acquire "$home" A2 w2 r2.2.2 '["codex"]' 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "acquire must refuse a wrongly-typed routes value, got exit 0: $out"
  after=$(cksum < "$home/state/route.json")
  [ "$before" = "$after" ] || fail "a refused acquire changed the store with a bad routes value"

  pass "a store whose keys are present but wrongly typed is refused, never overwritten"
}

# ---------------------------------------------------------------------------
# A store whose top-level shape passes but whose MEMBER values are wrongly
# typed is corruption too: every reader must refuse it clearly rather than
# indexing a scalar and turning the resulting empty value into a route
# decision.
# ---------------------------------------------------------------------------
test_wrongly_typed_store_member_values_are_refused_by_every_reader() {
  local home before after out status desc doc

  home=$(make_home wrong-typed-member "$FOUR_ROUTE_POOL")

  while IFS=$'\t' read -r desc doc; do
    [ -n "$desc" ] || continue
    printf '%s' "$doc" > "$home/state/route.json"
    before=$(cksum < "$home/state/route.json")

    status=
    out=$(acquire "$home" M1 w1 r1.1.1 '["codex"]' 2>&1) || status=$?
    status=${status:-0}
    [ "$status" -ne 0 ] \
      || fail "acquire must refuse $desc, got exit 0: $out"
    [ "$(result_field "$out" result)" = error ] \
      || fail "acquire answered something other than an error for $desc: $out"
    case "$out" in
      *"corrupt or unparseable"*) ;;
      *) fail "acquire's refusal of $desc did not name the corruption: $out" ;;
    esac

    status=
    out=$(finish "$home" M1 success 2>&1) || status=$?
    status=${status:-0}
    [ "$status" -ne 0 ] \
      || fail "finish must refuse $desc, got exit 0: $out"
    [ "$(result_field "$out" result)" = error ] \
      || fail "finish answered something other than an error for $desc: $out"

    status=
    out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status 2>&1) || status=$?
    status=${status:-0}
    [ "$status" -ne 0 ] || fail "status must refuse $desc, got exit 0: $out"
    case "$out" in
      *"corrupt or unparseable"*) ;;
      *) fail "status's refusal of $desc did not name the corruption: $out" ;;
    esac

    status=
    out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh 2>&1) || status=$?
    status=${status:-0}
    [ "$status" -ne 0 ] || fail "refresh must refuse $desc, got exit 0: $out"
    case "$out" in
      *"corrupt or unparseable"*) ;;
      *) fail "refresh's refusal of $desc did not name the corruption: $out" ;;
    esac

    after=$(cksum < "$home/state/route.json")
    [ "$before" = "$after" ] \
      || fail "a refused reader rewrote the store for $desc ($before -> $after)"
  done <<EOF
a scalar routes member	{"generation":1,"routes":{"codex":"garbage"},"assignments":{}}
a null routes member	{"generation":1,"routes":{"codex":null},"assignments":{}}
an array routes member	{"generation":1,"routes":{"codex":["eligible"]},"assignments":{}}
a scalar assignments member	{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{"M1":42}}
EOF

  # A healthy store with both maps populated, and a fresh store with both
  # empty, must still be accepted: the tightened guard rejects wrong member
  # types only, never a legitimate document.
  seed_routes "$home" '{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  out=$(acquire "$home" M2 w2 r2.2.2 '["codex"]')
  [ "$(result_field "$out" result)" = selected ] \
    || fail "a healthy store must still be accepted after the member-type guard: $out"
  out=$(finish "$home" M2 success)
  [ "$(result_field "$out" result)" = closed ] \
    || fail "finish must still close a healthy store's assignment: $out"

  pass "a store with a wrongly-typed value inside routes or assignments is refused by acquire, finish, status and refresh"
}

# defaultPin is a top-level config key, so its route must reach the catalog
# even when no rule and no default array mentions that route.
test_top_level_default_pin_contributes_its_route() {
  local home out
  home=$(make_home top-level-default-pin \
    '{"rules":[{"class":"builder","use":[{"harness":"codex","model":"gpt-5","effort":"high"}]}],
      "defaultPin":{"harness":"claude","model":"opus","effort":"high"}}')

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes | sort | tr '\n' ' ')
  [ "$out" = "claude codex " ] \
    || fail "a top-level defaultPin's route must appear in the derived catalog, got: [$out]"

  # A route only the defaultPin names must also pass the known-route check.
  out=$(acquire "$home" A1 w1 r1.1.1 '["claude"]' 2>&1)
  [ "$(result_field "$out" result)" != error ] \
    || fail "a defaultPin-only route was refused as unknown: $out"

  pass "a top-level defaultPin contributes its route id to the catalog"
}

# A store the commands did write must still be readable by all of them, so
# the new validation cannot be satisfied by refusing everything.
test_healthy_store_still_serves_every_reader() {
  local home out
  home=$(make_home corrupt-control "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'

  out=$(acquire "$home" A1 w1 r1.1.1 '["claude"]')
  [ "$(jq -r '.result' <<<"$out")" = selected ] || fail "healthy acquire did not select: $out"
  FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status >/dev/null \
    || fail "status refused a healthy store"
  out=$(printf '%s' '{"assignment_id":"A1","outcome":"exhausted"}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" finish)
  [ "$(jq -r '.result' <<<"$out")" = closed ] || fail "healthy finish did not close: $out"
  [ "$(jq -r '.routes.claude.state' "$home/state/route.json")" = exhausted ] \
    || fail "healthy finish did not record the immediate exclusion"
  pass "a healthy store is still served, and finish still records immediate exclusion"
}

# routes --class must narrow to exactly the routes a class can actually
# RESOLVE to, not merely the ones its pool mentions. These pools are the real
# shapes from this repo's own docs/examples/crew-dispatch.json, the ones that
# reproduced live failures: builder carries an enabled pin inside a
# three-route pool, tester carries a disabled pi-grok member, designer is a
# plain two-route pool, and researcher spans all three unpinned.
EXAMPLE_SHAPED_POOL='{"rules":[
  {"class":"researcher","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}]},
  {"class":"builder","use":[{"harness":"pi","model":"xai/grok-4.6","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"high"},{"harness":"claude","model":"claude-opus-4-8","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}},
  {"class":"designer","use":[{"harness":"claude","model":"fable","effort":"xhigh"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}]},
  {"class":"tester","use":[{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"},{"harness":"pi","model":"xai/grok-4.6","effort":"high","enabled":false}]}
],"default":[{"harness":"codex","model":"gpt-5.6-sol","effort":"high"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}],"defaultPin":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}'

ALL_THREE_ELIGIBLE='{
  "claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
  "codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
  "pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}
}'

# `routes --class` delegates to bin/fm-dispatch-resolve.sh, whose own
# model_exhausted filter reads quota-axi for claude and codex members. Without
# a stub that reaches the REAL quota-axi, so a model the captain's account has
# genuinely spent (measured 2026-09-22: model:fable at 0% remaining) drops its
# route and the expected pool silently shrinks. These cases are about
# class-pool scoping, not live quota, so they pin a healthy reading.
CLASS_ROUTES_FAKEBIN=
class_routes_fakebin() {
  [ -z "$CLASS_ROUTES_FAKEBIN" ] || return 0
  CLASS_ROUTES_FAKEBIN=$(fm_fakebin "$TMP_ROOT/class-routes-quota")
  fake_quota_axi_eligible "$CLASS_ROUTES_FAKEBIN"
}

class_routes() {  # <home> <class>
  class_routes_fakebin
  PATH="$CLASS_ROUTES_FAKEBIN:$PATH" FM_ROUTE_HOME_OVERRIDE="$1" \
    "$ROUTE" routes --class "$2" | sort | tr '\n' ' '
}

test_class_scoped_routes_narrow_to_that_class_pool() {
  local home out
  home=$(make_home class-scope "$EXAMPLE_SHAPED_POOL")
  class_routes_fakebin
  out=$(PATH="$CLASS_ROUTES_FAKEBIN:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" \
    "$ROUTE" routes | sort | tr '\n' ' ')
  [ "$out" = "claude codex pi-grok " ] || fail "full catalog wrong: $out"

  out=$(class_routes "$home" designer)
  [ "$out" = "claude codex " ] \
    || fail "designer's class-scoped routes must exclude the unrelated pi-grok: $out"

  out=$(class_routes "$home" researcher)
  [ "$out" = "claude codex pi-grok " ] \
    || fail "an unpinned all-enabled pool must still offer every route: $out"

  # An unmatched class falls back to the default pool, which is pinned to
  # codex, so it offers exactly codex.
  out=$(class_routes "$home" nosuchclass)
  [ "$out" = "codex " ] \
    || fail "an unmatched class must fall back to the default pool's pin: $out"
  pass "routes --class narrows candidates to that class's own approved pool"
}

# A resolver that cannot answer at all must say why. An empty list with a
# zero exit is a legitimate "no candidates"; a failure has to reach the
# operator with the resolver's own reason attached, not vanish into an empty
# stream that looks identical to success.
DUPLICATE_CLASS_POOL='{"rules":[
  {"class":"builder","use":[{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}]},
  {"class":"builder","use":[{"harness":"claude","model":"opus","effort":"high"}]}
],"default":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}'

test_failed_candidate_lookup_reports_the_resolver_reason() {
  local home out status
  home=$(make_home candidate-lookup-failure "$DUPLICATE_CLASS_POOL")
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class builder 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "a config the resolver rejects must not exit 0"
  case "$out" in
    *"could not determine candidate routes for class builder"*) ;;
    *) fail "the failure was not reported at all, got: [$out]" ;;
  esac
  case "$out" in
    *"dispatch class must be unique"*) ;;
    *) fail "the resolver's own reason never reached the operator, got: [$out]" ;;
  esac
  pass "a failing candidate lookup reports the resolver's own reason, never an empty stream"
}

# A pinned pool always resolves to its pin's exact tuple, so offering any
# other route can only make the rotation break the pin. Candidates must be
# exactly the pinned route, every single call, no matter how far the tie
# cursor has advanced.
test_pinned_class_offers_only_its_pinned_route() {
  local home out i picked
  home=$(make_home pinned-class "$EXAMPLE_SHAPED_POOL")
  out=$(class_routes "$home" builder)
  [ "$out" = "codex " ] \
    || fail "a pinned class must offer exactly its pinned route, got: $out"

  seed_routes "$home" "$ALL_THREE_ELIGIBLE"
  # Advance the tie cursor well past every catalog route: a pinned class must
  # land on codex every time, never rotate onto claude or pi-grok.
  for i in 1 2 3 4 5 6; do
    picked=$(result_field "$(acquire "$home" "b$i" "b$i" g1 \
      "$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class builder | jq -R . | jq -cs .)")" route_id)
    [ "$picked" = codex ] \
      || fail "acquire #$i for a codex-pinned builder selected '$picked', which breaks the pin"
  done
  pass "a pinned class offers only its pinned route, across every tie-cursor rotation"
}

# A route whose only member in this class's pool is switched off can never be
# resolved to, so offering it as a candidate could only zero the real pool.
test_disabled_only_route_is_never_offered_as_a_candidate() {
  local home out i picked
  home=$(make_home disabled-member "$EXAMPLE_SHAPED_POOL")
  out=$(class_routes "$home" tester)
  [ "$out" = "claude codex " ] \
    || fail "tester's disabled-only pi-grok member must never be offered: $out"

  seed_routes "$home" "$ALL_THREE_ELIGIBLE"
  for i in 1 2 3 4 5 6; do
    picked=$(result_field "$(acquire "$home" "t$i" "t$i" g1 \
      "$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes --class tester | jq -R . | jq -cs .)")" route_id)
    case "$picked" in
      claude|codex) : ;;
      *) fail "acquire #$i for tester selected '$picked', whose only pool member is switched off" ;;
    esac
  done
  pass "a route whose only class-pool member is disabled is never offered as a candidate"
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
  # assignment recorded: the old attempt is abandoned. This half of
  # reconciliation applies only to a caller passing a spawn_gen-shaped
  # owner.generation, which is why the seeded record uses that shape; see
  # fm_route_owner_abandoned's own scope-limit note.
  cat > "$home/state/relaunched-1.meta" <<'EOF'
spawn_gen=s999.9.9
EOF
  out=$(acquire "$home" new3 new3 g1 '["codex","claude"]')
  [ "$(result_field "$out" route_id)" = codex ] \
    || fail "an assignment whose owner meta spawn_gen no longer matches (relaunched under a new attempt) must be reconciled away: $out"
  pass "a spawn_gen-shaped owner generation that no longer matches its meta is reconciled away"
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
# Malformed request shapes are refused at the boundary, never mislabelled as
# proven provider unavailability, and never written to the store.
# ---------------------------------------------------------------------------
test_malformed_request_shapes_are_refused_before_any_write() {
  local home before after out desc req
  home=$(make_home malformed-request "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{
    "codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},
    "claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}}'
  before=$(cat "$home/state/route.json")

  while IFS=$'\t' read -r desc req; do
    [ -n "$desc" ] || continue
    out=$(printf '%s' "$req" | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" acquire) || true
    [ "$(result_field "$out" result)" = error ] \
      || fail "acquire must refuse $desc with result=error, never deferred or selected: $out"
    [ -n "$(result_field "$out" error)" ] \
      || fail "acquire's refusal of $desc must carry an explanatory error message: $out"
    after=$(cat "$home/state/route.json")
    [ "$after" = "$before" ] \
      || fail "acquire must not write the store when refusing $desc"
  done <<EOF
routes as a JSON string	{"assignment_id":"m1","owner":{"identity":"o1","generation":"g1"},"routes":"codex"}
routes as a JSON object	{"assignment_id":"m2","owner":{"identity":"o1","generation":"g1"},"routes":{"a":"codex"}}
routes holding a non-string id	{"assignment_id":"m3","owner":{"identity":"o1","generation":"g1"},"routes":[7]}
routes as a number	{"assignment_id":"m4","owner":{"identity":"o1","generation":"g1"},"routes":3}
an object assignment_id	{"assignment_id":{"a":1},"owner":{"identity":"o1","generation":"g1"},"routes":["codex"]}
an array owner.identity	{"assignment_id":"m5","owner":{"identity":["o1"],"generation":"g1"},"routes":["codex"]}
an object owner.generation	{"assignment_id":"m6","owner":{"identity":"o1","generation":{"g":1}},"routes":["codex"]}
EOF

  out=$(printf '%s' '{"assignment_id":{"a":1},"outcome":"success"}' \
    | FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" finish) || true
  [ "$(result_field "$out" result)" = error ] \
    || fail "finish must refuse a non-string assignment_id with result=error, never report it closed: $out"
  [ "$(cat "$home/state/route.json")" = "$before" ] \
    || fail "finish must not write the store when refusing a malformed assignment_id"

  out=$(acquire "$home" ok1 o1 g1 '["codex","claude"]')
  [ "$(result_field "$out" result)" = selected ] \
    || fail "a well-formed acquire must still succeed after malformed requests were refused: $out"
  pass "malformed acquire/finish request shapes are refused with result=error and leave the store untouched"
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

# A failure status anywhere in omp's reports is proven unavailability. The
# probe must not depend on where that entry sits in the array: the same
# evidence has to produce the same verdict whichever limit carries it.
DEEPSEEK_ONLY_POOL='{"rules":[{"class":"builder","use":[{"harness":"omp","model":"vercel-ai-gateway/deepseek/deepseek-v4.1-flash","effort":"xhigh"}]}]}'

deepseek_state_for_payload() {  # <home-name> <omp-json>
  local home fakebin
  home=$(make_home "$1" "$DEEPSEEK_ONLY_POOL")
  fakebin=$(fm_fakebin "$home")
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$(printf '%q' "$2")" > "$fakebin/omp"
  chmod +x "$fakebin/omp"
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null \
    || fail "refresh failed for $1"
  jq -r '.routes["pi-deepseek"].state' "$home/state/route.json"
}

test_any_failed_limit_marks_deepseek_outage_regardless_of_position() {
  local first_bad later_bad state

  first_bad='{"generatedAt":1789485834620,"reports":[{"limits":[
    {"status":"error","amount":{"remainingFraction":0.9,"remaining":90,"unit":"usd"}},
    {"status":"ok","amount":{"remainingFraction":0.5,"remaining":50,"unit":"usd"}}]}]}'
  later_bad='{"generatedAt":1789485834620,"reports":[{"limits":[
    {"status":"ok","amount":{"remainingFraction":0.5,"remaining":50,"unit":"usd"}},
    {"status":"error","amount":{"remainingFraction":0.9,"remaining":90,"unit":"usd"}}]}]}'

  state=$(deepseek_state_for_payload deepseek-first-bad "$first_bad")
  [ "$state" = outage ] || fail "an error limit at index 0 must read outage, got $state"

  state=$(deepseek_state_for_payload deepseek-later-bad "$later_bad")
  [ "$state" = outage ] \
    || fail "an error limit after a healthy one must still read outage, got $state"

  # A later report's failure counts too, not only a later limit in the first.
  state=$(deepseek_state_for_payload deepseek-later-report \
    '{"generatedAt":1789485834620,"reports":[
      {"limits":[{"status":"ok","amount":{"remainingFraction":0.5,"remaining":50,"unit":"usd"}}]},
      {"limits":[{"status":"failed","amount":{"remainingFraction":0.9,"remaining":90,"unit":"usd"}}]}]}')
  [ "$state" = outage ] \
    || fail "a failed limit in a later report must read outage, got $state"

  # All-healthy must still be eligible, so the check cannot pass by always
  # reporting outage.
  state=$(deepseek_state_for_payload deepseek-all-ok \
    '{"generatedAt":1789485834620,"reports":[{"limits":[
      {"status":"ok","amount":{"remainingFraction":0.5,"remaining":50,"unit":"usd"}},
      {"status":"ok","amount":{"remainingFraction":0.9,"remaining":90,"unit":"usd"}}]}]}')
  [ "$state" = eligible ] || fail "an all-healthy report must stay eligible, got $state"

  pass "any failed limit in omp's reports marks pi-deepseek outage, whatever its position"
}

# A spent balance and a spent fraction are two independent proofs of
# exhaustion, not a fallback chain. A healthy fraction on one limit must not
# mask a zero balance on another.
test_a_zero_balance_limit_exhausts_even_beside_a_healthy_fraction() {
  local state

  state=$(deepseek_state_for_payload deepseek-balance-only-zero \
    '{"generatedAt":1789485834620,"reports":[{"limits":[
      {"status":"ok","amount":{"remainingFraction":0.9,"remaining":90,"unit":"usd"}},
      {"status":"ok","amount":{"remaining":0,"unit":"usd"}}]}]}')
  [ "$state" = exhausted ] \
    || fail "a zero balance beside a healthy fraction must read exhausted, got $state"

  state=$(deepseek_state_for_payload deepseek-fraction-only-zero \
    '{"generatedAt":1789485834620,"reports":[{"limits":[
      {"status":"ok","amount":{"remaining":90,"unit":"usd"}},
      {"status":"ok","amount":{"remainingFraction":0,"unit":"usd"}}]}]}')
  [ "$state" = exhausted ] \
    || fail "a zero fraction beside a healthy balance must read exhausted, got $state"

  state=$(deepseek_state_for_payload deepseek-both-healthy \
    '{"generatedAt":1789485834620,"reports":[{"limits":[
      {"status":"ok","amount":{"remainingFraction":0.9,"remaining":90,"unit":"usd"}},
      {"status":"ok","amount":{"remaining":50,"unit":"usd"}}]}]}')
  [ "$state" = eligible ] \
    || fail "every bound healthy must stay eligible, got $state"

  pass "any spent bound exhausts pi-deepseek, whether it is the fraction or the balance"
}

# ---------------------------------------------------------------------------
# Gateway empty reports (captain's word, 2026-09-16): nothing spent yet is not
# unproven capacity, so an empty reports:[] is eligible until a launch or
# worker failure proves otherwise -- the same admission a no-probe route gets.
# ---------------------------------------------------------------------------
EMPTY_REPORTS_PAYLOAD='{"generatedAt":1789485834620,"reports":[],"accountsWithoutUsage":[],"disabledCredentials":[],"capacity":{}}'

fake_gateway_reading() {  # <home> <omp-json>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$(printf '%q' "$2")" > "$fakebin/omp"
  chmod +x "$fakebin/omp"
  printf '%s\n' "$fakebin"
}

test_gateway_with_no_usage_reports_reads_eligible_with_reason() {
  local home fakebin out

  home=$(make_home gateway-empty-reports "$DEEPSEEK_ONLY_POOL")
  fakebin=$(fake_gateway_reading "$home" "$EMPTY_REPORTS_PAYLOAD")
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null \
    || fail "refresh failed against an empty-reports gateway reading"

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route pi-deepseek)
  case "$out" in
    *state=eligible*"no usage reports yet"*) : ;;
    *) fail "an empty reports:[] must read eligible with a reason saying why, not unknown: $out" ;;
  esac

  pass "a gateway with no usage reports yet reads eligible with a reason saying why"
}

test_gateway_probe_error_still_reads_unknown() {
  local home fakebin out

  home=$(make_home gateway-probe-error "$DEEPSEEK_ONLY_POOL")
  fakebin=$(fm_fakebin "$home")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/omp"
  chmod +x "$fakebin/omp"
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null \
    || fail "refresh must still record a reading when the gateway probe fails"

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route pi-deepseek)
  case "$out" in
    *state=unknown*) : ;;
    *) fail "a real gateway probe failure must read unknown, never eligible: $out" ;;
  esac

  pass "a real gateway probe failure still reads unknown, never eligible"
}

test_gateway_empty_reports_preserves_a_verified_failure() {
  local home fakebin out

  home=$(make_home gateway-empty-reports-failure "$DEEPSEEK_ONLY_POOL")
  fakebin=$(fake_gateway_reading "$home" "$EMPTY_REPORTS_PAYLOAD")
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null \
    || fail "refresh failed against an empty-reports gateway reading"
  acquire "$home" a1 a1 g1 '["pi-deepseek"]' >/dev/null
  finish "$home" a1 launch-failed >/dev/null

  # The empty-reports reading says nothing about whether the route works, only
  # that nothing has been spent, so it must not clear a proven failure: a
  # later verified success does that, exactly as for a no-probe route.
  PATH="$fakebin:$PATH" FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route pi-deepseek)
  case "$out" in
    *state=launch-failed*) : ;;
    *) fail "an empty-reports refresh must preserve pi-deepseek's verified failure: $out" ;;
  esac
  out=$(acquire "$home" a2 a2 g1 '["pi-deepseek"]')
  [ "$(result_field "$out" result)" = deferred ] \
    || fail "the proven-failed route must stay out until new evidence arrives: $out"

  pass "an empty-reports gateway reading preserves a verified failure until a success clears it"
}

# Route ids come from operator-authored config, so one may contain a shell
# glob character. It must stay the literal configured string: expanding it
# against the caller's working directory would publish invented routes and
# let arbitrary filenames pass the known-route check.
test_a_glob_shaped_route_id_is_never_pathname_expanded() {
  local home out state_keys acquire_out

  home=$(make_home glob-route-id \
    '{"rules":[{"class":"builder","use":[{"harness":"*","model":"default","effort":"high"}]}]}')
  # Run from a directory that really does contain files a glob would match.
  mkdir -p "$home/cwd"
  : > "$home/cwd/AGENTS.md"
  : > "$home/cwd/bin"

  out=$( (cd "$home/cwd" && FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes) | tr '\n' ' ')
  [ "$out" = "* " ] || fail "the catalog must list the literal configured route id, got: [$out]"

  (cd "$home/cwd" && FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" refresh >/dev/null) \
    || fail "refresh failed for a glob-shaped route id"
  state_keys=$(jq -cr '.routes | keys' "$home/state/route.json")
  [ "$state_keys" = '["*"]' ] \
    || fail "refresh published expanded filenames instead of the configured route: $state_keys"

  # The known-route check must not accept a name that merely matches the glob.
  acquire_out=$( (cd "$home/cwd" && acquire "$home" A1 w1 r1.1.1 '["bin"]') )
  [ "$(result_field "$acquire_out" result)" = error ] \
    || fail "a filename matching the glob was accepted as a route id: $acquire_out"

  # The real configured id is still usable.
  acquire_out=$( (cd "$home/cwd" && acquire "$home" A2 w2 r2.2.2 '["*"]') )
  [ "$(result_field "$acquire_out" result)" != error ] \
    || fail "the literal configured route id must still be a known route: $acquire_out"

  pass "a glob-shaped route id stays literal and never expands against the working directory"
}

# The installer writes its agent plist through a temp file in the LaunchAgents
# directory itself. When the install fails after that temp file exists, it must
# not be left behind: launchd ignores the non-.plist suffix, so the debris is
# invisible and would accumulate one file per failed attempt. The fake mv below
# stands in for the real failure causes the install cannot provoke on demand
# (a read-only agent directory, a full disk), which strike at exactly this
# point: after mktemp created the file, before the rename lands.
test_a_failed_refresh_install_leaves_no_temp_plist() {
  local home agents fakebin status out leftovers published

  if [ "$(uname)" != Darwin ]; then
    pass "route-refresh install cleanup (skipped: launchd agents are macOS-only)"
    return 0
  fi

  home="$TMP_ROOT/refresh-install-fail"
  agents="$home/agents"
  mkdir -p "$home/state" "$agents"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
echo "mv: rename failed: Permission denied" >&2
exit 1
SH
  chmod +x "$fakebin/mv"

  out=$(PATH="$fakebin:$PATH" LAUNCH_AGENTS_DIR="$agents" FM_HOME="$home" \
    "$ROOT/bin/fm-route-refresh-install.sh" install --yes 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "an install whose rename fails must exit nonzero, got 0: $out"

  leftovers=$(find "$agents" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] \
    || fail "a failed install left $leftovers temp plist file(s) in the LaunchAgents directory"
  published=$(find "$agents" -maxdepth 1 -name '*.plist' 2>/dev/null | wc -l | tr -d ' ')
  [ "$published" = 0 ] || fail "a failed install must not publish a plist"

  pass "a failed route-refresh install leaves no temp plist behind"
}

# firstmate issue #127: a scheduled refresh under launchd's minimal built-in
# PATH could not find quota-axi at all, so a genuinely healthy pooled route
# came back state=unknown with an exit-127 "command not found" reason that
# read exactly like inconclusive provider telemetry. The installer must give
# the plist an explicit PATH covering quota-axi's real location, resolved at
# install time rather than assumed. This drives the real installer and the
# real refresh script; only launchctl itself is faked, so the real machine's
# launchd namespace is never touched.
test_scheduled_refresh_resolves_probe_tools_under_minimal_path() {
  local home agents fakebin toolbin out plist_path plist_path_value status

  if [ "$(uname)" != Darwin ]; then
    pass "scheduled refresh PATH resolution (skipped: launchd agents are macOS-only)"
    return 0
  fi

  home="$TMP_ROOT/minimal-path-refresh"
  agents="$home/agents"
  toolbin="$home/toolbin"
  mkdir -p "$home/state" "$home/config" "$agents" "$toolbin"
  printf '%s' "$FOUR_ROUTE_POOL" > "$home/config/crew-dispatch.json"
  toolbin=$(cd "$toolbin" && pwd -P)

  # A healthy pooled quota-axi, installed at a location NOT on the system
  # default PATH, standing in for ~/.nvm/versions/node/*/bin/quota-axi.
  cat > "$toolbin/quota-axi" <<'SH'
#!/usr/bin/env bash
provider=claude
case "$*" in *"--provider codex"*) provider=codex ;; esac
cat <<JSON
{"generatedAt":"2026-09-18T00:00:00.000Z","schemaVersion":3,"providers":[{"provider":"$provider","label":"$provider","source":"oauth","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":42}]},"state":{"status":"fresh","stale":false,"refreshedAt":"2026-09-18T00:00:00.000Z","sourcesTried":["oauth"]}}]}
JSON
SH
  chmod +x "$toolbin/quota-axi"

  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list) exit 1 ;;   # nothing registered yet: no output, exit nonzero like the real thing
  load|unload|remove) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/launchctl"

  # The installer resolves each probe tool's real directory with `command -v`
  # under ITS OWN run-time PATH (the interactive/install-time PATH), so
  # toolbin must be on PATH here, exactly as it would be on the captain's
  # real login shell where quota-axi already works. The real ambient PATH is
  # deliberately excluded: this machine has a real quota-axi installed too,
  # and it must never win over the fixture the test controls.
  out=$(PATH="$toolbin:$fakebin:/usr/bin:/bin" LAUNCH_AGENTS_DIR="$agents" FM_HOME="$home" \
    "$ROOT/bin/fm-route-refresh-install.sh" install --yes 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -eq 0 ] || fail "route-refresh install failed: $out"

  plist_path=$(find "$agents" -maxdepth 1 -name '*.plist' | head -n1)
  [ -n "$plist_path" ] || fail "install did not publish a plist in $agents: $out"

  plist_path_value=$(plutil -extract EnvironmentVariables.PATH raw "$plist_path" 2>/dev/null) \
    || fail "installed plist has no EnvironmentVariables.PATH: $(cat "$plist_path")"
  case "$plist_path_value" in
    *"$toolbin"*) : ;;
    *) fail "installed plist PATH does not cover quota-axi's real directory $toolbin: $plist_path_value" ;;
  esac

  # Simulate launchd's own minimal PATH (env -i, no login-shell dirs) plus
  # ONLY the PATH the plist itself now provides -- the same shape as the
  # reproduction in issue #127, but with the fixed plist's PATH applied.
  out=$(env -i PATH="$plist_path_value:/usr/bin:/bin" HOME="$HOME" \
    FM_ROUTE_HOME_OVERRIDE="$home" /bin/bash "$ROOT/bin/fm-route.sh" refresh 2>&1)
  case "$out" in
    refreshed\ generation=*) : ;;
    *) fail "refresh under the installed plist's PATH did not run: $out" ;;
  esac

  out=$(env -i PATH="$plist_path_value:/usr/bin:/bin" HOME="$HOME" \
    FM_ROUTE_HOME_OVERRIDE="$home" /bin/bash "$ROOT/bin/fm-route.sh" status --route claude)
  case "$out" in
    *state=eligible*) : ;;
    *state=unknown*) fail "a healthy pooled route still read unknown under the plist's own PATH (the #127 bug): $out" ;;
    *) fail "unexpected status after refresh under the installed plist's PATH: $out" ;;
  esac
  pass "a scheduled refresh under the installed plist's own minimal PATH resolves quota-axi and reads a healthy route as eligible"
}

# The plist is XML that launchd parses, so every interpolated value is part of
# that contract. A path carrying an XML metacharacter (a checkout under "R&D",
# a homebrew prefix the operator never chose) must still produce a plist the
# real parser accepts, with the original path readable back out. plutil is
# launchd's own parser, so it is the real consumer, not a substring check.
test_installed_plist_is_valid_xml_for_paths_with_metacharacters() {
  local home agents fakebin toolbin out status plist_path got_path got_home got_log

  if [ "$(uname)" != Darwin ]; then
    pass "plist XML escaping (skipped: launchd agents are macOS-only)"
    return 0
  fi

  # Every XML metacharacter the escaper handles, in both a tool directory
  # (reached through PATH) and the home path (reached through FM_HOME and the
  # derived log path), because each lands in a different <string> element.
  home="$TMP_ROOT/plist-xml-escape/a & b <c> d"
  agents="$home/agents"
  toolbin="$home/x&y/bin"
  mkdir -p "$home/state" "$home/config" "$agents" "$toolbin"
  printf '%s' "$FOUR_ROUTE_POOL" > "$home/config/crew-dispatch.json"
  home=$(cd "$home" && pwd -P)
  toolbin=$(cd "$toolbin" && pwd -P)

  printf '#!/usr/bin/env bash\nexit 0\n' > "$toolbin/quota-axi"
  chmod +x "$toolbin/quota-axi"

  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list) exit 1 ;;
  load|unload|remove) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/launchctl"

  out=$(PATH="$toolbin:$fakebin:/usr/bin:/bin" LAUNCH_AGENTS_DIR="$agents" \
    FM_ROUTE_HOME_OVERRIDE="$home" \
    "$ROOT/bin/fm-route-refresh-install.sh" install --yes 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -eq 0 ] || fail "install failed for a home containing XML metacharacters: $out"

  plist_path=$(find "$agents" -maxdepth 1 -name '*.plist' | head -n1)
  [ -n "$plist_path" ] || fail "install published no plist in $agents: $out"

  plutil -lint "$plist_path" >/dev/null 2>&1 \
    || fail "installed plist is not valid XML: $(plutil -lint "$plist_path" 2>&1)"

  # Escaping is only correct if the parser hands back the ORIGINAL path; a
  # plist that merely lints but yields "a &amp; b" would still break launchd.
  got_path=$(plutil -extract EnvironmentVariables.PATH raw "$plist_path" 2>/dev/null) \
    || fail "installed plist has no EnvironmentVariables.PATH"
  case "$got_path" in
    *"$toolbin"*) : ;;
    *) fail "parsed plist PATH lost or mangled the metacharacter directory $toolbin: $got_path" ;;
  esac

  got_home=$(plutil -extract EnvironmentVariables.FM_ROUTE_HOME_OVERRIDE raw "$plist_path" 2>/dev/null) \
    || fail "installed plist has no FM_ROUTE_HOME_OVERRIDE"
  [ "$got_home" = "$home" ] \
    || fail "parsed plist FM_ROUTE_HOME_OVERRIDE does not round-trip: want [$home] got [$got_home]"

  got_log=$(plutil -extract StandardOutPath raw "$plist_path" 2>/dev/null) \
    || fail "installed plist has no StandardOutPath"
  [ "$got_log" = "$home/state/.route-refresh.launchd.log" ] \
    || fail "parsed plist StandardOutPath does not round-trip: got [$got_log]"

  pass "an install whose paths contain XML metacharacters writes a plist the real parser accepts and round-trips"
}

# firstmate issue #127 acceptance criteria 2 and 3: a probe tool missing from
# PATH is a broken check, never provider telemetry, and the dispatch refusal
# must say so rather than naming "unknown telemetry" (which sends a human
# to check quotas that are fine).
test_missing_probe_tool_reads_as_broken_check_not_provider_telemetry() {
  local home out reason

  home=$(make_home missing-probe-tool "$FOUR_ROUTE_POOL")
  env -i PATH=/usr/bin:/bin HOME="$HOME" FM_ROUTE_HOME_OVERRIDE="$home" \
    /bin/bash "$ROOT/bin/fm-route.sh" refresh >/dev/null \
    || fail "refresh must still succeed (and record unknown) when a probe tool is missing"

  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" status --route claude)
  case "$out" in
    *state=unknown*) : ;;
    *) fail "a missing probe tool must still record unknown, never eligible: $out" ;;
  esac
  case "$out" in
    *"not on PATH"*"health check could not run"*) : ;;
    *) fail "the recorded reason does not distinguish a missing tool from provider telemetry: $out" ;;
  esac

  out=$(acquire "$home" a1 a1 g1 '["claude","codex"]')
  [ "$(result_field "$out" result)" = deferred ] \
    || fail "a route whose check could not run must still defer, never be selected: $out"
  reason=$(result_field "$out" reason)
  case "$reason" in
    *"health check could not run"*) : ;;
    *"unknown telemetry"*) fail "dispatch refusal named generic unknown telemetry instead of the real missing-tool cause: $reason" ;;
    *) fail "dispatch refusal did not name the real cause: $reason" ;;
  esac
  pass "a probe tool missing from PATH records a distinguishable broken-check reason and the dispatch refusal names it, never reading as provider telemetry"
}

# The safety property issue #127 explicitly protects: a route that is
# genuinely unknown (the tool ran, the evidence was inconclusive or stale)
# must keep deferring with the original generic wording, never the new
# missing-tool wording and never eligible. This is what stops the fix from
# widening eligibility.
test_genuinely_unknown_route_keeps_generic_refusal_and_still_defers() {
  local home out reason

  home=$(make_home genuine-unknown "$FOUR_ROUTE_POOL")
  seed_routes "$home" '{
    "claude":{"state":"unknown","reason":"quota-axi returned no claude provider report","observedAt":"t","manualDisabled":false},
    "codex":{"state":"unknown","reason":"quota-axi returned no codex provider report","observedAt":"t","manualDisabled":false}
  }'
  out=$(acquire "$home" a1 a1 g1 '["claude","codex"]')
  [ "$(result_field "$out" result)" = deferred ] \
    || fail "a genuinely unknown route must still defer, never be selected: $out"
  reason=$(result_field "$out" reason)
  case "$reason" in
    *"unknown telemetry"*) : ;;
    *"health check could not run"*) fail "a genuinely unknown route (real evidence, just inconclusive) was wrongly reported as a broken check: $reason" ;;
    *) fail "unexpected refusal reason for a genuinely unknown route: $reason" ;;
  esac
  pass "a genuinely unknown route keeps the original generic refusal wording and still defers"
}

# firstmate issue #127, "second, separate problem": the installer's home_key
# is derived from FM_HOME's real path, so installing from a relocated home
# (a worktree, a renamed checkout) mints a new label with its own plist,
# and a torn-down worktree can leave its old label registered in launchd
# forever with no backing plist. install must sweep and unload those.
test_install_unloads_orphaned_job_with_no_backing_plist() {
  local home agents fakebin out status removed_label

  if [ "$(uname)" != Darwin ]; then
    pass "orphaned route-refresh job sweep (skipped: launchd agents are macOS-only)"
    return 0
  fi

  home="$TMP_ROOT/orphan-sweep"
  agents="$home/agents"
  mkdir -p "$home/state" "$home/config" "$agents"
  printf '%s' "$FOUR_ROUTE_POOL" > "$home/config/crew-dispatch.json"

  fakebin=$(fm_fakebin "$home")
  removed_label="$home/removed-label"
  cat > "$fakebin/launchctl" <<SH
#!/usr/bin/env bash
case "\$1" in
  list)
    if [ "\$#" -eq 0 ] || [ "\$2" = "" ]; then
      printf -- '-\t0\tcom.firstmate.route-refresh.orphan12345678\n'
      exit 0
    fi
    exit 1
    ;;
  remove) printf '%s\n' "\$2" >> "$removed_label"; exit 0 ;;
  load|unload) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/launchctl"

  # HOME is redirected into the sandbox so the installer's sweep compares the
  # faked launchctl registry against this sandbox's own LaunchAgents
  # directory. Without that the sweep refuses to run at all, precisely so a
  # redirected LAUNCH_AGENTS_DIR can never make the real machine's jobs look
  # orphaned and get unloaded.
  mkdir -p "$home/fakehome/Library"
  ln -sfn "$agents" "$home/fakehome/Library/LaunchAgents"
  out=$(PATH="$fakebin:$PATH" HOME="$home/fakehome" \
    LAUNCH_AGENTS_DIR="$home/fakehome/Library/LaunchAgents" FM_HOME="$home" \
    "$ROOT/bin/fm-route-refresh-install.sh" install --yes 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -eq 0 ] || fail "install failed while sweeping an orphaned job: $out"

  [ -f "$removed_label" ] || fail "install never called launchctl remove for the orphaned label: $out"
  grep -qxF com.firstmate.route-refresh.orphan12345678 "$removed_label" \
    || fail "install removed the wrong label(s): $(cat "$removed_label" 2>/dev/null)"
  pass "install unloads an orphaned route-refresh job whose plist no longer exists"
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
test_refresh_marks_no_probe_route_eligible_with_reason
test_acquire_selects_a_no_probe_route
test_no_probe_route_verified_failure_excludes_then_recovers
test_route_with_erroring_probe_still_records_unknown
test_pooled_codex_admits_on_one_usable_account_of_five
test_pooled_codex_all_accounts_blocked_is_exhausted
test_pooled_claude_reads_the_probe_accounts_location
test_pooled_missing_command_falls_back_to_quota_axi_and_says_so
test_pooled_reader_failures_fall_back_to_quota_axi
test_verified_recovery_reenables_after_deferral
test_manual_disable_wins_and_survives
test_zero_prepaid_grok_credits_not_exhaustion
test_zero_prepaid_grok_credits_alone_is_unknown_not_exhausted
test_idempotent_acquire_and_finish
test_closed_assignment_never_reauthorizes
test_release_deletes_a_running_record_and_leaves_routes_untouched
test_release_refuses_a_foreign_owner
test_release_never_deletes_closed_history
test_release_refuses_malformed_requests_before_any_write
test_corrupt_store_is_refused_and_left_intact
test_wrongly_typed_store_is_refused_and_left_intact
test_wrongly_typed_store_member_values_are_refused_by_every_reader
test_top_level_default_pin_contributes_its_route
test_healthy_store_still_serves_every_reader
test_class_scoped_routes_narrow_to_that_class_pool
test_failed_candidate_lookup_reports_the_resolver_reason
test_pinned_class_offers_only_its_pinned_route
test_disabled_only_route_is_never_offered_as_a_candidate
test_different_owner_reusing_assignment_id_refused
test_launch_failure_finish_excludes_route_immediately
test_abandoned_owner_does_not_block_fewest_pending
test_live_owner_with_matching_generation_still_counts
test_owner_with_mismatched_generation_is_abandoned
test_pinned_researcher_route_preserved
test_unapproved_route_id_refused
test_malformed_request_shapes_are_refused_before_any_write
test_refresh_runs_standalone_with_fake_bounded_readers
test_a_failed_refresh_install_leaves_no_temp_plist
test_any_failed_limit_marks_deepseek_outage_regardless_of_position
test_a_zero_balance_limit_exhausts_even_beside_a_healthy_fraction
test_gateway_with_no_usage_reports_reads_eligible_with_reason
test_gateway_probe_error_still_reads_unknown
test_gateway_empty_reports_preserves_a_verified_failure
test_a_glob_shaped_route_id_is_never_pathname_expanded
test_real_concurrent_processes_split_evenly_no_lost_updates
test_scheduled_refresh_resolves_probe_tools_under_minimal_path
test_installed_plist_is_valid_xml_for_paths_with_metacharacters
test_missing_probe_tool_reads_as_broken_check_not_provider_telemetry
test_genuinely_unknown_route_keeps_generic_refusal_and_still_defers
test_install_unloads_orphaned_job_with_no_backing_plist

echo "# all fm-route tests passed"
