#!/usr/bin/env bash
# fm-primary-watch-version-lib.sh - the one definition of a primary watcher
# extension's marker version.
#
# A primary watcher is its runtime adapter (.pi/extensions/fm-primary-pi-watch.ts
# or .omp/extensions/fm-primary-omp.ts) PLUS the shared lifecycle core it binds
# (bin/fm-primary-watch-core.ts). Both files decide watcher behaviour, so the
# version hashes both, in that order, exactly as the core itself does when it
# publishes the marker. Hashing only the adapter would leave a live session
# running stale core logic behind a still-matching marker.
#
# The adapter resolves its core through <adapter-dir>/../../bin, so the core is
# always <fm-root>/bin/fm-primary-watch-core.ts for the same root that owns the
# adapter. Missing files or a missing SHA-256 utility return nonzero, which every
# caller already treats as "not loaded" rather than as a match.
#
# No side effects on source. set -u / set -e safe.

fm_primary_watch_version() {  # <extension-file> <fm-root> -> sha256:<hex>
  local extension=${1:-} root=${2:-} core
  [ -n "$extension" ] && [ -f "$extension" ] || return 1
  [ -n "$root" ] || return 1
  core="$root/bin/fm-primary-watch-core.ts"
  [ -f "$core" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    cat "$extension" "$core" | shasum -a 256 | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    cat "$extension" "$core" | sha256sum | awk '{print "sha256:" $1}'
  else
    return 1
  fi
}
