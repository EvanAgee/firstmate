#!/usr/bin/env bash
set -u
phase_root=$PWD
mkdir -p "$phase_root/.test-phase-tmp"
export TMPDIR="$phase_root/.test-phase-tmp"
reproduce_before_fix() {
  local before entry
  before=$(fm_test_tmproot before-episode-receipt)
  mkdir -p "$before/bin"
  for entry in "$phase_root"/bin/*; do
    if [ "${entry##*/}" != fm-supervise-daemon.sh ]; then
      ln -s "$entry" "$before/bin/${entry##*/}"
    fi
  done
  git -C "$phase_root" show 68d0417:bin/fm-supervise-daemon.sh > "$before/bin/fm-supervise-daemon.sh"
  ROOT=$before
  test_generic_before_detailed_episodes_delivers_each_once
  test_detailed_episodes_do_not_repeat_after_failed_acknowledgement
}
. "$phase_root/tests/fm-watch-wedge-two-signal.test.sh" reproduce_before_fix
