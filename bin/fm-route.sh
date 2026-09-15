#!/usr/bin/env bash
# Shared provider-availability admission for native launches, across every
# approved route a caller's config/crew-dispatch.json profiles name. One
# private JSON file, in the canonical owner home shared by every local worker
# and validation caller, is the eligibility and assignment record; every
# writer takes .route.lock (bin/fm-wake-lib.sh's fm_lock_* helpers) and
# publishes with a tmp-file + mv -f atomic replace.
#
# Contract (data/fm-dynamic-subscription-routing/report.md, "Addendum: minimum
# assignment routing", plus the 2026-09-15 admission corrections): balance by
# fewest pending/running managed assignments per eligible route, ROTATING
# ties (not first-in-array); multiple Claude models never multiply the claude
# route's slots. Exclude only PROVEN exhaustion/outage/auth failure;
# unknown/stale telemetry is a distinct "unknown" state, never proven
# unavailable, and never blocks selection on its own. Zero prepaid Grok
# credits is never read as subscription exhaustion. Manual disable
# (config/route-disabled) always wins, takes effect immediately (never
# waiting for the next refresh), and survives refresh.
#
# Public acquire/finish protocol: bounded JSON on stdin, one JSON object on
# stdout. No other subcommand (refresh/status/routes/group-for/disable/
# enable) touches stdin; they keep their existing flag/argument shape because
# they carry no untrusted caller-supplied identity to bound. Nothing here
# ever accepts or evaluates an executable string: every JSON field is a plain
# string/array of strings, validated before use, never passed to eval or a
# shell substitution that could reinterpret it.
#
# Usage:
#   echo '{"assignment_id":"<id>","owner":{"identity":"<id>","generation":"<gen>"},"routes":["codex","claude"]}' \
#     | fm-route.sh acquire
#   echo '{"assignment_id":"<id>","outcome":"success","profile":{"adapter":"codex","model":"gpt-5","effort":"high"}}' \
#     | fm-route.sh finish
#   fm-route.sh refresh
#   fm-route.sh status [--route <id>]
#   fm-route.sh disable --route <id>
#   fm-route.sh enable --route <id>
#   fm-route.sh routes                         # list route ids derived from config
#   fm-route.sh routes --class <class>         # only the route ids that class's own pool covers
#   fm-route.sh group-for --harness <h> --model <m>   # print the route id one profile maps to
#
# acquire request fields (all required):
#   assignment_id   caller-chosen stable id (task id, in Firstmate's own
#                   callers). A repeat call with the SAME assignment_id and
#                   the SAME owner.identity, while the record is pending,
#                   running, or closed, returns that existing record
#                   unchanged (idempotent) -- closed never authorizes another
#                   launch: it answers "already-closed" with no route_id. A
#                   deferred record is re-evaluated fresh on the
#                   next call with the same id (retriable), never returned
#                   stale, so newer eligibility evidence can admit it. A
#                   different owner.identity reusing an existing id is
#                   refused with a JSON error object.
#   owner.identity  the identity that owns this assignment.
#   owner.generation a freshness token the caller supplies; stored on the
#                   record and read back by finish/status, but not itself
#                   part of the idempotency key.
#   routes          array of the caller's own approved candidate route ids
#                   (a subset of `fm-route.sh routes`'s output). acquire
#                   never invents a route id outside this list and never
#                   picks a profile within the chosen route.
#
# acquire response, one of:
#   {"result":"selected","route_id":"codex","reason":"fewest-pending","generation":5}
#   {"result":"deferred","reason":"...","generation":5}
#   {"result":"already-closed","assignment_id":"<id>","generation":5,"note":"..."}
#   {"result":"error","error":"..."}
# ONLY "selected" carries route_id and only "selected" authorizes a launch;
# "already-closed" deliberately omits route_id so a caller keying on it can
# never relaunch from a spent record.
# "generation" here is route.json's own monotonic decision/observation
# generation (bumped by refresh), distinct from the caller-supplied
# owner.generation.
#
# finish request fields:
#   assignment_id   the id to close.
#   outcome         one of success, launch-failed, auth-failed, exhausted,
#                   outage.
#   profile         optional {adapter, model, effort}: the actual resolved,
#                   nonsecret profile identity the caller launched, recorded
#                   on the closed assignment for a future session-reuse
#                   qualifier to key on (adapter/provider/effective-model/
#                   billing-route/settings), without fm-route.sh owning that
#                   qualification logic itself.
# An auth-failed/exhausted/outage outcome is recorded as verified failure
# evidence against that route: refresh's next probe corroborates or clears
# it, but finish itself marks the route EXCLUDED from that moment (never
# waiting for the next timer tick), until newer route-relevant success
# clears it. finish never blocks on network I/O and never holds the
# assignment lock while waiting on anything external -- it only writes the
# already-decided outcome.
#
# finish response: {"result":"closed","assignment_id":"<id>"}, idempotent (a
# second finish on an already-closed assignment succeeds with no effect).
#
# refresh re-reads non-inference health/quota evidence for every route in
# the canonical catalog and atomically republishes state/route.json's routes
# map. It never runs inside acquire: acquire only reads the most recent
# refresh's recorded state PLUS finish's own immediate exclusions, evaluated
# fresh at THIS acquire call's decision time (a route finish marked excluded
# a moment ago is excluded now, even if the refresh timer is dead or has not
# ticked since). A stalled refresh timer degrades quota/health evidence to
# stale (unknown-treated), never a hang and never a false eligible.
#
# Reconciliation: before selecting, acquire drops any candidate route's
# pending/running assignment from the fewest-pending count when that
# assignment's owner has no live state/<owner>.meta record in the canonical
# home, or that record's spawn_gen no longer matches the assignment's stored
# owner generation (the owner was torn down or relaunched under a new
# attempt) -- elapsed time alone never triggers this, only actual
# process/task/run ownership evidence.
#
# Route ids are derived from config/crew-dispatch.json's approved profiles
# (rules[].use, rules[].pin, rules[].defaultPin, .default) at the canonical
# home, never hardcoded: fm_route_group_for maps each profile's {harness,
# model} to a route id by billing surface (claude, codex, any harness whose
# model starts with xai/ groups to pi-grok, any harness whose model starts
# with vercel-ai-gateway/ groups to pi-deepseek). A profile whose
# harness/model matches no known billing surface still gets a route id (its
# harness name) so it is never silently dropped from the catalog, but
# fm_route_probe for that id returns unknown ("unsupported telemetry";
# defer explicitly rather than guess).
#
# Canonical owner home: the route store always lives under the primary
# firstmate checkout's own state/ and config/ directories, the same shared
# location for every local worker home and every validation caller. A
# secondmate (a separate tracked-code checkout) points config/route-
# canonical-home at the primary's absolute path (inherited the same way
# config/backend already is); FM_ROUTE_HOME_OVERRIDE wins over both, for
# tests and for a deliberately isolated pool.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_route_resolve_canonical_home() {
  if [ -n "${FM_ROUTE_HOME_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_ROUTE_HOME_OVERRIDE"
    return 0
  fi
  if [ -f "$FM_ROOT/config/route-canonical-home" ]; then
    local pointed
    IFS= read -r pointed < "$FM_ROOT/config/route-canonical-home" 2>/dev/null || pointed=
    pointed=${pointed%$'\r'}
    if [ -n "$pointed" ] && [ -d "$pointed" ]; then
      printf '%s\n' "$pointed"
      return 0
    fi
  fi
  printf '%s\n' "$FM_ROOT"
}

ROUTE_CANONICAL_HOME=$(fm_route_resolve_canonical_home)

# Maps one profile's {harness, model} to a route id. Pure function of its
# inputs; fm_route_ids_from_config supplies every profile in the active
# config, so the derived route set always matches what is approved.
fm_route_group_for() {
  local harness=$1 model=$2
  case "$harness" in
    claude) printf 'claude\n'; return 0 ;;
    codex) printf 'codex\n'; return 0 ;;
  esac
  case "$model" in
    xai/*) printf 'pi-grok\n'; return 0 ;;
    vercel-ai-gateway/*) printf 'pi-deepseek\n'; return 0 ;;
  esac
  printf '%s\n' "$harness"
}

# With no argument, list every route id the whole approved catalog covers,
# derived from every approved profile in config/crew-dispatch.json.
#
# With a class name, list only the route ids that class can currently be
# SERVED by. That question belongs to bin/fm-dispatch-resolve.sh, which
# already owns pool selection, pin detection, the static enabled column, and
# the model-scoped quota window, so this shells out to its
# --list-candidate-routes mode and prints the answer verbatim rather than
# re-deriving a parallel copy that drifts one exclusion rule at a time.
# acquire is unaffected: it still balances fewest-pending across whatever
# route ids it is handed.
fm_route_ids_from_config() {
  local class=${1:-} config="$FM_ROUTE_CANONICAL_CONFIG_DIR/crew-dispatch.json" harness model seen="" g
  [ -f "$config" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [ -n "$class" ]; then
    local out status=0
    out=$(FM_CONFIG_OVERRIDE="$FM_ROUTE_CANONICAL_CONFIG_DIR" \
      FM_STATE_OVERRIDE="$FM_ROUTE_CANONICAL_STATE_DIR" \
      "$SCRIPT_DIR/fm-dispatch-resolve.sh" --class "$class" \
        --home "$ROUTE_CANONICAL_HOME" --list-candidate-routes 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
      printf 'error: could not determine candidate routes for class %s: %s\n' \
        "$class" "$(printf '%s' "$out" | tr '\n' ' ')" >&2
      return "$status"
    fi
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  while IFS=$'\t' read -r harness model; do
    [ -n "$harness" ] || continue
    g=$(fm_route_group_for "$harness" "${model:-default}")
    case " $seen " in
      *" $g "*) continue ;;
    esac
    seen="$seen $g"
    printf '%s\n' "$g"
  done < <(jq -r '
    def profiles($v):
      if ($v == null) then []
      elif ($v | type) == "array" then $v
      else [$v]
      end;
    ((.rules // [])[]? | (profiles(.use) + profiles(.pin))[]?),
    (profiles(.default)[]?),
    (profiles(.defaultPin)[]?)
    | select(. != null)
    | [(.harness // ""), (.model // "default")] | @tsv
  ' "$config" 2>/dev/null)
}

fm_route_is_known() {
  local r=$1 x
  while IFS= read -r x; do
    [ "$x" != "$r" ] || return 0
  done < <(fm_route_ids_from_config)
  return 1
}

# ---- non-inference health probes ------------------------------------------
# Each probe prints exactly one TSV line: state<TAB>reason<TAB>observed_at
# state is one of: eligible exhausted outage auth-failed unknown
# observed_at is the RFC3339 timestamp the probe's own source attributes to
# the reading (never the probe's own wall-clock collection time). A probe
# that cannot parse a usable observation timestamp reports unknown.
#
# Claude, Codex, and Grok all read through quota-axi (verified schemaVersion
# 3: providers[].quotaSemantics.effectiveAvailability[] scoped by
# all_models/all_products, providers[].state.{status,stale,refreshedAt}),
# never an invented per-tool schema. Grok additionally carries
# providers[].credits.remaining, which is PREPAID balance, never subscription
# evidence, and is never read here. Gateway/DeepSeek reads through
# `omp usage --provider vercel-ai-gateway --json` (verified live shape:
# reports[].limits[].amount.{remaining,limit,used,unit}, plus an empty
# reports:[] when the account has no usage yet). Probes shell out to the
# existing proxy/CLI owners and never touch credentials directly; command
# names are overridable so tests substitute fake readers on PATH.
: "${FM_ROUTE_QUOTA_AXI_BIN:=quota-axi}"
: "${FM_ROUTE_OMP_BIN:=omp}"

fm_route_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Shared quota-axi reader for claude/codex/grok. $1 is the quota-axi provider
# id, $2 is the effectiveAvailability scope to read (all_models/all_products).
fm_route_probe_quota_axi() {
  local provider=$1 scope=$2 json state stale ts pct auth_status err
  json=$("$FM_ROUTE_QUOTA_AXI_BIN" --provider "$provider" --json 2>/dev/null) || {
    printf 'unknown\tquota-axi --provider %s failed\t%s\n' "$provider" "$(fm_route_now)"
    return 0
  }
  state=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[]? | select(.provider == $p) | .state.status) // empty' 2>/dev/null) || state=
  [ -n "$state" ] || { printf 'unknown\tquota-axi returned no %s provider report\t%s\n' "$provider" "$(fm_route_now)"; return 0; }
  stale=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[]? | select(.provider == $p) | .state.stale) // false' 2>/dev/null) || stale=false
  ts=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[]? | select(.provider == $p) | .state.refreshedAt) // empty' 2>/dev/null) || ts=
  [ -n "$ts" ] || ts=$(fm_route_now)
  err=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[]? | select(.provider == $p) | .state.error) // empty' 2>/dev/null) || err=
  auth_status=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[]? | select(.provider == $p) | .state.authStatus) // empty' 2>/dev/null) || auth_status=

  case "$state" in
    auth_required)
      printf 'auth-failed\t%s\t%s\n' "${err:-quota-axi reports auth_required for $provider}" "$ts"
      return 0
      ;;
    rate_limited)
      printf 'outage\t%s\t%s\n' "${err:-quota-axi reports rate_limited for $provider}" "$ts"
      return 0
      ;;
    error)
      printf 'unknown\t%s\t%s\n' "${err:-quota-axi reports a provider error for $provider}" "$ts"
      return 0
      ;;
  esac
  if [ "$auth_status" = expired_refreshable ]; then
    printf 'unknown\t%s\t%s\n' "${err:-quota-axi reports $provider auth as expired_refreshable, not yet a confirmed failure}" "$ts"
    return 0
  fi
  if [ "$stale" = true ]; then
    printf 'unknown\tquota-axi %s report is stale (refreshedAt=%s)\t%s\n' "$provider" "$ts" "$ts"
    return 0
  fi
  pct=$(printf '%s' "$json" | jq -r --arg p "$provider" --arg scope "$scope" '
    (.providers[]? | select(.provider == $p) | .quotaSemantics.effectiveAvailability[]?
      | select(.scope == $scope) | .effectivePercentRemaining) // empty
  ' 2>/dev/null) || pct=
  if [ -z "$pct" ]; then
    printf 'unknown\tquota-axi %s reported no effective remaining for scope %s\t%s\n' "$provider" "$scope" "$ts"
    return 0
  fi
  if awk -v p="$pct" 'BEGIN{exit !(p<=0)}' 2>/dev/null; then
    printf 'exhausted\t%s effective remaining at %s%% for scope %s\t%s\n' "$provider" "$pct" "$scope" "$ts"
    return 0
  fi
  printf 'eligible\t%s effective remaining %s%% for scope %s\t%s\n' "$provider" "$pct" "$scope" "$ts"
}

fm_route_probe_claude() { fm_route_probe_quota_axi claude all_models; }
fm_route_probe_codex() { fm_route_probe_quota_axi codex all_models; }
fm_route_probe_pi_grok() {
  # Grok's providers[].credits.remaining is prepaid balance; it is NEVER read
  # here. Only quotaSemantics.effectiveAvailability[scope=all_products]
  # (the shared subscription-period credits window) counts as subscription
  # eligibility evidence, and fm_route_probe_quota_axi already excludes the
  # credits field entirely.
  fm_route_probe_quota_axi grok all_products
}

fm_route_probe_pi_deepseek() {
  local json balance remaining_fraction unit ts reports_count status
  # Gateway's real omp usage shape (live-verified): reports[].limits[].amount
  # .{used,limit,remaining,usedFraction,remainingFraction,unit}, generatedAt
  # as epoch milliseconds; an account with no usage yet returns reports:[].
  json=$("$FM_ROUTE_OMP_BIN" usage --provider vercel-ai-gateway --json 2>/dev/null) || {
    printf 'unknown\tomp usage --provider vercel-ai-gateway failed\t%s\n' "$(fm_route_now)"
    return 0
  }
  ts=$(printf '%s' "$json" | jq -r '(.generatedAt // empty)' 2>/dev/null) || ts=
  if [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
    ts=$(fm_route_ms_to_rfc3339 "$ts") || ts=$(fm_route_now)
  else
    ts=$(fm_route_now)
  fi
  reports_count=$(printf '%s' "$json" | jq -r '(.reports // []) | length' 2>/dev/null) || reports_count=0
  if [ "$reports_count" -le 0 ] 2>/dev/null; then
    printf 'unknown\tomp usage vercel-ai-gateway reported no usage reports yet (authorized trial allowance unproven)\t%s\n' "$ts"
    return 0
  fi
  status=$(printf '%s' "$json" | jq -r '
    [.reports[]?.limits[]?.status // empty]
    | map(select(. == "error" or . == "failed")) | first // empty
  ' 2>/dev/null) || status=
  case "$status" in
    error|failed)
      printf 'outage\tomp usage vercel-ai-gateway reported limit status %s\t%s\n' "$status" "$ts"
      return 0
      ;;
  esac
  remaining_fraction=$(printf '%s' "$json" | jq -r '
    [.reports[]?.limits[]?.amount | select(. != null) | (.remainingFraction // empty)] | min // empty
  ' 2>/dev/null) || remaining_fraction=
  balance=$(printf '%s' "$json" | jq -r '
    [.reports[]?.limits[]?.amount | select(. != null) | (.remaining // empty)] | min // empty
  ' 2>/dev/null) || balance=
  unit=$(printf '%s' "$json" | jq -r '[.reports[]?.limits[]?.amount.unit // empty] | first // empty' 2>/dev/null) || unit=
  if [ -z "$remaining_fraction" ] && [ -z "$balance" ]; then
    printf 'unknown\tomp usage vercel-ai-gateway reported no balance/remaining field (authorized trial allowance unproven)\t%s\n' "$ts"
    return 0
  fi
  if [ -n "$remaining_fraction" ] && awk -v r="$remaining_fraction" 'BEGIN{exit !(r<=0)}' 2>/dev/null; then
    printf 'exhausted\tvercel-ai-gateway remaining fraction at or below zero\t%s\n' "$ts"
    return 0
  fi
  if [ -n "$balance" ] && awk -v b="$balance" 'BEGIN{exit !(b<=0)}' 2>/dev/null; then
    printf 'exhausted\tvercel-ai-gateway balance at or below zero\t%s\n' "$ts"
    return 0
  fi
  printf 'eligible\tvercel-ai-gateway remaining %s (%s)\t%s\n' "${remaining_fraction:-$balance}" "${unit:-fraction}" "$ts"
}

# omp's generatedAt is epoch milliseconds; quota-axi's timestamps are already
# RFC3339. date(1) portability (BSD vs GNU) needs two different flag forms.
fm_route_ms_to_rfc3339() {
  local ms=$1 s
  s=$((ms / 1000))
  date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

fm_route_probe() {
  case "$1" in
    claude) fm_route_probe_claude ;;
    codex) fm_route_probe_codex ;;
    pi-grok) fm_route_probe_pi_grok ;;
    pi-deepseek) fm_route_probe_pi_deepseek ;;
    *) printf 'unknown\tno probe for route %s\t%s\n' "$1" "$(fm_route_now)" ;;
  esac
}

# ---- state store ------------------------------------------------------------
FM_ROUTE_CANONICAL_STATE_DIR="$ROUTE_CANONICAL_HOME/state"
FM_ROUTE_CANONICAL_CONFIG_DIR="$ROUTE_CANONICAL_HOME/config"
ROUTE_FILE="$FM_ROUTE_CANONICAL_STATE_DIR/route.json"
ROUTE_LOCK="$FM_ROUTE_CANONICAL_STATE_DIR/.route.lock"
ROUTE_DISABLED_FILE="$FM_ROUTE_CANONICAL_CONFIG_DIR/route-disabled"

# An absent store is a fresh one and gets the default document. An existing
# store that does not parse as this document's shape is NOT silently
# replaced: every caller feeds the result straight back into jq and writes
# the result, so returning corrupt bytes here would publish a destroyed
# store over a real one. Refuse instead and leave the file untouched for a
# human to inspect.
FM_ROUTE_CORRUPT_MESSAGE="state/route.json is corrupt or unparseable, refusing to overwrite it"
fm_route_read() {
  [ -f "$ROUTE_FILE" ] || { printf '{"generation":0,"routes":{},"assignments":{}}'; return 0; }
  jq -ce '
    if type == "object"
      and (.routes | type) == "object"
      and (.assignments | type) == "object"
      and (.routes | all(.[]; type == "object"))
      and (.assignments | all(.[]; type == "object"))
    then . else error("bad shape") end' \
    "$ROUTE_FILE" 2>/dev/null || return 1
}

fm_route_corrupt_text_error() {
  printf 'error: %s (%s)\n' "$FM_ROUTE_CORRUPT_MESSAGE" "$ROUTE_FILE" >&2
}

# The read side refuses corrupt bytes; this is the matching guard on the way
# out. Every caller builds its payload in a command substitution, which set -e
# does not abort on, so a failed jq leaves an empty string that would otherwise
# be published atomically over a real store.
fm_route_write() {
  local content=$1 tmp
  printf '%s' "$content" | jq -ce '
    if type == "object"
      and (.routes | type) == "object"
      and (.assignments | type) == "object"
      and (.routes | all(.[]; type == "object"))
      and (.assignments | all(.[]; type == "object"))
    then . else error("bad shape") end' >/dev/null 2>&1 || return 1
  mkdir -p "$FM_ROUTE_CANONICAL_STATE_DIR"
  tmp="$ROUTE_FILE.tmp.$$"
  printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$ROUTE_FILE" || { rm -f "$tmp"; return 1; }
}

fm_route_manual_disabled() {
  local r=$1
  [ -f "$ROUTE_DISABLED_FILE" ] || return 1
  grep -qxF "$r" "$ROUTE_DISABLED_FILE" 2>/dev/null
}

# An assignment's owner is abandoned when its recorded state/<owner>.meta no
# longer exists, or exists but its spawn_gen no longer matches the
# assignment's stored owner_generation (a relaunch created a new attempt).
# Elapsed time is never consulted. Returns 0 (abandoned) or 1 (still owned).
#
# Scope limit, stated plainly: only the meta-existence half runs for
# Firstmate's own current callers. The generation-mismatch half applies
# solely to a caller that passes an owner.generation in fm-spawn.sh's
# spawn_gen shape ("s<epoch>.<pid>.<random>"), the only value directly
# comparable to a meta's spawn_gen= line. fm-spawn.sh's route acquire runs
# long before it assigns SPAWN_GEN and fm-control.sh's relaunch mints its own
# "r"-shaped token, so both are pure freshness markers today and neither
# reaches the mismatch branch. The branch stays for the separate native
# no-mistakes integration, which can pass a comparable shape.
#
# Accepted limit on fresh-spawn fairness: fm-spawn.sh acquires its route long
# before it writes state/<id>.meta, since that write follows worktree creation,
# the git fetch, config inheritance, and the launch. An in-flight spawn with no
# meta yet reads as abandoned here, so it is not counted against its route's
# pending total for that window, and a burst of concurrent fresh spawns can
# skew toward one route until each meta lands. Deliberate narrowing, not a
# defect: fewest-pending is exact for settled assignments, approximate for
# in-flight ones.
fm_route_owner_abandoned() {
  local owner=$1 owner_gen=$2 meta spawn_gen
  meta="$FM_ROUTE_CANONICAL_STATE_DIR/$owner.meta"
  [ -f "$meta" ] || return 0
  spawn_gen=$(sed -n 's/^spawn_gen=//p' "$meta" | head -n 1)
  # A caller-supplied owner_generation that does not look like fm-spawn's own
  # spawn_gen shape (relaunch-style tokens, e.g. "rTIMESTAMP.PID.RANDOM") is
  # never compared against spawn_gen: only Firstmate's own fm-spawn.sh writes
  # a directly-comparable value, and other callers' generation is a pure
  # freshness marker with no meta counterpart to reconcile against.
  case "$owner_gen" in
    s*.*.*) : ;;
    *) return 1 ;;
  esac
  [ -n "$spawn_gen" ] || return 1
  [ "$spawn_gen" = "$owner_gen" ] && return 1
  return 0
}

# ---- commands ---------------------------------------------------------------

cmd_refresh() {
  local doc gen r state reason ts routes_json manual
  fm_lock_acquire_wait "$ROUTE_LOCK"
  doc=$(fm_route_read) || {
    fm_lock_release "$ROUTE_LOCK"
    fm_route_corrupt_text_error
    return 6
  }
  gen=$(printf '%s' "$doc" | jq -r '.generation // 0')
  gen=$((gen + 1))
  routes_json='{}'
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    IFS=$'\t' read -r state reason ts < <(fm_route_probe "$r")
    if fm_route_manual_disabled "$r"; then
      manual=true
    else
      manual=false
    fi
    routes_json=$(jq -c --arg r "$r" --arg state "$state" --arg reason "$reason" --arg ts "$ts" --argjson manual "$manual" \
      '.[$r] = {state:$state, reason:$reason, observedAt:$ts, manualDisabled:$manual}' <<<"$routes_json")
  done < <(fm_route_ids_from_config)
  doc=$(jq -c --argjson gen "$gen" --argjson routes "$routes_json" '.generation=$gen | .routes=$routes' <<<"$doc")
  fm_route_write "$doc" || {
    fm_lock_release "$ROUTE_LOCK"
    fm_route_corrupt_text_error
    return 6
  }
  fm_lock_release "$ROUTE_LOCK"
  printf 'refreshed generation=%s\n' "$gen"
}

cmd_status() {
  local want=$1 doc
  doc=$(fm_route_read) || { fm_route_corrupt_text_error; return 6; }
  if [ -n "$want" ]; then
    jq -r --arg r "$want" '
      .routes[$r] as $x
      | if $x == null then "route=\($r) state=unknown reason=\"never refreshed\""
        else "route=\($r) state=\($x.state) manual_disabled=\($x.manualDisabled) reason=\"\($x.reason)\" observed_at=\($x.observedAt)"
        end
    ' <<<"$doc"
  else
    jq -r '
      .routes | to_entries[] |
      "route=\(.key) state=\(.value.state) manual_disabled=\(.value.manualDisabled) reason=\"\(.value.reason)\" observed_at=\(.value.observedAt)"
    ' <<<"$doc"
  fi
}

cmd_disable() {
  local r=$1
  mkdir -p "$FM_ROUTE_CANONICAL_CONFIG_DIR"
  fm_lock_acquire_wait "$ROUTE_LOCK"
  touch "$ROUTE_DISABLED_FILE"
  if ! grep -qxF "$r" "$ROUTE_DISABLED_FILE" 2>/dev/null; then
    printf '%s\n' "$r" >> "$ROUTE_DISABLED_FILE"
  fi
  fm_lock_release "$ROUTE_LOCK"
  printf 'disabled route=%s\n' "$r"
}

cmd_enable() {
  local r=$1 tmp
  fm_lock_acquire_wait "$ROUTE_LOCK"
  if [ -f "$ROUTE_DISABLED_FILE" ]; then
    tmp="$ROUTE_DISABLED_FILE.tmp.$$"
    grep -vxF "$r" "$ROUTE_DISABLED_FILE" > "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$ROUTE_DISABLED_FILE"
  fi
  fm_lock_release "$ROUTE_LOCK"
  printf 'enabled route=%s\n' "$r"
}

fm_route_json_error() {  # <message>
  jq -cn --arg msg "$1" '{result:"error", error:$msg}'
}

# Read one request field that the protocol declares a string, and fail unless
# it really is a non-empty string. Without the type check `jq -r` happily
# renders an object or array as its pretty-printed text, so a malformed
# request would flow on as a plausible-looking identifier instead of being
# refused at the boundary.
fm_route_req_string() {  # <request-json> <jq-path>
  jq -er "$2 | if type == \"string\" and length > 0 then . else empty end" <<<"$1" 2>/dev/null
}

# Same idea for the routes list: it must be a JSON array of non-empty strings.
# A bare string would otherwise pass a `length` check as a character count and
# then crash the route-id validation loop mid-iteration.
fm_route_req_id_array() {  # <request-json>
  jq -ec '.routes
    | if type == "array" and length > 0 and (all(.[]; type == "string" and length > 0))
      then . else empty end' <<<"$1" 2>/dev/null
}

# Eligible-for-selection means: manually disabled routes are dropped first
# (effective immediately, not waiting for refresh); the last refresh's
# recorded state must be "eligible"; and a route finish's immediate
# exclusion (recorded directly on route state by cmd_finish, see below)
# overrides a stale "eligible" reading from before that finish, evaluated
# fresh at THIS call.
cmd_acquire() {
  local req=$1
  local assignment owner_identity owner_gen routes_json doc gen r best_count count
  local existing existing_owner existing_status state
  local has_unknown=0 reasons="" abandoned
  local -a tied_routes best_route

  assignment=$(fm_route_req_string "$req" '.assignment_id') \
    || { fm_route_json_error "assignment_id is required, as a non-empty string"; return 1; }
  owner_identity=$(fm_route_req_string "$req" '.owner.identity') \
    || { fm_route_json_error "owner.identity is required, as a non-empty string"; return 1; }
  owner_gen=$(fm_route_req_string "$req" '.owner.generation') \
    || { fm_route_json_error "owner.generation is required, as a non-empty string"; return 1; }
  routes_json=$(fm_route_req_id_array "$req") \
    || { fm_route_json_error "routes must be a non-empty array of route id strings"; return 1; }
  while IFS= read -r r; do
    fm_route_is_known "$r" || { fm_route_json_error "unknown route id: $r"; return 1; }
  done < <(jq -r '.[]' <<<"$routes_json")

  fm_lock_acquire_wait "$ROUTE_LOCK"
  doc=$(fm_route_read) || {
    fm_lock_release "$ROUTE_LOCK"
    fm_route_json_error "$FM_ROUTE_CORRUPT_MESSAGE"
    return 1
  }
  gen=$(printf '%s' "$doc" | jq -r '.generation // 0')

  existing=$(jq -c --arg a "$assignment" '.assignments[$a] // empty' <<<"$doc")
  if [ -n "$existing" ]; then
    existing_owner=$(jq -r '.owner' <<<"$existing")
    existing_status=$(jq -r '.status' <<<"$existing")
    if [ "$existing_owner" != "$owner_identity" ]; then
      fm_lock_release "$ROUTE_LOCK"
      fm_route_json_error "assignment $assignment is already owned by a different owner"
      return 1
    fi
    if [ "$existing_status" != deferred ]; then
      fm_lock_release "$ROUTE_LOCK"
      if [ "$existing_status" = closed ]; then
        # A closed record is history, never a reusable slot: it carries no
        # route_id at all, so no caller keying on route_id can mistake this
        # echo for an authorization. A genuinely new attempt needs a new
        # assignment id.
        jq -cn --argjson gen "$gen" --arg a "$assignment" \
          '{result:"already-closed", assignment_id:$a, generation:$gen, note:"already closed; not relaunched"}'
      else
        jq -cn --argjson gen "$gen" \
          --arg route "$(jq -r '.route' <<<"$existing")" --arg reason "$(jq -r '.reason' <<<"$existing")" \
          '{result:"selected", route_id:$route, reason:$reason, generation:$gen}'
      fi
      return 0
    fi
    # deferred: fall through and re-evaluate fresh below.
  fi

  tied_routes=()
  best_count=
  while IFS= read -r r; do
    state=$(jq -r --arg r "$r" '.routes[$r].state // "unknown"' <<<"$doc")
    # Read config/route-disabled directly (never the document's own stored
    # manualDisabled snapshot, which only refresh keeps current): a manual
    # disable/enable must take effect immediately, without waiting for the
    # next refresh tick.
    if fm_route_manual_disabled "$r"; then continue; fi
    if [ "$state" != eligible ]; then
      [ "$state" != unknown ] || has_unknown=1
      continue
    fi
    count=0
    # The "pending" half of the status filter below is not written by any
    # current path (acquire writes running/deferred, finish writes closed);
    # it is harmless and kept for a future async-acquire state.
    while IFS=$'\t' read -r a_owner a_owner_gen; do
      [ -n "$a_owner" ] || continue
      abandoned=0
      fm_route_owner_abandoned "$a_owner" "$a_owner_gen" && abandoned=1
      [ "$abandoned" -eq 1 ] || count=$((count + 1))
    done < <(jq -r --arg r "$r" '
      .assignments | to_entries[] | select(.value.route == $r and (.value.status == "pending" or .value.status == "running"))
      | [.value.owner, .value.ownerGeneration] | @tsv
    ' <<<"$doc")
    if [ -z "$best_count" ] || [ "$count" -lt "$best_count" ]; then
      best_count=$count
      tied_routes=("$r")
    elif [ "$count" -eq "$best_count" ]; then
      tied_routes+=("$r")
    fi
  done < <(jq -r '.[]' <<<"$routes_json")

  # Rotate genuinely across successive selections (including within a
  # concurrent burst, since every acquire is serialized by ROUTE_LOCK): a
  # monotonic cursor lives on the document itself, advances by one on every
  # tie-broken pick, and indexes into the tied set with modulo -- never
  # always the first-scanned candidate.
  best_route=
  if [ "${#tied_routes[@]}" -gt 0 ]; then
    local cursor pick_index
    cursor=$(printf '%s' "$doc" | jq -r '.tieCursor // 0')
    pick_index=$((cursor % ${#tied_routes[@]}))
    best_route=${tied_routes[$pick_index]}
    doc=$(jq -c --argjson cursor "$((cursor + 1))" '.tieCursor = $cursor' <<<"$doc")
  fi

  if [ -z "$best_route" ]; then
    if [ "$has_unknown" -eq 1 ]; then
      reasons="no route proven eligible; at least one candidate has unknown telemetry"
    else
      reasons="every candidate route is excluded (exhausted, outage, auth-failed, or manually disabled)"
    fi
    doc=$(jq -c --arg a "$assignment" --arg owner "$owner_identity" --arg gen "$owner_gen" --arg reason "$reasons" \
      '.assignments[$a] = {owner:$owner, ownerGeneration:$gen, status:"deferred", route:null, reason:$reason}' <<<"$doc")
    fm_route_write "$doc" || {
      fm_lock_release "$ROUTE_LOCK"
      fm_route_json_error "$FM_ROUTE_CORRUPT_MESSAGE"
      return 1
    }
    fm_lock_release "$ROUTE_LOCK"
    jq -cn --argjson gen "$gen" --arg reason "$reasons" '{result:"deferred", reason:$reason, generation:$gen}'
    return 0
  fi

  doc=$(jq -c --arg a "$assignment" --arg owner "$owner_identity" --arg gen "$owner_gen" --arg route "$best_route" \
    '.assignments[$a] = {owner:$owner, ownerGeneration:$gen, status:"running", route:$route, reason:"fewest-pending"}' <<<"$doc")
  fm_route_write "$doc" || {
    fm_lock_release "$ROUTE_LOCK"
    fm_route_json_error "$FM_ROUTE_CORRUPT_MESSAGE"
    return 1
  }
  fm_lock_release "$ROUTE_LOCK"
  jq -cn --argjson gen "$gen" --arg route "$best_route" \
    '{result:"selected", route_id:$route, reason:"fewest-pending", generation:$gen}'
}

cmd_finish() {
  local req=$1
  local assignment outcome profile doc existing route
  assignment=$(fm_route_req_string "$req" '.assignment_id') \
    || { fm_route_json_error "assignment_id is required, as a non-empty string"; return 1; }
  outcome=$(fm_route_req_string "$req" '.outcome') || outcome=
  profile=$(jq -c '.profile // empty' <<<"$req" 2>/dev/null) || profile=

  case "$outcome" in
    success|launch-failed|auth-failed|exhausted|outage) : ;;
    *) fm_route_json_error "outcome must be one of success, launch-failed, auth-failed, exhausted, outage"; return 1 ;;
  esac

  fm_lock_acquire_wait "$ROUTE_LOCK"
  doc=$(fm_route_read) || {
    fm_lock_release "$ROUTE_LOCK"
    fm_route_json_error "$FM_ROUTE_CORRUPT_MESSAGE"
    return 1
  }
  existing=$(jq -c --arg a "$assignment" '.assignments[$a] // empty' <<<"$doc")
  if [ -z "$existing" ] || [ "$(jq -r '.status' <<<"$existing")" = closed ]; then
    fm_lock_release "$ROUTE_LOCK"
    jq -cn --arg a "$assignment" '{result:"closed", assignment_id:$a}'
    return 0
  fi
  route=$(jq -r '.route // empty' <<<"$existing")

  doc=$(jq -c --arg a "$assignment" --arg outcome "$outcome" --argjson profile "${profile:-null}" \
    '.assignments[$a].status = "closed" | .assignments[$a].outcome = $outcome
     | (if $profile != null then .assignments[$a].profile = $profile else . end)' <<<"$doc")

  # A failure outcome is verified evidence against its route: exclude it
  # immediately, without waiting for refresh's next probe tick. refresh
  # later corroborates or clears it against fresh evidence; only that
  # verified fresh success clears the exclusion, never a timer alone.
  case "$outcome" in
    auth-failed|exhausted|outage)
      if [ -n "$route" ]; then
        local state_name
        case "$outcome" in
          auth-failed) state_name=auth-failed ;;
          exhausted) state_name=exhausted ;;
          outage) state_name=outage ;;
        esac
        doc=$(jq -c --arg r "$route" --arg state "$state_name" --arg ts "$(fm_route_now)" \
          '.routes[$r] = ((.routes[$r] // {}) + {state:$state, reason:("finish recorded " + $state), observedAt:$ts, manualDisabled:((.routes[$r].manualDisabled) // false)})' <<<"$doc")
      fi
      ;;
  esac

  fm_route_write "$doc" || {
    fm_lock_release "$ROUTE_LOCK"
    fm_route_json_error "$FM_ROUTE_CORRUPT_MESSAGE"
    return 1
  }
  fm_lock_release "$ROUTE_LOCK"
  jq -cn --arg a "$assignment" '{result:"closed", assignment_id:$a}'
}

# ---- argument parsing ---------------------------------------------------

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
SUBCOMMAND=$1
shift

ROUTE_ID=
GROUP_HARNESS=
GROUP_MODEL=
ROUTE_CLASS=
want_value=

for arg in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      route) ROUTE_ID=$arg ;;
      harness) GROUP_HARNESS=$arg ;;
      model) GROUP_MODEL=$arg ;;
      class) ROUTE_CLASS=$arg ;;
    esac
    want_value=
    continue
  fi
  case "$arg" in
    --route) want_value=route ;;
    --route=*) ROUTE_ID=${arg#--route=} ;;
    --harness) want_value=harness ;;
    --harness=*) GROUP_HARNESS=${arg#--harness=} ;;
    --model) want_value=model ;;
    --model=*) GROUP_MODEL=${arg#--model=} ;;
    --class) want_value=class ;;
    --class=*) ROUTE_CLASS=${arg#--class=} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

case "$SUBCOMMAND" in
  refresh)
    cmd_refresh
    ;;
  status)
    cmd_status "$ROUTE_ID"
    ;;
  routes)
    fm_route_ids_from_config "$ROUTE_CLASS"
    ;;
  group-for)
    [ -n "$GROUP_HARNESS" ] || { echo "error: --harness is required" >&2; exit 2; }
    fm_route_group_for "$GROUP_HARNESS" "${GROUP_MODEL:-default}"
    ;;
  disable)
    [ -n "$ROUTE_ID" ] || { echo "error: --route is required" >&2; exit 2; }
    fm_route_is_known "$ROUTE_ID" || { echo "error: unknown route id: $ROUTE_ID" >&2; exit 2; }
    cmd_disable "$ROUTE_ID"
    ;;
  enable)
    [ -n "$ROUTE_ID" ] || { echo "error: --route is required" >&2; exit 2; }
    fm_route_is_known "$ROUTE_ID" || { echo "error: unknown route id: $ROUTE_ID" >&2; exit 2; }
    cmd_enable "$ROUTE_ID"
    ;;
  acquire)
    REQUEST_BODY=$(cat) || { echo "error: could not read acquire request from stdin" >&2; exit 2; }
    REQUEST_JSON=$(jq -c '.' <<<"$REQUEST_BODY" 2>/dev/null) || { fm_route_json_error "request body is not valid JSON"; exit 1; }
    RESULT=$(cmd_acquire "$REQUEST_JSON") || { printf '%s\n' "$RESULT"; exit 1; }
    printf '%s\n' "$RESULT"
    ;;
  finish)
    REQUEST_BODY=$(cat) || { echo "error: could not read finish request from stdin" >&2; exit 2; }
    REQUEST_JSON=$(jq -c '.' <<<"$REQUEST_BODY" 2>/dev/null) || { fm_route_json_error "request body is not valid JSON"; exit 1; }
    RESULT=$(cmd_finish "$REQUEST_JSON") || { printf '%s\n' "$RESULT"; exit 1; }
    printf '%s\n' "$RESULT"
    ;;
  *)
    echo "error: unknown subcommand: $SUBCOMMAND" >&2
    usage >&2
    exit 2
    ;;
esac
