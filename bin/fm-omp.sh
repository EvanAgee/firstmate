#!/usr/bin/env bash
# fm-omp.sh - canonical primary omp launch: load both firstmate extensions.
#
# omp auto-discovers loose .ts extensions ONLY from ~/.omp/agent/extensions/
# (user-global), never from a project .pi/extensions/. firstmate's two primary
# extensions therefore load ONLY via explicit -e flags:
#
#   .pi/extensions/fm-primary-omp-turnend-guard.ts
#   .pi/extensions/fm-primary-omp-watch.ts
#
# This wrapper is the single owner of that launch argv. It resolves FM_ROOT,
# refuses to start when either file is missing, and execs omp with
# `-e <turnend> -e <watch>` plus every passthrough argument. Do not copy those
# files into ~/.omp/agent/extensions/; the wrapper is the fix.
#
# Usage:
#   fm-omp.sh [omp-args...]
#
# Environment:
#   FM_OMP_BIN         omp executable (default: command -v omp)
#   FM_ROOT_OVERRIDE   firstmate repo root (default: parent of this script)
#
# Exit status is omp's. A missing extension file or missing omp executable
# prints `error: ...` on stderr and exits 1.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TURNEND="$FM_ROOT/.pi/extensions/fm-primary-omp-turnend-guard.ts"
WATCH="$FM_ROOT/.pi/extensions/fm-primary-omp-watch.ts"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -f "$TURNEND" ] || die "missing turn-end guard extension: $TURNEND"
[ -f "$WATCH" ] || die "missing watcher extension: $WATCH"

if [ -n "${FM_OMP_BIN:-}" ]; then
  OMP_BIN=$FM_OMP_BIN
else
  OMP_BIN=$(command -v omp) || die "omp not found on PATH"
fi
[ -x "$OMP_BIN" ] || die "omp is not executable: $OMP_BIN"

exec "$OMP_BIN" -e "$TURNEND" -e "$WATCH" "$@"
