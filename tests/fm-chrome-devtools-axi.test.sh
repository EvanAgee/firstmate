#!/usr/bin/env bash
# Portable chrome-devtools-axi compatibility tests.
#
# The live browser probe is skipped here. This file pins the launcher spec,
# snapshot classifier, and bootstrap's reaction to a pageId schema failure
# through fake axi output. tests/fm-chrome-devtools-axi-live-e2e.test.sh is
# the opt-in guard that actually opens a page.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-chrome-devtools-axi-lib.sh disable=SC1091
. "$ROOT/bin/fm-chrome-devtools-axi-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chrome-devtools-axi-tests)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

add_snapshot_axi() {
  local fakebin=$1 mode=$2
  cat > "$fakebin/chrome-devtools-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' '0.1.30'
  exit 0
fi
if [ "\${1:-}" = stop ]; then
  exit 0
fi
if [ "\${1:-}" = open ]; then
  if [ "$mode" = pageid ]; then
    cat <<'OUT'
page:
  url: "https://example.com"
  refs: 0
snapshot:
MCP error -32602: Input validation error: Invalid arguments for tool take_snapshot: Required at pageId
OUT
    exit 1
  fi
  cat <<'OUT'
page:
  url: "https://example.com"
  refs: 1
snapshot:
RootWebArea "Example Domain"
  heading "Example Domain"
OUT
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
}

make_bootstrap_home() {
  local dir=$1
  local fakebin
  mkdir -p "$dir/home/config"
  printf '%s\n' manual > "$dir/home/config/backlog-backend"
  printf '%s\n' tmux > "$dir/home/config/backend"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" no-mistakes FM_FAKE_NO_MISTAKES_VERSION 1.31.2
  fm_fake_exit0 "$fakebin" git gh
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.4'; exit 0 ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
    fi
    exit 0
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'mv [<id>...]'
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.25
  printf '%s\n' "$fakebin"
}

test_launcher_prints_pin_and_routing_flag() {
  local spec
  command -v node >/dev/null 2>&1 || fail "node is required to read the launcher spec"
  spec=$(node "$ROOT/bin/fm-chrome-devtools-mcp.js" --fm-print-spec) || fail "launcher --fm-print-spec failed"
  printf '%s\n' "$spec" | grep -Eq '^package=chrome-devtools-mcp@[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "launcher did not print a pinned chrome-devtools-mcp package: $spec"
  printf '%s\n' "$spec" | grep -Fxq 'flag=--no-page-id-routing' \
    || fail "launcher did not print --no-page-id-routing: $spec"
  printf '%s\n' "$spec" | grep -Fq '@latest' \
    && fail "launcher still names @latest: $spec"
  pass "launcher prints a pinned MCP package and --no-page-id-routing"
}

test_launcher_ok_accepts_the_shipped_script() {
  command -v node >/dev/null 2>&1 || fail "node is required to check the launcher"
  fm_chrome_devtools_mcp_launcher_ok || fail "shipped launcher spec was rejected"
  pass "shipped launcher satisfies the compatibility spec check"
}

test_snapshot_classifier_accepts_a_named_session_page() {
  local output
  output=$(cat <<'OUT'
page:
  url: "https://example.com"
  refs: 1
snapshot:
RootWebArea "Example Domain"
  heading "Example Domain"
OUT
)
  fm_chrome_devtools_axi_snapshot_ok "$output" || fail "valid snapshot was rejected"
  pass "snapshot classifier accepts an example.com snapshot"
}

test_snapshot_classifier_rejects_pageid_schema_error() {
  local output
  output=$(cat <<'OUT'
page:
  url: "https://example.com"
  refs: 0
snapshot:
MCP error -32602: Input validation error: Invalid arguments for tool take_snapshot: Required at pageId
OUT
)
  if fm_chrome_devtools_axi_snapshot_ok "$output"; then
    fail "pageId schema error was accepted as a snapshot"
  fi
  pass "snapshot classifier rejects the pageId schema error"
}

test_bootstrap_reports_pageid_probe_failure() {
  local case_dir fakebin out missing
  missing='MISSING: chrome-devtools-axi (install: npm install -g chrome-devtools-axi && chrome-devtools-axi setup hooks)'
  case_dir="$TMP_ROOT/pageid-fail"
  fakebin=$(make_bootstrap_home "$case_dir")
  add_snapshot_axi "$fakebin" pageid
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE=0 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing" ] || fail "pageId probe failure expected '$missing', got: $out"
  pass "bootstrap reports chrome-devtools-axi missing when the snapshot probe hits pageId"
}

test_bootstrap_accepts_named_session_snapshot() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/snapshot-ok"
  fakebin=$(make_bootstrap_home "$case_dir")
  add_snapshot_axi "$fakebin" ok
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE=0 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "successful snapshot probe should be silent, got: $out"
  pass "bootstrap stays silent when a named-session snapshot succeeds"
}

write_probe_env_axi() {
  local fakebin=$1 dump=$2
  cat > "$fakebin/chrome-devtools-axi" <<SH
#!/usr/bin/env bash
{
  printf 'cmd=%s\n' "\${1:-}"
  printf 'AUTO_CONNECT=%s\n' "\${CHROME_DEVTOOLS_AXI_AUTO_CONNECT-<unset>}"
  printf 'BROWSER_URL=%s\n' "\${CHROME_DEVTOOLS_AXI_BROWSER_URL-<unset>}"
  printf 'USER_DATA_DIR=%s\n' "\${CHROME_DEVTOOLS_AXI_USER_DATA_DIR-<unset>}"
  printf 'PORT=%s\n' "\${CHROME_DEVTOOLS_AXI_PORT-<unset>}"
  printf 'WS_HEADERS=%s\n' "\${CHROME_DEVTOOLS_AXI_WS_HEADERS-<unset>}"
  printf 'HEADED=%s\n' "\${CHROME_DEVTOOLS_AXI_HEADED-<unset>}"
  printf 'MCP_PATH=%s\n' "\${CHROME_DEVTOOLS_AXI_MCP_PATH-<unset>}"
  printf 'SESSION=%s\n' "\${CHROME_DEVTOOLS_AXI_SESSION-<unset>}"
  printf 'BRIDGE_TIMEOUT_MS=%s\n' "\${CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS-<unset>}"
} > "\${FM_CHROME_AXI_ENV_DUMP:-$dump}"
if [ "\${1:-}" = open ]; then
  cat <<'OUT'
page:
  url: "https://example.com"
  refs: 1
snapshot:
RootWebArea "Example Domain"
OUT
fi
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
}

assert_probe_env_isolated() {
  local dump=$1 launcher=$2 timeout_ms expected_session
  grep -Fxq 'AUTO_CONNECT=<unset>' "$dump" || fail "probe inherited AUTO_CONNECT: $(cat "$dump")"
  grep -Fxq 'BROWSER_URL=<unset>' "$dump" || fail "probe inherited BROWSER_URL: $(cat "$dump")"
  grep -Fxq 'USER_DATA_DIR=<unset>' "$dump" || fail "probe inherited USER_DATA_DIR: $(cat "$dump")"
  grep -Fxq 'PORT=<unset>' "$dump" || fail "probe inherited PORT: $(cat "$dump")"
  grep -Fxq 'WS_HEADERS=<unset>' "$dump" || fail "probe inherited WS_HEADERS: $(cat "$dump")"
  grep -Fxq 'HEADED=<unset>' "$dump" || fail "probe inherited HEADED: $(cat "$dump")"
  grep -Fxq "MCP_PATH=$launcher" "$dump" || fail "probe did not pin MCP_PATH: $(cat "$dump")"
  expected_session=$(fm_chrome_devtools_axi_probe_session)
  grep -Fxq "SESSION=$expected_session" "$dump" \
    || fail "probe did not use the probe session $expected_session: $(cat "$dump")"
  timeout_ms=$(sed -n 's/^BRIDGE_TIMEOUT_MS=//p' "$dump")
  case "$timeout_ms" in
    ''|*[!0-9]*) fail "probe did not set a numeric bridge timeout: $(cat "$dump")" ;;
  esac
  [ "$timeout_ms" -ge 30000 ] \
    || fail "probe bridge timeout $timeout_ms is below axi's 30000 default: $(cat "$dump")"
}

with_attach_env() {
  CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1
  CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222
  CHROME_DEVTOOLS_AXI_USER_DATA_DIR=/tmp/chrome-profile
  CHROME_DEVTOOLS_AXI_PORT=9224
  # Literal JSON env value; not expanded as a shell word list.
  # shellcheck disable=SC2089
  CHROME_DEVTOOLS_AXI_WS_HEADERS='{"Authorization":"Bearer x"}'
  CHROME_DEVTOOLS_AXI_HEADED=1
  # shellcheck disable=SC2090
  export CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR CHROME_DEVTOOLS_AXI_PORT \
    CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_HEADED
}

test_probe_open_unsets_attach_env() {
  local case_dir fakebin dump launcher
  case_dir="$TMP_ROOT/probe-open-env"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  dump="$case_dir/open.env"
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || fail "launcher missing"
  write_probe_env_axi "$fakebin" "$dump"
  with_attach_env
  PATH="$fakebin:$PATH" fm_chrome_devtools_axi_run_open \
    || fail "isolated probe open failed"
  [ -f "$dump" ] || fail "probe open did not record env"
  grep -Fxq 'cmd=open' "$dump" || fail "probe open did not run open: $(cat "$dump")"
  assert_probe_env_isolated "$dump" "$launcher"
  [ "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-}" = 1 ] \
    || fail "probe open unset AUTO_CONNECT in the parent shell"
  pass "probe open drops attach env and stays isolated"
}

test_probe_stop_unsets_attach_env() {
  local case_dir fakebin dump launcher
  case_dir="$TMP_ROOT/probe-stop-env"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  dump="$case_dir/stop.env"
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || fail "launcher missing"
  write_probe_env_axi "$fakebin" "$dump"
  with_attach_env
  PATH="$fakebin:$PATH" fm_chrome_devtools_axi_stop_probe_session \
    || fail "isolated probe stop failed"
  [ -f "$dump" ] || fail "probe stop did not record env"
  grep -Fxq 'cmd=stop' "$dump" || fail "probe stop did not run stop: $(cat "$dump")"
  assert_probe_env_isolated "$dump" "$launcher"
  [ "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-}" = 1 ] \
    || fail "probe stop unset AUTO_CONNECT in the parent shell"
  pass "probe stop drops attach env and stays isolated"
}

test_probe_sessions_are_process_unique() {
  local case_dir fakebin dump_a dump_b session_a session_b pid_a pid_b
  case_dir="$TMP_ROOT/probe-unique"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  dump_a="$case_dir/a.env"
  dump_b="$case_dir/b.env"
  write_probe_env_axi "$fakebin" "$case_dir/unused.env"
  PATH="$fakebin:$PATH" FM_CHROME_AXI_ENV_DUMP="$dump_a" bash -c '
    . "$1"
    fm_chrome_devtools_axi_run_open
  ' _ "$ROOT/bin/fm-chrome-devtools-axi-lib.sh" &
  pid_a=$!
  PATH="$fakebin:$PATH" FM_CHROME_AXI_ENV_DUMP="$dump_b" bash -c '
    . "$1"
    fm_chrome_devtools_axi_run_open
  ' _ "$ROOT/bin/fm-chrome-devtools-axi-lib.sh" &
  pid_b=$!
  wait "$pid_a" || fail "unique-session probe A failed"
  wait "$pid_b" || fail "unique-session probe B failed"
  session_a=$(sed -n 's/^SESSION=//p' "$dump_a")
  session_b=$(sed -n 's/^SESSION=//p' "$dump_b")
  [ -n "$session_a" ] || fail "probe A recorded no session: $(cat "$dump_a" 2>/dev/null)"
  [ -n "$session_b" ] || fail "probe B recorded no session: $(cat "$dump_b" 2>/dev/null)"
  [ "$session_a" != "$session_b" ] || fail "concurrent probes shared session $session_a"
  [ "$session_a" = "fm-bootstrap-chrome-probe-$pid_a" ] \
    || fail "probe A session $session_a was not pid-unique for $pid_a"
  [ "$session_b" = "fm-bootstrap-chrome-probe-$pid_b" ] \
    || fail "probe B session $session_b was not pid-unique for $pid_b"
  pass "concurrent probes use distinct process-unique sessions"
}

test_probe_stop_runs_on_exit() {
  local case_dir fakebin dump session
  case_dir="$TMP_ROOT/probe-exit"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  dump="$case_dir/exit.env"
  write_probe_env_axi "$fakebin" "$dump"
  PATH="$fakebin:$PATH" FM_CHROME_AXI_ENV_DUMP="$dump" bash -c '
    . "$1"
    fm_chrome_devtools_axi_arm_probe_cleanup
    exit 0
  ' _ "$ROOT/bin/fm-chrome-devtools-axi-lib.sh" \
    || fail "probe EXIT cleanup process failed"
  [ -f "$dump" ] || fail "EXIT cleanup did not invoke axi stop"
  grep -Fxq 'cmd=stop' "$dump" || fail "EXIT cleanup did not stop the probe: $(cat "$dump")"
  session=$(sed -n 's/^SESSION=//p' "$dump")
  printf '%s\n' "$session" | grep -Eq '^fm-bootstrap-chrome-probe-[0-9]+$' \
    || fail "EXIT cleanup used a non-unique session: $session"
  pass "probe stop runs on EXIT for a process-unique session"
}

test_mcp_path_export_is_inheritable() {
  local launcher line
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || fail "launcher missing"
  line=$(fm_chrome_devtools_axi_mcp_path_export) || fail "mcp path export failed"
  unset CHROME_DEVTOOLS_AXI_MCP_PATH
  eval "$line"
  [ "${CHROME_DEVTOOLS_AXI_MCP_PATH:-}" = "$launcher" ] \
    || fail "export did not pin the launcher: ${CHROME_DEVTOOLS_AXI_MCP_PATH:-} ($line)"
  pass "MCP_PATH export pins the firstmate launcher"
}

test_session_start_prints_mcp_path_export() {
  local case_dir fakebin out line launcher
  case_dir="$TMP_ROOT/session-pin"
  fakebin=$(make_bootstrap_home "$case_dir")
  mkdir -p "$case_dir/home/state" "$case_dir/home/data"
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || fail "launcher missing"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_API=0 "$ROOT/bin/fm-session-start.sh")
  line=$(printf '%s\n' "$out" | grep '^export CHROME_DEVTOOLS_AXI_MCP_PATH=' | head -1)
  [ -n "$line" ] || fail "session start did not print MCP_PATH export: $out"
  unset CHROME_DEVTOOLS_AXI_MCP_PATH
  eval "$line"
  [ "${CHROME_DEVTOOLS_AXI_MCP_PATH:-}" = "$launcher" ] \
    || fail "session-start export did not pin the launcher: ${CHROME_DEVTOOLS_AXI_MCP_PATH:-}"
  pass "session start prints an inheritable MCP_PATH export"
}

test_launcher_prints_pin_and_routing_flag
test_launcher_ok_accepts_the_shipped_script
test_snapshot_classifier_accepts_a_named_session_page
test_snapshot_classifier_rejects_pageid_schema_error
test_bootstrap_reports_pageid_probe_failure
test_bootstrap_accepts_named_session_snapshot
test_probe_open_unsets_attach_env
test_probe_stop_unsets_attach_env
test_probe_sessions_are_process_unique
test_probe_stop_runs_on_exit
test_mcp_path_export_is_inheritable
test_session_start_prints_mcp_path_export
