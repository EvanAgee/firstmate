#!/usr/bin/env bash
# tests/fm-api.test.sh - localhost API front door: health, bind, config, lifecycle.
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

echo "# fm-api.test.sh: all assertions passed"
