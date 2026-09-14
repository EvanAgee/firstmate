#!/usr/bin/env bash
set -u
phase_root=$PWD
mkdir -p "$phase_root/.test-phase-tmp"
phase_evidence=/Users/evanagee/.no-mistakes/evidence/01M2GFFFCXESED6R9329FWSBBA
export TMPDIR="$phase_root/.test-phase-tmp"
capture_episodes() {
  local original
  original=$(declare -f run_poll_daemon)
  eval "${original/run_poll_daemon/run_poll_daemon_original}"
  run_poll_daemon() {
    local dir=$1 result
    printf '\nCASE %s: daemon %s\n' "${dir##*/}" "$2" >> "$phase_evidence/stalled-episodes.log"
    for file in axi-status crew-observation; do
      if [ -f "$dir/$file" ]; then
        printf '%s before:\n' "$file" >> "$phase_evidence/stalled-episodes.log"
        cat "$dir/$file" >> "$phase_evidence/stalled-episodes.log"
      fi
    done
    printf 'Durable queue before:\n' >> "$phase_evidence/stalled-episodes.log"
    cat "$dir/state/.wake-queue" >> "$phase_evidence/stalled-episodes.log" 2>/dev/null || true
    run_poll_daemon_original "$@"
    result=$?
    printf 'Daemon exit: %s\n' "$result" >> "$phase_evidence/stalled-episodes.log"
    for file in .wake-queue .subsuper-escalations .subsuper-stalled-ps.generation .watcher-down; do
      printf '%s after:\n' "$file" >> "$phase_evidence/stalled-episodes.log"
      cat "$dir/state/$file" >> "$phase_evidence/stalled-episodes.log" 2>/dev/null || true
      printf '\n' >> "$phase_evidence/stalled-episodes.log"
    done
    return "$result"
  }
  test_generic_before_detailed_episodes_delivers_each_once
  test_detailed_episodes_do_not_repeat_after_failed_acknowledgement
  test_daemon_only_recovery_rearms_same_stall_identity
}
printf 'Production watcher polling, fixture axi status and backend, real durable queue ingestion and acknowledgement.\n' > "$phase_evidence/stalled-episodes.log"
. "$phase_root/tests/fm-watch-wedge-two-signal.test.sh" capture_episodes
