#!/usr/bin/env bash
set -u
phase_root=$PWD
mkdir -p "$phase_root/.test-phase-tmp"
phase_evidence=/Users/evanagee/.no-mistakes/evidence/01M2GFFFCXESED6R9329FWSBBA
export TMPDIR="$phase_root/.test-phase-tmp"
capture_cli() {
  local dir pid out
  reset_fakes
  dir=$(new_case cli-walk)
  make_repo_on_branch "$dir/wt" fm/cli-walk
  make_fakebin "$dir" >/dev/null
  fm_write_meta "$dir/state/cli-walk.meta" 'window=fm:fm-cli-walk' "worktree=$dir/wt" 'kind=ship'
  FM_FAKE_AXI_STATUS=$(run_active_agent fm/cli-walk 11s)
  printf 'Recent activity, default threshold:\n'
  run_crew_state "$dir" cli-walk
  FM_FAKE_AXI_STATUS=$(run_quiet_agent fm/cli-walk 25m 86240)
  printf '\nQuiet 25 minutes, default threshold:\n'
  run_crew_state "$dir" cli-walk
  printf '\nSame quiet agent, FM_PIPELINE_PARKED_MAX=3600:\n'
  FM_PIPELINE_PARKED_MAX=3600 run_crew_state "$dir" cli-walk
  bash -c 'exit 0' &
  pid=$!
  wait "$pid"
  FM_FAKE_AXI_STATUS="$(run_awaiting_agent_dead fm/cli-walk 13h)
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,13h,\"quiet 13h ago: log: last activity\",\"$pid\",fix 1"
  printf '\nAwaiting an exited PID:\n'
  run_crew_state "$dir" cli-walk
  FM_FAKE_AXI_STATUS="$(run_awaiting_agent_dead fm/cli-walk 13h)
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,13h,\"quiet 13h ago: log: last activity\",\"$$\",fix 1"
  printf '\nAwaiting a live PID:\n'
  run_crew_state "$dir" cli-walk
  FM_FAKE_AXI_STATUS=$(run_parked fm/cli-walk)
  printf '\nGenuine review gate:\n'
  run_crew_state "$dir" cli-walk
}
. "$phase_root/tests/fm-crew-state.test.sh" capture_cli
