#!/usr/bin/env bash
set -u
phase_root=$PWD
mkdir -p "$phase_root/.test-phase-tmp"
export TMPDIR="$phase_root/.test-phase-tmp"
capture_triage() {
  test_crew_absorb_class_classifier
  test_stalled_run_step_never_absorbs
  test_provably_working_signal_absorbed
  printf '\nStatus event:\n'
  cat "$TMP_ROOT/provably-working-signal/state/task.status"
  printf 'Persisted signal suppressor:\n'
  cat "$TMP_ROOT/provably-working-signal/state/.seen-task_status"
  printf '\nTriage log:\n'
  cat "$TMP_ROOT/provably-working-signal/state/.watch-triage.log"
  printf '\nQueue bytes: '
  if [ -f "$TMP_ROOT/provably-working-signal/state/.wake-queue" ]; then wc -c < "$TMP_ROOT/provably-working-signal/state/.wake-queue"; else printf '0 (absent)\n'; fi
}
. "$phase_root/tests/fm-watch-triage.test.sh" capture_triage
