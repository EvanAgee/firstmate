#!/usr/bin/env bash
# Exact verified Pi-compatible harness family membership.
# Source this file, then call:
#   fm_pi_compatible_harness_is_verified <harness>
# The tracked bin/fm-pi-compatible-runtimes file is the single membership owner.
# This file has no side effects when sourced.

FM_PI_COMPATIBLE_ROOT=${FM_ROOT_OVERRIDE:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}
FM_PI_COMPATIBLE_ALLOWLIST="$FM_PI_COMPATIBLE_ROOT/bin/fm-pi-compatible-runtimes"

fm_pi_compatible_harness_is_verified() {
  local harness=${1:-}
  [ -n "$harness" ] || return 1
  [ -f "$FM_PI_COMPATIBLE_ALLOWLIST" ] || return 1
  grep -Fqx -- "$harness" "$FM_PI_COMPATIBLE_ALLOWLIST"
}
