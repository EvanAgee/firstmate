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

class_routes() {  # <home> <class>
  FM_ROUTE_HOME_OVERRIDE="$1" "$ROUTE" routes --class "$2" | sort | tr '\n' ' '
}

test_class_scoped_routes_narrow_to_that_class_pool() {
  local home out
  home=$(make_home class-scope "$EXAMPLE_SHAPED_POOL")
  out=$(FM_ROUTE_HOME_OVERRIDE="$home" "$ROUTE" routes | sort | tr '\n' ' ')
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
  local home agents fakebin status out leftovers

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
  [ ! -f "$agents/$(basename "$agents")".plist ] || fail "a failed install must not publish a plist"

  pass "a failed route-refresh install leaves no temp plist behind"
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
test_a_glob_shaped_route_id_is_never_pathname_expanded
test_real_concurrent_processes_split_evenly_no_lost_updates

echo "# all fm-route tests passed"
