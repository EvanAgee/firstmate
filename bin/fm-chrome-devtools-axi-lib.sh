# shellcheck shell=bash
# chrome-devtools-axi compatibility floor, pinned MCP launcher, and the
# named-session open-and-snapshot probe.
# Usage: . bin/fm-chrome-devtools-axi-lib.sh
#
# chrome-devtools-axi is an external CLI. Firstmate does not own its pageId
# routing. This file is the single owner of the Firstmate-side contract:
#   - FM_CHROME_DEVTOOLS_AXI_MIN follows the axi-family floor policy owned
#     beside the floor constants in bin/fm-bootstrap.sh.
#   - bin/fm-chrome-devtools-mcp.js is the CHROME_DEVTOOLS_AXI_MCP_PATH
#     launcher. It pins chrome-devtools-mcp and adds --no-page-id-routing.
#   - Compatible means the installed chrome-devtools-axi meets that floor,
#     the launcher prints the expected pin and flag, and (unless the live
#     probe is skipped) `chrome-devtools-axi open` against a named session
#     returns a snapshot instead of the pageId schema error.
# bin/fm-bootstrap.sh turns a failing check into the operator-facing MISSING
# diagnostic. bin/fm-session-start.sh exports CHROME_DEVTOOLS_AXI_MCP_PATH and
# prints that export in the digest so the captain inherits the pin.
# bin/fm-spawn.sh still exports the launcher path and a per-task session name
# so workers do not inherit @latest or the default bridge.
#
# COMPATIBILITY VERDICT REUSE. The live probe launches Chrome, so one session
# start must not pay for it twice. Two reuse layers collapse that:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes
#     it in FM_CHROME_DEVTOOLS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES
#     that variable, the same contract as bin/fm-tasks-axi-lib.sh.
# FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE=1 skips the launcher spec check and the
# open-and-snapshot step so portable tests can exercise the version floor
# without a real node or browser. Call those functions directly to test them.
# A successful live probe is cached under state/.chrome-devtools-axi-probe
# keyed by axi version, launcher spec, and launcher identity. Detect-only
# bootstrap may read that cache and must not write it.

FM_CHROME_DEVTOOLS_AXI_MIN=0.1.30
FM_CHROME_DEVTOOLS_AXI_PROBE_URL=https://example.com
FM_CHROME_DEVTOOLS_AXI_PROBE_TIMEOUT_MS=30000

FM_CHROME_DEVTOOLS_AXI_COMPATIBLE_MEMO=${FM_CHROME_DEVTOOLS_AXI_COMPATIBLE:-}
unset FM_CHROME_DEVTOOLS_AXI_COMPATIBLE
case "$FM_CHROME_DEVTOOLS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_CHROME_DEVTOOLS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_chrome_devtools_mcp_launcher_path() {
  local dir
  dir=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  [ -f "$dir/fm-chrome-devtools-mcp.js" ] || return 1
  printf '%s\n' "$dir/fm-chrome-devtools-mcp.js"
}

fm_chrome_devtools_mcp_launcher_spec() {
  local launcher
  command -v node >/dev/null 2>&1 || return 1
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || return 1
  node "$launcher" --fm-print-spec
}

fm_chrome_devtools_mcp_launcher_ok() {
  local spec
  spec=$(fm_chrome_devtools_mcp_launcher_spec) || return 1
  printf '%s\n' "$spec" | grep -Eq '^package=chrome-devtools-mcp@[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  printf '%s\n' "$spec" | grep -Fxq 'flag=--no-page-id-routing'
}

fm_chrome_devtools_axi_version_parts() {
  local output
  command -v chrome-devtools-axi >/dev/null 2>&1 || return 1
  output=$(chrome-devtools-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_chrome_devtools_axi_version_ok() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_chrome_devtools_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_CHROME_DEVTOOLS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_chrome_devtools_axi_probe_cache_path() {
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_STATE_OVERRIDE/.chrome-devtools-axi-probe"
    return 0
  fi
  [ -n "${FM_HOME:-}" ] || return 1
  printf '%s\n' "$FM_HOME/state/.chrome-devtools-axi-probe"
}

fm_chrome_devtools_axi_probe_identity() {
  local version spec launcher
  version=$(chrome-devtools-axi --version 2>/dev/null) || return 1
  spec=$(fm_chrome_devtools_mcp_launcher_spec) || return 1
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || return 1
  printf '%s\n%s\n%s\n' "$version" "$spec" "$launcher"
}

fm_chrome_devtools_axi_probe_cache_hit() {
  local cache identity cached
  cache=$(fm_chrome_devtools_axi_probe_cache_path) || return 1
  [ -f "$cache" ] || return 1
  identity=$(fm_chrome_devtools_axi_probe_identity) || return 1
  cached=$(cat "$cache" 2>/dev/null) || return 1
  [ "$cached" = "$identity" ]
}

fm_chrome_devtools_axi_probe_cache_store() {
  local cache identity parent tmp
  [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && return 0
  cache=$(fm_chrome_devtools_axi_probe_cache_path) || return 1
  identity=$(fm_chrome_devtools_axi_probe_identity) || return 1
  parent=${cache%/*}
  [ -d "$parent" ] || mkdir -p "$parent" || return 1
  tmp=$(mktemp "$parent/.chrome-devtools-axi-probe.XXXXXX") || return 1
  if ! printf '%s\n' "$identity" > "$tmp" || ! mv -f "$tmp" "$cache"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_chrome_devtools_axi_snapshot_ok() {
  local output=$1
  printf '%s\n' "$output" | grep -Fq 'Required at pageId' && return 1
  printf '%s\n' "$output" | grep -Fq 'Invalid arguments for tool take_snapshot' && return 1
  printf '%s\n' "$output" | grep -Fq 'MCP error' && return 1
  printf '%s\n' "$output" | grep -Fq 'snapshot:' || return 1
  printf '%s\n' "$output" | grep -Eq 'example\.com' || return 1
  return 0
}

fm_chrome_devtools_axi_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_chrome_devtools_axi_mcp_path_export() {
  local launcher
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || return 1
  printf 'export CHROME_DEVTOOLS_AXI_MCP_PATH=%s\n' \
    "$(fm_chrome_devtools_axi_shell_quote "$launcher")"
}

fm_chrome_devtools_axi_export_mcp_path() {
  local launcher
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || return 1
  export CHROME_DEVTOOLS_AXI_MCP_PATH=$launcher
}

fm_chrome_devtools_axi_probe_session() {
  printf '%s\n' "${FM_CHROME_DEVTOOLS_AXI_PROBE_SESSION:-fm-bootstrap-chrome-probe-$$}"
}

fm_chrome_devtools_axi_probe_cmd() {
  local launcher timeout_ms session
  launcher=$(fm_chrome_devtools_mcp_launcher_path) || return 1
  session=$(fm_chrome_devtools_axi_probe_session) || return 1
  timeout_ms=${FM_CHROME_DEVTOOLS_AXI_PROBE_TIMEOUT_MS:-30000}
  case "$timeout_ms" in
    ''|*[!0-9]*|0) timeout_ms=30000 ;;
  esac
  env \
    -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT \
    -u CHROME_DEVTOOLS_AXI_BROWSER_URL \
    -u CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
    -u CHROME_DEVTOOLS_AXI_PORT \
    -u CHROME_DEVTOOLS_AXI_WS_HEADERS \
    -u CHROME_DEVTOOLS_AXI_HEADED \
    "CHROME_DEVTOOLS_AXI_MCP_PATH=$launcher" \
    "CHROME_DEVTOOLS_AXI_SESSION=$session" \
    "CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS=$timeout_ms" \
    "$@"
}

fm_chrome_devtools_axi_run_open() {
  fm_chrome_devtools_axi_probe_cmd chrome-devtools-axi open "$FM_CHROME_DEVTOOLS_AXI_PROBE_URL"
}

fm_chrome_devtools_axi_stop_probe_session() {
  fm_chrome_devtools_mcp_launcher_path >/dev/null 2>&1 || return 0
  fm_chrome_devtools_axi_probe_cmd chrome-devtools-axi stop >/dev/null 2>&1 || true
}

fm_chrome_devtools_axi_on_probe_exit() {
  local prev_cmd=${FM_CHROME_DEVTOOLS_AXI_PREV_EXIT_CMD:-true}
  FM_CHROME_DEVTOOLS_AXI_PROBE_CLEANUP_ARMED=0
  fm_chrome_devtools_axi_stop_probe_session
  eval "$prev_cmd"
}

fm_chrome_devtools_axi_arm_probe_cleanup() {
  local prev
  [ "${FM_CHROME_DEVTOOLS_AXI_PROBE_CLEANUP_ARMED:-0}" = 1 ] && return 0
  FM_CHROME_DEVTOOLS_AXI_PROBE_CLEANUP_ARMED=1
  FM_CHROME_DEVTOOLS_AXI_PREV_EXIT_CMD=true
  prev=$(trap -p EXIT 2>/dev/null || true)
  if [ -n "$prev" ]; then
    prev=${prev#trap -- \'}
    prev=${prev%\' EXIT}
    FM_CHROME_DEVTOOLS_AXI_PREV_EXIT_CMD=$prev
  fi
  trap fm_chrome_devtools_axi_on_probe_exit EXIT
}

fm_chrome_devtools_axi_disarm_probe_cleanup() {
  [ "${FM_CHROME_DEVTOOLS_AXI_PROBE_CLEANUP_ARMED:-0}" = 1 ] || return 0
  FM_CHROME_DEVTOOLS_AXI_PROBE_CLEANUP_ARMED=0
  if [ "${FM_CHROME_DEVTOOLS_AXI_PREV_EXIT_CMD:-true}" = true ]; then
    trap - EXIT
  else
    trap "$FM_CHROME_DEVTOOLS_AXI_PREV_EXIT_CMD" EXIT
  fi
  FM_CHROME_DEVTOOLS_AXI_PREV_EXIT_CMD=true
}

fm_chrome_devtools_axi_live_probe() {
  local output status
  if [ "${FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE:-0}" = 1 ]; then
    return 0
  fi
  fm_chrome_devtools_axi_probe_cache_hit && return 0
  fm_chrome_devtools_axi_arm_probe_cleanup
  output=$(fm_chrome_devtools_axi_run_open 2>&1)
  status=$?
  fm_chrome_devtools_axi_stop_probe_session
  fm_chrome_devtools_axi_disarm_probe_cleanup
  [ "$status" -eq 0 ] || return 1
  fm_chrome_devtools_axi_snapshot_ok "$output" || return 1
  fm_chrome_devtools_axi_probe_cache_store || true
  return 0
}

fm_chrome_devtools_axi_compatible_probe() {
  fm_chrome_devtools_axi_version_ok || return 1
  if [ "${FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE:-0}" = 1 ]; then
    return 0
  fi
  fm_chrome_devtools_mcp_launcher_ok || return 1
  fm_chrome_devtools_axi_live_probe
}

fm_chrome_devtools_axi_compatible() {
  case "$FM_CHROME_DEVTOOLS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_chrome_devtools_axi_compatible_probe; then
    FM_CHROME_DEVTOOLS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_CHROME_DEVTOOLS_AXI_COMPATIBLE_MEMO=0
  return 1
}
