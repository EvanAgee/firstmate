#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

size=$(wc -c < "$ROOT/AGENTS.md" | tr -d ' ')
[ "$size" -lt 32768 ] || fail "AGENTS.md is $size bytes; harness instruction cap is 32768 bytes"
pass "AGENTS.md fits the 32768-byte harness instruction cap"
