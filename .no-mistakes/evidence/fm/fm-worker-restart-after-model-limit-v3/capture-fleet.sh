#!/usr/bin/env bash
set -u
phase_root=$PWD
mkdir -p "$phase_root/.test-phase-tmp"
export TMPDIR="$phase_root/.test-phase-tmp"
capture_fleet() {
  test_stalled_work_and_decisions_remain_visible >&2
  PATH="$TMP_ROOT/stalled-work/fakebin:$PATH" FM_HOME="$TMP_ROOT/stalled-work" "$SNAPSHOT" --secondmate-home-summary
}
. "$phase_root/tests/fm-fleet-snapshot-view.test.sh" capture_fleet
