#!/usr/bin/env bash
# tests/fm-api.test.sh - localhost API front door: health, bind, config, lifecycle,
# the fleet snapshot read, write token, captain notes, worker relays, decision answers, and rung toggles.
#
# Speaks real HTTP against a throwaway firstmate home. Does not read the live
# home and does not inspect server source.
set -u

# shellcheck source=tests/api-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/api-helpers.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
node -e 'process.stdout.write("fm-api-node-ok")' >/dev/null 2>&1 \
  || { echo "skip: node is not a usable Node.js"; exit 0; }

split_http() {
  # stdin: "<status>\n<body>" -> sets HTTP_CODE and HTTP_BODY
  HTTP_CODE=
  HTTP_BODY=
  IFS= read -r HTTP_CODE || true
  HTTP_BODY=$(cat)
}

write_fleet_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-07-07)

## Queued
- [ ] queued-task - Queued Task (repo: alpha) (kind: ship) (since 2026-07-08)

## Done
- [x] done-task - Done Task (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha" \
    "project=alpha" \
    "harness=claude" \
    "model=claude-opus-4-8" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: implementing the snapshot\n' > "$home/state/ship-task.status"
}

json_query() {  # <json> <node-expr> - print one JSON.stringify of the expr, or exit 1
  JSON=$1 EXPR=$2 node -e '
const d = JSON.parse(process.env.JSON);
let v;
try { v = new Function("d", "return (" + process.env.EXPR + ");")(d); } catch { process.exit(1); }
if (v === undefined) process.exit(1);
process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));
'
}

strip_snapshot_times() {
  node -e '
function strip(v) {
  if (Array.isArray(v)) return v.map(strip);
  if (v && typeof v === "object") {
    const out = {};
    for (const [k, val] of Object.entries(v)) {
      // enrich is the one documented API addition on top of the snapshot
      // script output; the dedicated enrich test covers it.
      if (k === "generated" || k === "observed_at" || k === "enrich") continue;
      out[k] = strip(val);
    }
    return out;
  }
  return v;
}
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  process.stdout.write(JSON.stringify(strip(JSON.parse(raw))));
});
'
}

test_empty_home_fleet_is_empty_not_error() {
  local home port resp schema ntasks nrecords
  home=$(fm_test_api_home api-fleet-empty)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /fleet GET 10000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "empty fleet status $HTTP_CODE, wanted 200: $HTTP_BODY"
  schema=$(fm_test_json_field "$HTTP_BODY" schema) || fail "empty fleet missing schema: $HTTP_BODY"
  [ "$schema" = "fm-fleet-snapshot.v1" ] || fail "empty fleet schema $schema"
  ntasks=$(json_query "$HTTP_BODY" 'd.tasks.length') || fail "empty fleet missing tasks: $HTTP_BODY"
  nrecords=$(json_query "$HTTP_BODY" 'd.backlog.records.length') || fail "empty fleet missing backlog.records: $HTTP_BODY"
  [ "$ntasks" = 0 ] || fail "empty fleet tasks length $ntasks, wanted 0"
  [ "$nrecords" = 0 ] || fail "empty fleet backlog.records length $nrecords, wanted 0"
  fm_test_api_stop "$home"
  pass "empty home answers with an empty fleet, not an error"
}

test_fleet_snapshot_for_fixture_home() {
  local home port resp schema served ids states stages status
  home=$(fm_test_api_home api-fleet-fixture)
  write_fleet_fixture "$home"
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /fleet GET 10000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "fixture fleet status $HTTP_CODE, wanted 200: $HTTP_BODY"
  schema=$(fm_test_json_field "$HTTP_BODY" schema) || fail "fixture fleet missing schema: $HTTP_BODY"
  [ "$schema" = "fm-fleet-snapshot.v1" ] || fail "fixture fleet schema $schema"
  served=$(fm_test_json_field "$HTTP_BODY" fm_home) || fail "fixture fleet missing fm_home: $HTTP_BODY"
  [ "$served" = "$(cd "$home" && pwd)" ] || fail "fixture fleet fm_home $served"
  ids=$(json_query "$HTTP_BODY" 'd.tasks.map(t => t.id)') || fail "fixture fleet missing tasks: $HTTP_BODY"
  assert_contains "$ids" '"ship-task"' "fixture fleet tasks: $ids"
  status=$(json_query "$HTTP_BODY" 'd.tasks.find(t => t.id === "ship-task").current_state.state') \
    || fail "fixture fleet missing current_state.state: $HTTP_BODY"
  [ -n "$status" ] || fail "fixture fleet status was empty"
  states=$(json_query "$HTTP_BODY" 'd.backlog.records.map(r => r.state)') \
    || fail "fixture fleet missing backlog stages: $HTTP_BODY"
  assert_contains "$states" '"in_flight"' "fixture fleet stages: $states"
  assert_contains "$states" '"queued"' "fixture fleet stages: $states"
  assert_contains "$states" '"done"' "fixture fleet stages: $states"
  stages=$(json_query "$HTTP_BODY" 'd.tasks.find(t => t.id === "ship-task").current_state') \
    || fail "fixture fleet missing current_state: $HTTP_BODY"
  assert_contains "$stages" '"state"' "fixture fleet current_state: $stages"
  fm_test_api_stop "$home"
  pass "GET /fleet returns tasks, statuses, and stages for a fixture home"
}

test_fleet_body_matches_snapshot_script() {
  local home port resp script served api_stripped script_stripped
  home=$(fm_test_api_home api-fleet-agree)
  write_fleet_fixture "$home"
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /fleet GET 10000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "agree fleet status $HTTP_CODE, wanted 200: $HTTP_BODY"
  served=$(fm_test_json_field "$HTTP_BODY" fm_home) || fail "agree fleet missing fm_home: $HTTP_BODY"
  script=$(FM_HOME="$served" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fm-fleet-snapshot.sh --json failed"
  api_stripped=$(printf '%s' "$HTTP_BODY" | strip_snapshot_times) \
    || fail "API fleet body was not JSON: $HTTP_BODY"
  script_stripped=$(printf '%s' "$script" | strip_snapshot_times) \
    || fail "snapshot script body was not JSON"
  [ "$api_stripped" = "$script_stripped" ] \
    || fail "GET /fleet disagreed with fm-fleet-snapshot.sh --json for $served"
  fm_test_api_stop "$home"
  pass "GET /fleet matches firstmate's own snapshot script"
}

test_fleet_rejects_non_get() {
  local home port resp
  home=$(fm_test_api_home api-fleet-post)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /fleet POST 2000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 405 ] || fail "POST /fleet status $HTTP_CODE, wanted 405: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "POST /fleet is method not allowed"
}

test_health_reports_version_and_home() {
  local home port resp version served
  home=$(fm_test_api_home api-health)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "health status $HTTP_CODE, wanted 200: $HTTP_BODY"
  version=$(fm_test_json_field "$HTTP_BODY" version) \
    || fail "health body missing version: $HTTP_BODY"
  served=$(fm_test_json_field "$HTTP_BODY" home) \
    || fail "health body missing home: $HTTP_BODY"
  [ "$version" = 1 ] || fail "health version $version, wanted 1"
  [ "$served" = "$(cd "$home" && pwd)" ] || fail "health home $served, wanted $(cd "$home" && pwd)"
  fm_test_api_stop "$home"
  pass "health reports version and the served throwaway home"
}

test_unknown_path_is_not_found() {
  local home port resp
  home=$(fm_test_api_home api-404)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 404 ] || fail "root status $HTTP_CODE, wanted 404"
  fm_test_api_stop "$home"
  pass "unknown paths return 404"
}

test_binds_localhost_only() {
  local home port resp other
  home=$(fm_test_api_home api-localhost)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "127.0.0.1 health failed: $HTTP_CODE $HTTP_BODY"
  if other=$(fm_test_non_loopback_ipv4); then
    node -e '
const http = require("http");
const host = process.argv[1];
const port = process.argv[2];
const req = http.get({ host, port, path: "/health" }, (res) => {
  process.stdout.write(String(res.statusCode));
  res.resume();
});
req.on("error", () => process.stdout.write("0\n"));
req.setTimeout(2000, () => {
  req.destroy();
  process.stdout.write("0\n");
});
' "$other" "$port" | grep -qx 0 \
      || fail "API answered on non-loopback $other:$port"
  fi
  fm_test_api_stop "$home"
  pass "server answers on 127.0.0.1 and not on a non-loopback address"
}

test_port_and_home_come_from_config() {
  local home port requested n out bound served resp
  home=$(fm_test_api_home api-config)
  n=0
  requested=
  bound=
  while [ "$n" -lt 8 ]; do
    requested=$((20000 + RANDOM % 20000))
    printf '%s\n' "$requested" > "$home/config/api-port"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start 2>&1) || out=
    if [ -f "$home/state/.api.port" ]; then
      FM_TEST_API_HOMES+=("$home")
      bound=$(cat "$home/state/.api.port")
      [ "$bound" = "$requested" ] && break
      FM_HOME="$home" "$ROOT/bin/fm-api.sh" stop >/dev/null 2>&1 || true
      bound=
    fi
    n=$((n + 1))
  done
  [ "$bound" = "$requested" ] || fail "could not bind a configured port (last: $out)"
  resp=$(fm_test_api_http "$bound" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "configured-port health $HTTP_CODE"
  served=$(fm_test_json_field "$HTTP_BODY" home)
  [ "$served" = "$(cd "$home" && pwd)" ] || fail "served home was $served"
  case "$served" in
    "$ROOT"|"$ROOT"/*) fail "health home used the repo path instead of the throwaway home: $served" ;;
  esac
  fm_test_api_stop "$home"
  pass "port and home come from firstmate config, not hardcoded paths"
}

test_two_homes_do_not_share_a_server() {
  local home_a home_b port_a port_b served_a served_b resp
  home_a=$(fm_test_api_home api-home-a)
  home_b=$(fm_test_api_home api-home-b)
  port_a=$(fm_test_api_start "$home_a")
  port_b=$(fm_test_api_start "$home_b")
  [ "$port_a" != "$port_b" ] || fail "two homes bound the same port $port_a"
  resp=$(fm_test_api_http "$port_a" /health)
  split_http <<<"$resp"
  served_a=$(fm_test_json_field "$HTTP_BODY" home)
  resp=$(fm_test_api_http "$port_b" /health)
  split_http <<<"$resp"
  served_b=$(fm_test_json_field "$HTTP_BODY" home)
  [ "$served_a" = "$(cd "$home_a" && pwd)" ] || fail "home A served $served_a"
  [ "$served_b" = "$(cd "$home_b" && pwd)" ] || fail "home B served $served_b"
  [ "$served_a" != "$served_b" ] || fail "both homes reported the same home"
  fm_test_api_stop "$home_a"
  fm_test_api_stop "$home_b"
  pass "each throwaway home gets its own API"
}

test_start_stop_lifecycle() {
  local home port resp status
  home=$(fm_test_api_home api-lifecycle)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "start did not bring health up: $HTTP_CODE"
  status=$(FM_HOME="$home" "$ROOT/bin/fm-api.sh" status)
  assert_contains "$status" "api: running" "status after start: $status"
  fm_test_api_stop "$home"
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 0 ] || fail "stop left health answering: $HTTP_CODE $HTTP_BODY"
  status=$(FM_HOME="$home" "$ROOT/bin/fm-api.sh" status)
  assert_contains "$status" "api: stopped" "status after stop: $status"
  pass "start brings the API up and stop takes it down"
}

test_start_is_idempotent() {
  local home port first second
  home=$(fm_test_api_home api-attach)
  port=$(fm_test_api_start "$home")
  first=$(cat "$home/state/.api.pid")
  second=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start 2>&1) || \
    fail "second start failed: $second"
  assert_contains "$second" "api: attached" "second start did not attach: $second"
  [ "$(cat "$home/state/.api.pid")" = "$first" ] || fail "second start replaced the pid"
  fm_test_api_stop "$home"
  pass "start attaches when the API is already running"
}

test_start_replaces_server_when_lock_holder_changes() {
  local home port first second out resp holder_a holder_b
  home=$(fm_test_api_home api-session-replace)
  sleep 60 &
  holder_a=$!
  printf '%s\n' "$holder_a" > "$home/state/.lock"
  port=$(fm_test_api_start "$home")
  first=$(cat "$home/state/.api.pid")
  sleep 60 &
  holder_b=$!
  printf '%s\n' "$holder_b" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start 2>&1) || \
    fail "start under a new lock holder failed: $out"
  assert_contains "$out" "api: started" "start under a new lock holder should not attach: $out"
  second=$(cat "$home/state/.api.pid")
  [ "$second" != "$first" ] || fail "start reused the previous session's pid $first"
  [ "$(cat "$home/state/.api.session-pid")" = "$holder_b" ] || \
    fail "recorded session pid was $(cat "$home/state/.api.session-pid"), wanted $holder_b"
  port=$(cat "$home/state/.api.port")
  kill "$holder_a" 2>/dev/null || true
  wait "$holder_a" 2>/dev/null || true
  sleep 2.5
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "API went down after the previous session pid died: $HTTP_CODE $HTTP_BODY"
  fm_test_api_stop "$home"
  kill "$holder_b" 2>/dev/null || true
  wait "$holder_b" 2>/dev/null || true
  pass "start replaces a server that belongs to another lock holder"
}

test_api_stays_up_when_lock_holder_is_replaced() {
  local home port resp holder_a holder_b i
  home=$(fm_test_api_home api-lock-watch)
  sleep 60 &
  holder_a=$!
  printf '%s\n' "$holder_a" > "$home/state/.lock"
  port=$(fm_test_api_start "$home")
  sleep 60 &
  holder_b=$!
  printf '%s\n' "$holder_b" > "$home/state/.lock"
  kill "$holder_a" 2>/dev/null || true
  wait "$holder_a" 2>/dev/null || true
  i=0
  while [ "$i" -lt 20 ]; do
    resp=$(fm_test_api_http "$port" /health)
    split_http <<<"$resp"
    [ "$HTTP_CODE" = 200 ] || fail "API exited while a new lock holder was live: $HTTP_CODE $HTTP_BODY"
    sleep 0.2
    i=$((i + 1))
  done
  kill "$holder_b" 2>/dev/null || true
  wait "$holder_b" 2>/dev/null || true
  i=0
  while [ "$i" -lt 40 ]; do
    resp=$(fm_test_api_http "$port" /health)
    split_http <<<"$resp"
    [ "$HTTP_CODE" = 0 ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ "$HTTP_CODE" = 0 ] || fail "API still answered after no live lock holder remained"
  pass "API stays up while state/.lock names a live holder"
}

test_malformed_url_returns_400_and_keeps_serving() {
  local home port resp
  home=$(fm_test_api_home api-bad-url)
  port=$(fm_test_api_start "$home")
  resp=$(node -e '
const net = require("net");
const port = Number(process.argv[1]);
const sock = net.connect(port, "127.0.0.1", () => {
  sock.write("GET //[ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
});
const chunks = [];
sock.on("data", (c) => chunks.push(c));
sock.on("error", () => {
  process.stdout.write("0\n");
  process.exit(0);
});
sock.on("end", () => {
  const text = Buffer.concat(chunks).toString("utf8");
  const nl = text.indexOf("\r\n");
  const statusLine = nl === -1 ? text : text.slice(0, nl);
  const parts = statusLine.split(" ");
  process.stdout.write((parts[1] || "0") + "\n");
  const bodyAt = text.indexOf("\r\n\r\n");
  if (bodyAt !== -1) process.stdout.write(text.slice(bodyAt + 4));
});
' "$port")
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 400 ] || fail "malformed url status $HTTP_CODE, wanted 400: $HTTP_BODY"
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "server died after a malformed URL: $HTTP_CODE $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "malformed URL returns 400 and the server keeps serving"
}

test_api_exits_when_session_pid_dies() {
  local home port holder resp i
  home=$(fm_test_api_home api-session)
  sleep 60 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "API did not start under a live session pid"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  i=0
  while [ "$i" -lt 40 ]; do
    resp=$(fm_test_api_http "$port" /health)
    split_http <<<"$resp"
    [ "$HTTP_CODE" = 0 ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ "$HTTP_CODE" = 0 ] || fail "API still answered after the session pid died"
  pass "API exits when the session it was started under dies"
}

test_symlinked_api_port_refuses_start() {
  local home target out status
  home=$(fm_test_api_home api-port-symlink)
  FM_TEST_API_HOMES+=("$home")
  target="$home/config/api-port-real"
  printf '0\n' > "$target"
  rm -f "$home/config/api-port"
  ln -s "$target" "$home/config/api-port"
  status=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "start accepted a symlinked config/api-port: $out"
  assert_contains "$out" "must not be a symlink" "symlink refusal: $out"
  [ ! -f "$home/state/.api.pid" ] || fail "start recorded a pid after refusing a symlink"
  fm_test_api_stop "$home"
  pass "start refuses a symlinked config/api-port"
}

test_env_port_overrides_config() {
  local home port resp
  home=$(fm_test_api_home api-env-port)
  printf '65535\n' > "$home/config/api-port"
  FM_TEST_API_HOMES+=("$home")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_API_PORT=0 "$ROOT/bin/fm-api.sh" start >/dev/null \
    || fail "start with FM_API_PORT=0 failed"
  port=$(cat "$home/state/.api.port")
  [ "$port" != 65535 ] || fail "FM_API_PORT did not override config/api-port"
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "env-port health $HTTP_CODE"
  fm_test_api_stop "$home"
  pass "FM_API_PORT overrides config/api-port"
}

test_first_start_writes_token_later_starts_keep_it() {
  local home port first second mode
  home=$(fm_test_api_home api-token-gen)
  [ ! -f "$home/config/api-token" ] || fail "fixture home already had a write token"
  port=$(fm_test_api_start "$home")
  [ -f "$home/config/api-token" ] || fail "first start did not write config/api-token"
  first=$(fm_test_api_token "$home")
  [ "${#first}" -eq 64 ] || fail "generated token length ${#first}, wanted 64"
  mode=$(node -e 'const fs=require("fs"); process.stdout.write((fs.statSync(process.argv[1]).mode & 0o777).toString(8))' "$home/config/api-token")
  [ "$mode" = 600 ] || fail "token file mode $mode, wanted 600"
  fm_test_api_stop "$home"
  port=$(fm_test_api_start "$home")
  second=$(fm_test_api_token "$home")
  [ "$first" = "$second" ] || fail "later start rotated the write token"
  fm_test_api_stop "$home"
  pass "first start writes a write token and later starts keep it"
}

test_preexisting_token_is_kept() {
  local home port kept
  home=$(fm_test_api_home api-token-keep)
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    > "$home/config/api-token"
  port=$(fm_test_api_start "$home")
  kept=$(fm_test_api_token "$home")
  [ "$kept" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] \
    || fail "start replaced a preexisting write token"
  fm_test_api_stop "$home"
  pass "a preexisting write token survives start"
}

test_symlinked_api_token_refuses_start() {
  local home target out status
  home=$(fm_test_api_home api-token-symlink)
  FM_TEST_API_HOMES+=("$home")
  target="$home/config/api-token-real"
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$target"
  ln -s "$target" "$home/config/api-token"
  status=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "start accepted a symlinked config/api-token: $out"
  assert_contains "$out" "must not be a symlink" "token symlink refusal: $out"
  [ ! -f "$home/state/.api.pid" ] || fail "start recorded a pid after refusing a token symlink"
  fm_test_api_stop "$home"
  pass "start refuses a symlinked config/api-token"
}

test_captain_note_without_token_is_unauthorized() {
  local home port resp queue
  home=$(fm_test_api_home api-note-no-token)
  printf 'working: implementing\n' > "$home/state/sample-task.status"
  port=$(fm_test_api_start "$home")
  HTTP_BODY='{"task":"sample-task","text":"please go smaller"}' \
    resp=$(fm_test_api_http "$port" /captain-notes POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "missing token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  HTTP_BODY='{"task":"sample-task","text":"please go smaller"}' \
    HTTP_AUTHORIZATION='Bearer definitely-not-the-token' \
    resp=$(fm_test_api_http "$port" /captain-notes POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "wrong token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -z "$queue" ] || fail "unauthorized note still reached the wake queue: $queue"
  fm_test_api_stop "$home"
  pass "a captain note without the token is refused with 401"
}

test_captain_note_with_token_lands_in_wake_queue() {
  local home port token resp expected queue
  home=$(fm_test_api_home api-note-ok)
  printf 'working: implementing\n' > "$home/state/sample-task.status"
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  expected=$(printf '%s' 'captain-note on running task sample-task: please go smaller' \
    | "$ROOT/bin/fm-operational-input.sh" encode away-supervisor) \
    || fail "could not encode the expected captain note"
  HTTP_BODY='{"task":"sample-task","text":"please go smaller"}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /captain-notes POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "authorized note status $HTTP_CODE, wanted 200: $HTTP_BODY"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -n "$queue" ] || fail "authorized note did not reach the wake queue"
  printf '%s\n' "$queue" | grep -F "$expected" >/dev/null \
    || fail "wake queue missing the encoded captain note: $queue"
  printf '%s\n' "$queue" | grep -F 'check: captain-note:' >/dev/null \
    || fail "wake queue missing the captain-note check payload: $queue"
  printf '%s\n' "$queue" | awk -F '\t' '$3=="check" { found=1 } END { exit found?0:1 }' \
    || fail "wake queue did not record a check wake: $queue"
  fm_test_api_stop "$home"
  pass "a captain note with the token lands in the wake queue encoded for firstmate"
}

test_reads_need_no_token() {
  local home port token resp
  home=$(fm_test_api_home api-read-no-token)
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  [ -n "$token" ] || fail "start did not write a write token"
  resp=$(fm_test_api_http "$port" /health)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "health without token status $HTTP_CODE, wanted 200: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "reads still need no token after a write token exists"
}

test_question_back_note_does_not_close_a_hold() {
  local home port token resp before after queue
  home=$(fm_test_api_home api-note-question)
  printf 'needs-decision: which target? [key=deploy-target]\n' > "$home/state/sample-task.status"
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-task-decision-deploy-target - which target? (kind: captain)

## Done
EOF
  before=$(cat "$home/data/backlog.md")
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  HTTP_BODY='{"task":"sample-task","text":"what is this for?"}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /captain-notes POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "question-back note status $HTTP_CODE, wanted 200: $HTTP_BODY"
  after=$(cat "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "a question-back note rewrote the backlog"
  [ ! -f "$home/state/captain-replies.jsonl" ] \
    || fail "a captain note wrote state/captain-replies.jsonl"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  printf '%s\n' "$queue" | grep -F 'what is this for?' >/dev/null \
    || fail "question-back note did not reach firstmate: $queue"
  fm_test_api_stop "$home"
  pass "a clarifying question-back stays a captain note and does not close a hold"
}

# A crew-dispatch config with one class rig (two rungs, both on) and a default
# ladder (two rungs). Used by the rung-toggle tests below.
write_rung_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/config"
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {
      "when": "builder class: ordinary",
      "use": [
        { "harness": "codex", "model": "gpt-5.6", "effort": "high" },
        { "harness": "claude", "model": "opus", "effort": "high" }
      ]
    }
  ],
  "default": [
    { "harness": "codex", "model": "gpt-5.5", "effort": "medium" },
    { "harness": "pi", "model": "anthropic/claude-sonnet-5", "effort": "medium" }
  ]
}
EOF
}

test_worker_relay_without_token_is_unauthorized() {
  local home port resp queue
  home=$(fm_test_api_home api-relay-no-token)
  printf 'working: implementing\n' > "$home/state/sample-task.status"
  port=$(fm_test_api_start "$home")
  HTTP_BODY='{"task":"sample-task","text":"try the smaller batch first"}' \
    resp=$(fm_test_api_http "$port" /workers/relay POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "missing token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -z "$queue" ] || fail "unauthorized relay still reached the wake queue: $queue"
  fm_test_api_stop "$home"
  pass "relaying to a worker without the token is refused with 401"
}

test_worker_relay_with_token_lands_in_wake_queue() {
  local home port token resp expected queue
  home=$(fm_test_api_home api-relay-ok)
  printf 'working: implementing\n' > "$home/state/sample-task.status"
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  expected=$(printf '%s' 'captain-relay to worker sample-task: try the smaller batch first' \
    | "$ROOT/bin/fm-operational-input.sh" encode away-supervisor) \
    || fail "could not encode the expected relay"
  HTTP_BODY='{"task":"sample-task","text":"try the smaller batch first"}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /workers/relay POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "authorized relay status $HTTP_CODE, wanted 200: $HTTP_BODY"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -n "$queue" ] || fail "authorized relay did not reach the wake queue"
  printf '%s\n' "$queue" | grep -F "$expected" >/dev/null \
    || fail "wake queue missing the encoded relay: $queue"
  printf '%s\n' "$queue" | grep -F 'check: worker-relay:' >/dev/null \
    || fail "wake queue missing the worker-relay check payload: $queue"
  fm_test_api_stop "$home"
  pass "relaying to a worker with the token lands the steer on the wake queue for firstmate"
}

test_worker_relay_unknown_task_is_not_found() {
  local home port token resp
  home=$(fm_test_api_home api-relay-unknown)
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  HTTP_BODY='{"task":"ghost-task","text":"try the smaller batch first"}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /workers/relay POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 404 ] || fail "unknown-task relay status $HTTP_CODE, wanted 404: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "relaying to an unknown task is 404"
}

test_decision_answer_without_token_is_unauthorized() {
  local home port resp queue
  home=$(fm_test_api_home api-answer-no-token)
  printf 'needs-decision: which target? [key=deploy-target]\n' > "$home/state/sample-task.status"
  port=$(fm_test_api_start "$home")
  HTTP_BODY='{"task":"sample-task","key":"deploy-target","text":"ship to prod"}' \
    resp=$(fm_test_api_http "$port" /decisions/answer POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "missing token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  HTTP_BODY='{"task":"sample-task","key":"deploy-target","text":"ship to prod"}' \
    HTTP_AUTHORIZATION='Bearer definitely-not-the-token' \
    resp=$(fm_test_api_http "$port" /decisions/answer POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "wrong token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -z "$queue" ] || fail "unauthorized answer still reached the wake queue: $queue"
  fm_test_api_stop "$home"
  pass "answering a decision without the token is refused with 401"
}

test_decision_answer_with_token_lands_in_wake_queue() {
  local home port token resp expected queue
  home=$(fm_test_api_home api-answer-ok)
  printf 'needs-decision: which target? [key=deploy-target]\n' > "$home/state/sample-task.status"
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  expected=$(printf '%s' 'answer decision [key=deploy-target] on task sample-task with: ship to prod' \
    | "$ROOT/bin/fm-operational-input.sh" encode away-supervisor) \
    || fail "could not encode the expected answer"
  HTTP_BODY='{"task":"sample-task","key":"deploy-target","text":"ship to prod"}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /decisions/answer POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "authorized answer status $HTTP_CODE, wanted 200: $HTTP_BODY"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -n "$queue" ] || fail "authorized answer did not reach the wake queue"
  printf '%s\n' "$queue" | grep -F "$expected" >/dev/null \
    || fail "wake queue missing the encoded answer: $queue"
  printf '%s\n' "$queue" | grep -F 'check: decision-answer:' >/dev/null \
    || fail "wake queue missing the decision-answer check payload: $queue"
  printf '%s\n' "$queue" | awk -F '\t' '$3=="check" { found=1 } END { exit found?0:1 }' \
    || fail "wake queue did not record a check wake: $queue"
  fm_test_api_stop "$home"
  pass "answering a decision with the token lands the answer on the wake queue for firstmate"
}

test_decision_answer_unknown_task_is_not_found() {
  local home port token resp
  home=$(fm_test_api_home api-answer-unknown)
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  HTTP_BODY='{"task":"ghost-task","key":"deploy-target","text":"ship to prod"}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /decisions/answer POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 404 ] || fail "unknown-task answer status $HTTP_CODE, wanted 404: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "answering a decision on an unknown task is 404"
}

test_rung_toggle_without_token_is_unauthorized() {
  local home port resp before after
  home=$(fm_test_api_home api-rung-no-token)
  write_rung_fixture "$home"
  before=$(cat "$home/config/crew-dispatch.json")
  port=$(fm_test_api_start "$home")
  HTTP_BODY='{"rig":"builder class: ordinary","rung":1,"enabled":false}' \
    resp=$(fm_test_api_http "$port" /rigs/rung POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "missing token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  after=$(cat "$home/config/crew-dispatch.json")
  [ "$before" = "$after" ] || fail "unauthorized rung toggle rewrote the config"
  fm_test_api_stop "$home"
  pass "toggling a rung without the token is refused with 401"
}

test_rung_toggle_with_token_flips_enabled() {
  local home port token resp
  home=$(fm_test_api_home api-rung-ok)
  write_rung_fixture "$home"
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  HTTP_BODY='{"rig":"builder class: ordinary","rung":1,"enabled":false}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/rung POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "authorized rung off status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(node -e 'const c=require(process.argv[1]);process.stdout.write(String(c.rules[0].use[1].enabled))' \
      "$home/config/crew-dispatch.json")" = false ] \
    || fail "rung 1 was not turned off in the config"
  HTTP_BODY='{"rig":"builder class: ordinary","rung":1,"enabled":true}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/rung POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "authorized rung on status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(node -e 'const c=require(process.argv[1]);process.stdout.write(String("enabled" in c.rules[0].use[1]))' \
      "$home/config/crew-dispatch.json")" = false ] \
    || fail "turning a rung back on did not drop its enabled key"
  fm_test_api_stop "$home"
  pass "toggling a rung with the token flips its enabled state in the config"
}

test_rung_toggle_refuses_last_enabled_rung() {
  local home port token resp before after
  home=$(fm_test_api_home api-rung-last)
  write_rung_fixture "$home"
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  # Turn off rung 0 first so rung 1 is the last one on.
  HTTP_BODY='{"rig":"builder class: ordinary","rung":0,"enabled":false}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/rung POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "turning off rung 0 status $HTTP_CODE, wanted 200: $HTTP_BODY"
  before=$(cat "$home/config/crew-dispatch.json")
  HTTP_BODY='{"rig":"builder class: ordinary","rung":1,"enabled":false}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/rung POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 400 ] || fail "last-rung-off status $HTTP_CODE, wanted 400: $HTTP_BODY"
  printf '%s' "$HTTP_BODY" | grep -F 'last enabled rung' >/dev/null \
    || fail "last-rung-off error is not clear: $HTTP_BODY"
  after=$(cat "$home/config/crew-dispatch.json")
  [ "$before" = "$after" ] || fail "refused last-rung toggle still rewrote the config"
  fm_test_api_stop "$home"
  pass "a toggle that would turn off a ladder's last rung is refused with a clear error"
}

test_rig_config_without_token_is_unauthorized() {
  local home port resp before after
  home=$(fm_test_api_home api-config-no-token)
  write_rung_fixture "$home"
  before=$(cat "$home/config/crew-dispatch.json")
  port=$(fm_test_api_start "$home")
  HTTP_BODY='{"rules":[{"when":"x","use":[{"harness":"claude"}]}],"default":[{"harness":"codex"}]}' \
    resp=$(fm_test_api_http "$port" /rigs/config POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 401 ] || fail "missing token status $HTTP_CODE, wanted 401: $HTTP_BODY"
  after=$(cat "$home/config/crew-dispatch.json")
  [ "$before" = "$after" ] || fail "unauthorized config save rewrote the config"
  fm_test_api_stop "$home"
  pass "saving a whole dispatch config without the token is refused with 401"
}

test_rig_config_with_token_writes_config() {
  local home port token resp
  home=$(fm_test_api_home api-config-ok)
  write_rung_fixture "$home"
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  HTTP_BODY='{"note":"n","rules":[{"when":"builder class: ordinary","use":[{"harness":"claude","model":"opus"}]}],"default":[{"harness":"codex","model":"gpt-5.5"}]}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/config POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "authorized config save status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(node -e 'const c=require(process.argv[1]);process.stdout.write(String(c.rules[0].use[0].model))' \
      "$home/config/crew-dispatch.json")" = opus ] \
    || fail "config save did not write the new rules"
  [ "$(node -e 'const c=require(process.argv[1]);process.stdout.write(String(c.note))' \
      "$home/config/crew-dispatch.json")" = n ] \
    || fail "config save dropped the note"
  fm_test_api_stop "$home"
  pass "saving a whole dispatch config with the token writes it"
}

test_rig_config_refuses_a_ladder_with_no_enabled_rung() {
  local home port token resp before after
  home=$(fm_test_api_home api-config-broken)
  write_rung_fixture "$home"
  before=$(cat "$home/config/crew-dispatch.json")
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  HTTP_BODY='{"rules":[{"when":"x","use":[{"harness":"claude","enabled":false}]}],"default":[{"harness":"codex"}]}' \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/config POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 400 ] || fail "all-off ladder status $HTTP_CODE, wanted 400: $HTTP_BODY"
  printf '%s' "$HTTP_BODY" | grep -F 'enabled rung' >/dev/null \
    || fail "all-off ladder error is not clear: $HTTP_BODY"
  after=$(cat "$home/config/crew-dispatch.json")
  [ "$before" = "$after" ] || fail "refused config save still rewrote the config"
  fm_test_api_stop "$home"
  pass "saving a config with a ladder that has no enabled rung is refused"
}

test_rig_config_without_default_is_accepted() {
  local home port token resp
  home=$(fm_test_api_home api-config-no-default)
  mkdir -p "$home/config"
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    { "when": "builder class: ordinary", "use": [{ "harness": "claude", "model": "opus" }], "why": "keep this reason" }
  ]
}
EOF
  port=$(fm_test_api_start "$home")
  token=$(fm_test_api_token "$home")
  resp=$(fm_test_api_http "$port" /rigs/config GET)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "GET config without default status $HTTP_CODE, wanted 200: $HTTP_BODY"
  HTTP_BODY=$(json_query "$HTTP_BODY" 'JSON.stringify(d.config)') \
    HTTP_AUTHORIZATION="Bearer $token" \
    resp=$(fm_test_api_http "$port" /rigs/config POST)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "POST config without default status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(node -e 'const c=require(process.argv[1]);process.stdout.write(String("default" in c))' \
      "$home/config/crew-dispatch.json")" = false ] \
    || fail "round-trip invented a default ladder"
  [ "$(node -e 'const c=require(process.argv[1]);process.stdout.write(String(c.rules[0].why))' \
      "$home/config/crew-dispatch.json")" = "keep this reason" ] \
    || fail "round-trip dropped the why"
  fm_test_api_stop "$home"
  pass "saving a config with rules and no default is accepted"
}

test_rig_config_get_returns_the_whole_file() {
  local home port resp
  home=$(fm_test_api_home api-config-get)
  mkdir -p "$home/config"
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "note": "the note",
  "rules": [
    { "when": "builder class: ordinary", "use": [{ "harness": "claude", "model": "opus" }], "why": "keep this reason" }
  ],
  "default": [{ "harness": "codex", "model": "gpt-5.5" }]
}
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs/config GET)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "GET /rigs/config status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" 'd.config.rules[0].why')" = "keep this reason" ] \
    || fail "GET /rigs/config dropped the rule's why field: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" 'd.config.note')" = "the note" ] \
    || fail "GET /rigs/config dropped the note: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "GET /rigs/config returns the whole dispatch file, keeping fields /rigs drops"
}

test_rig_config_get_missing_file_is_null() {
  local home port resp
  home=$(fm_test_api_home api-config-get-missing)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /rigs/config GET)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "GET missing config status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" 'd.config === null')" = true ] \
    || fail "GET missing config should answer config null: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "GET /rigs/config on a missing file answers config null"
}

test_health_reports_version_and_home
test_unknown_path_is_not_found
test_binds_localhost_only
test_port_and_home_come_from_config
test_two_homes_do_not_share_a_server
test_start_stop_lifecycle
test_start_is_idempotent
test_start_replaces_server_when_lock_holder_changes
test_api_stays_up_when_lock_holder_is_replaced
test_malformed_url_returns_400_and_keeps_serving
test_api_exits_when_session_pid_dies
test_env_port_overrides_config
test_symlinked_api_port_refuses_start
test_first_start_writes_token_later_starts_keep_it
test_preexisting_token_is_kept
test_symlinked_api_token_refuses_start
test_captain_note_without_token_is_unauthorized
test_captain_note_with_token_lands_in_wake_queue
test_reads_need_no_token
test_question_back_note_does_not_close_a_hold
test_worker_relay_without_token_is_unauthorized
test_worker_relay_with_token_lands_in_wake_queue
test_worker_relay_unknown_task_is_not_found
test_decision_answer_without_token_is_unauthorized
test_decision_answer_with_token_lands_in_wake_queue
test_decision_answer_unknown_task_is_not_found
test_rung_toggle_without_token_is_unauthorized
test_rung_toggle_with_token_flips_enabled
test_rung_toggle_refuses_last_enabled_rung
test_rig_config_without_token_is_unauthorized
test_rig_config_with_token_writes_config
test_rig_config_refuses_a_ladder_with_no_enabled_rung
test_rig_config_without_default_is_accepted
test_rig_config_get_returns_the_whole_file
test_rig_config_get_missing_file_is_null

test_fleet_tasks_carry_enrich() {
  local home port resp
  home=$(fm_test_api_home api-fleet-enrich)
  write_fleet_fixture "$home"
  mkdir -p "$home/data/ship-task"
  cat > "$home/data/ship-task/brief.md" <<'EOF'
# Task

Build the enrich window end to end.

# Extra

Not part of the prompt.
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /fleet GET 10000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "enrich fleet status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" 'd.tasks.find(t => t.id === "ship-task").enrich.title')" = "Ship Task" ] || \
    fail "enrich title from the backlog record: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" 'd.tasks.find(t => t.id === "ship-task").enrich.first_prompt')" = \
    "Build the enrich window end to end." ] || \
    fail "enrich first_prompt is the brief Task section: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" 'd.tasks.find(t => t.id === "ship-task").enrich.model')" = "claude-opus-4-8" ] || \
    fail "enrich model comes from the task meta: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" \
      '((e) => typeof e.started_at === "string" && !isNaN(Date.parse(e.started_at)))(d.tasks.find(t => t.id === "ship-task").enrich)')" = true ] || \
    fail "enrich started_at is a parseable time: $HTTP_BODY"
  [ "$(json_query "$HTTP_BODY" \
      '((e) => typeof e.last_activity_at === "string" && !isNaN(Date.parse(e.last_activity_at)))(d.tasks.find(t => t.id === "ship-task").enrich)')" = true ] || \
    fail "enrich last_activity_at is a parseable time: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "fleet tasks carry the enrich window: title, brief prompt, and activity times"
}

if command -v jq >/dev/null 2>&1; then
  test_empty_home_fleet_is_empty_not_error
  test_fleet_snapshot_for_fixture_home
  test_fleet_body_matches_snapshot_script
  test_fleet_rejects_non_get
  test_fleet_tasks_carry_enrich
else
  echo "skip: jq not found (fleet snapshot endpoint)"
fi

echo "# fm-api.test.sh: all assertions passed"
