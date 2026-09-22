#!/usr/bin/env bash
# Opt-in live guard for firstmate's chrome-devtools-axi compatibility probe.
#
# A stub can only confirm the classifier already written into the stub. This
# opens a page in a named session through firstmate's pinned MCP launcher and
# requires a snapshot. The launcher disables pageId routing through axi 0.1.30
# and keeps routing enabled for axi 0.1.31 and newer. Run this after an axi or
# chrome-devtools-mcp upgrade and before trusting the pin and version boundary
# in bin/fm-chrome-devtools-mcp.js.
set -u

if [ "${FM_CHROME_DEVTOOLS_AXI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CHROME_DEVTOOLS_AXI_LIVE_E2E=1 to run the live chrome-devtools-axi probe"
  exit 0
fi

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-chrome-devtools-axi-lib.sh disable=SC1091
. "$ROOT/bin/fm-chrome-devtools-axi-lib.sh"

command -v chrome-devtools-axi >/dev/null 2>&1 \
  || fail "chrome-devtools-axi not found; install it before running this guard"
command -v node >/dev/null 2>&1 \
  || fail "node not found; the pinned MCP launcher cannot start"

FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE=0
FM_CHROME_DEVTOOLS_AXI_PROBE_SESSION=fm-chrome-axi-live-e2e-$$
export FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE
export FM_CHROME_DEVTOOLS_AXI_PROBE_SESSION

cleanup_probe() {
  fm_chrome_devtools_axi_stop_probe_session
}
trap cleanup_probe EXIT

test_named_session_open_returns_a_snapshot() {
  local output status
  output=$(fm_chrome_devtools_axi_run_open 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "named-session open exited $status: $output"
  fm_chrome_devtools_axi_snapshot_ok "$output" \
    || fail "named-session open did not return a usable snapshot: $output"
  pass "named-session open through the pinned launcher returns a snapshot"
}

test_named_session_open_returns_a_snapshot
