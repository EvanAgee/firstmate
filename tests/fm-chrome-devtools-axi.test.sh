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

test_launcher_prints_pin_and_routing_flag
test_launcher_ok_accepts_the_shipped_script
test_snapshot_classifier_accepts_a_named_session_page
test_snapshot_classifier_rejects_pageid_schema_error
test_bootstrap_reports_pageid_probe_failure
test_bootstrap_accepts_named_session_snapshot
