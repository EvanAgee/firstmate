#!/usr/bin/env bash
# tests/api-helpers.sh - HTTP-against-throwaway-home seam for the localhost API.
#
# Source after tests/lib.sh (or source this file alone; it loads lib.sh).
# Later API tickets should drive the server through these helpers: build a
# throwaway home, start on an ephemeral port, speak real HTTP, then stop.
#
#   # shellcheck source=tests/api-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/api-helpers.sh"
#   home=$(fm_test_api_home)
#   port=$(fm_test_api_start "$home")
#   resp=$(fm_test_api_http "$port" /health)   # first line is the status code
#
# Started servers are stopped on EXIT. Do not point these helpers at a live
# firstmate home.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${FM_TEST_API_HELPERS_SOURCED:-}" ]; then
  FM_TEST_API_HELPERS_SOURCED=1
  FM_TEST_API_HOMES=()
  fm_test_api_stop_all() {
    local home
    for home in "${FM_TEST_API_HOMES[@]:-}"; do
      [ -n "$home" ] || continue
      FM_HOME="$home" "$ROOT/bin/fm-api.sh" stop >/dev/null 2>&1 || true
    done
    FM_TEST_API_HOMES=()
  }
  fm_test_api_exit() {
    fm_test_api_stop_all
    fm_test_cleanup
  }
  trap fm_test_api_exit EXIT
  trap 'fm_test_api_exit; exit 130' INT
  trap 'fm_test_api_exit; exit 143' TERM
fi

# fm_test_api_home [prefix]: throwaway firstmate home with state/, data/, and
# config/api-port=0. Echoes the home path.
fm_test_api_home() {
  local prefix=${1:-fm-api} root home
  root=$(fm_test_tmproot "$prefix") || fail "fm_test_api_home could not create a fixture root"
  [ -n "$root" ] || fail "fm_test_api_home got an empty fixture root"
  home="$root/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '0\n' > "$home/config/api-port"
  printf '%s\n' "$home"
}

# fm_test_api_start <home>: start this home's API and echo the bound port.
fm_test_api_start() {
  local home=$1 out port
  [ -n "$home" ] || fail "fm_test_api_start requires a home"
  FM_TEST_API_HOMES+=("$home")
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start 2>&1) || \
    fail "fm-api.sh start failed: $out"
  port=$(cat "$home/state/.api.port" 2>/dev/null) || port=
  [ -n "$port" ] || fail "API start did not write a port file: $out"
  printf '%s\n' "$port"
}

# fm_test_api_stop <home>
fm_test_api_stop() {
  local home=$1
  [ -n "$home" ] || return 0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" stop >/dev/null 2>&1 || true
}

# fm_test_api_http <port> <path> [method] [timeout-ms]: GET (or method)
# 127.0.0.1:<port><path>. Prints "<status>\n<body>" on success. Status 0 means
# the request failed to connect. timeout-ms defaults to 2000.
fm_test_api_http() {
  local port=$1 req_path=$2 method=${3:-GET} timeout_ms=${4:-2000}
  node -e '
const http = require("http");
const port = process.argv[1];
const reqPath = process.argv[2];
const method = process.argv[3];
const timeoutMs = Number(process.argv[4] || 2000);
const req = http.request({ host: "127.0.0.1", port, path: reqPath, method }, (res) => {
  const chunks = [];
  res.on("data", (c) => chunks.push(c));
  res.on("end", () => {
    process.stdout.write(String(res.statusCode) + "\n" + Buffer.concat(chunks).toString("utf8"));
  });
});
req.on("error", () => {
  process.stdout.write("0\n");
  process.exit(0);
});
req.setTimeout(timeoutMs, () => {
  req.destroy();
  process.stdout.write("0\n");
});
req.end();
' "$port" "$req_path" "$method" "$timeout_ms"
}

# fm_test_json_field <json> <field>: print one top-level JSON string/number/bool.
fm_test_json_field() {
  JSON=$1 FIELD=$2 node -e '
const d = JSON.parse(process.env.JSON);
if (!Object.prototype.hasOwnProperty.call(d, process.env.FIELD)) process.exit(1);
const v = d[process.env.FIELD];
if (v === null || v === undefined) process.exit(1);
process.stdout.write(String(v));
'
}

# fm_test_json <json> <js-expr>: evaluate a JS expression with `d` bound to the
# parsed object. Prints a scalar, or JSON for an object/array. Exit 1 if the
# result is null or undefined.
fm_test_json() {
  JSON=$1 EXPR=$2 node -e '
const d = JSON.parse(process.env.JSON);
const v = Function("d", "return (" + process.env.EXPR + ");")(d);
if (v === null || v === undefined) process.exit(1);
if (typeof v === "object") process.stdout.write(JSON.stringify(v));
else process.stdout.write(String(v));
'
}

# fm_test_non_loopback_ipv4: echo a non-internal IPv4 address, or return 1.
fm_test_non_loopback_ipv4() {
  node -e '
const os = require("os");
const nets = os.networkInterfaces();
for (const list of Object.values(nets)) {
  for (const n of list || []) {
    if ((n.family === "IPv4" || n.family === 4) && !n.internal) {
      process.stdout.write(n.address);
      process.exit(0);
    }
  }
}
process.exit(1);
' 2>/dev/null
}
