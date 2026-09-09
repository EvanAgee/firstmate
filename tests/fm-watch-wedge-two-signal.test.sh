#!/usr/bin/env bash
# tests/fm-watch-wedge-two-signal.test.sh - the two-signal wedge rule in
# bin/fm-watch.sh: a pane going idle is ONE signal and never escalates on its
# own. A worker escalates as a possible wedge only when its second signal is
# quiet too - no declared pause, no live no-mistakes pipeline, and no armed PR
# merge watch.
#
# Why this suite exists: on 2026-09-01 five workers doing their real work inside
# an active pipeline were flagged as possible wedges, and on 2026-09-09 three
# workers firstmate had deliberately stopped on a green PR escalated to level 3
# with a `paused: [key=await-merge]` line sitting at the end of each status log.
# Both batches were idle-pane-only verdicts, and each false alarm cost firstmate
# a full handling turn.
#
# The classifier functions are exercised through the sourced watcher (its
# BASH_SOURCE guard returns before the singleton lock and the blocking loop), so
# these assert real behavior through the production entry points and never
# inspect implementation source. The broader watcher triage contract lives in
# fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-wedge-two-signal)

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
ok() { printf 'ok - %s\n' "$1"; }

# Build one hermetic case: a state dir holding a single ship task's meta and
# status log, plus the fake tmux and fake fm-crew-state.sh from wake-helpers.
# Echoes the case dir. The task's window is "fmtest:fm-<id>", the shape
# fm_backend_tmux_agent_state parses.
make_wedge_case() {  # <name> <id> <status-line> [meta-extra-lines]
  local name=$1 id=$2 status_line=$3 meta_extra=${4:-} dir
  dir=$(make_case "$name")
  local state="$dir/state"
  {
    printf 'window=fmtest:fm-%s\n' "$id"
    printf 'backend=tmux\n'
    printf 'harness=claude\n'
    printf 'kind=ship\n'
    printf 'worktree=%s/wt\n' "$dir"
    [ -z "$meta_extra" ] || printf '%s\n' "$meta_extra"
  } > "$state/$id.meta"
  mkdir -p "$dir/wt"
  printf '%s\n' "$status_line" > "$state/$id.status"
  printf '%s\n' "$dir"
}

# Run <fn> <args...> inside a subshell that has sourced the real watcher against
# <dir>'s state, with <dir>'s fake tmux and fake fm-crew-state.sh on PATH. Every
# FM_FAKE_* knob the caller exported is inherited, so a case fixes the agent
# liveness, the crew-state verdict, and the axi status the same way production
# would read them. Prints the function's stdout.
run_in_watcher() {  # <dir> <fn> <args...>
  local dir=$1
  shift
  (
    PATH="$dir/fakebin:$PATH"
    FM_HOME="$dir"
    FM_STATE_OVERRIDE="$dir/state"
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
    export PATH FM_HOME FM_STATE_OVERRIDE FM_CREW_STATE_BIN
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    "$@"
  )
}

# An agent the fake tmux reports as gone: its window is absent from the
# inventory, which fm_backend_tmux_agent_state reads as `missing` -> dead.
agent_gone() { unset FM_FAKE_TMUX_WINDOW; }
# An agent whose window IS in the inventory. Whether the classifier then calls
# it alive depends on the pane's foreground command, set per case.
agent_present() {  # <id>
  FM_FAKE_TMUX_WINDOW="fmtest:fm-$1"
  export FM_FAKE_TMUX_WINDOW
}

# --- the six-case table -----------------------------------------------------
#
# Each row drives pause_state_class, the function the watcher's stale paths call
# to decide between the long pause cadence, the absorb-as-working path, and the
# wedge ladder. `paused` and `working` both mean "no wedge escalation"; `none`
# means the wake surfaces for firstmate to inspect, which is the correct answer
# for a live agent whose pane merely looks quiet.

# The 2026-09-09 shape exactly: a worker firstmate stopped with `fm-control
# exit`, whose recorded backend cannot report agent liveness (an unverified
# backend answers `unverified`, an unreadable meta answers `unreadable`, and
# fm_backend_agent_alive maps both to `unknown` - never `dead`). Its run-step
# read `done`, which crew_absorb_class flattens to `none`. The old gate demanded
# a confidently `dead` agent before a declared pause could win, so this worker
# fell straight through to the wedge ladder despite its own `paused:` line.
# The measured 2026-09-09 root cause. A worker firstmate stopped on a green PR
# keeps a `working` run-step for as long as its ci step monitors the open PR:
# all three escalated workers read `state: working · source: run-step ·
# validating (running)` with a `paused: [key=await-merge]` line at the end of
# their status log. The old code honored that `working` verdict over the
# declared pause and absorbed the pane as provably-working, which starts the
# WEDGE TIMER - and that timer is what escalated them to level 3.
test_stale_working_run_step_does_not_beat_a_pause() {
  local dir out
  dir=$(make_wedge_case working-vs-pause wp \
    'paused: [key=await-merge] PR https://example.invalid/pull/1 green; waiting for the serial merge queue' \
    'mode=no-mistakes')
  agent_gone
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  # The live shape, captured from the installed binary on 2026-09-09: the ci
  # step is still `running` because the PR is open, but nothing has happened in
  # it for the better part of an hour.
  export FM_FAKE_AXI_STATUS='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,15h29m,"quiet 51m55s ago: log: base branch advanced, re-arming CI monitor timeout","",starting'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-wp wp)
  unset FM_FAKE_CREW_STATE FM_FAKE_AXI_STATUS
  if [ "$out" = paused ]; then
    ok "a quiet run-step 'working' does not beat a declared pause once the agent is gone"
  else
    fail "declared pause + gone agent must classify paused despite a working run-step, got '$out'"
  fi
}

# The other side of that same gate: a worker whose agent is still live and whose
# run is genuinely moving must keep classifying working, so a real validation is
# never re-routed onto the pause cadence.
test_live_agent_with_working_run_stays_working() {
  local dir out
  dir=$(make_wedge_case working-live wl \
    'paused: [key=await-ci] waiting on the CI queue' \
    'mode=no-mistakes')
  agent_present wl
  FM_FAKE_TMUX_CURRENT_COMMAND=claude
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_FAKE_AXI_STATUS='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-wl wl)
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND FM_FAKE_AXI_STATUS
  if [ "$out" = none ] || [ "$out" = working ]; then
    ok "a live agent with a moving run is never re-routed onto the pause cadence"
  else
    fail "live agent + working run must not classify paused, got '$out'"
  fi
}

test_declared_pause_beats_run_step_done() {
  local dir out
  dir=$(make_wedge_case pause-vs-done pd \
    'paused: [key=await-merge] PR green, waiting on the serial merge queue' \
    'mode=no-mistakes')
  # backend=zellij has no liveness classifier, so the agent reads `unknown`.
  sed -i.bak 's/^backend=tmux$/backend=zellij/' "$dir/state/pd.meta"
  rm -f "$dir/state/pd.meta.bak"
  agent_gone
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-pd pd)
  unset FM_FAKE_CREW_STATE
  if [ "$out" = paused ]; then
    ok "a declared pause outranks a run-step 'done' when the agent is not alive"
  else
    fail "declared pause + run-step done must classify paused, got '$out'"
  fi
}

test_declared_pause_with_live_agent_stays_none() {
  local dir out
  dir=$(make_wedge_case pause-live pl \
    'paused: [key=await-upstream] waiting on the upstream release' \
    'mode=no-mistakes')
  agent_present pl
  FM_FAKE_TMUX_CURRENT_COMMAND=claude
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-pl pl)
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  if [ "$out" = none ]; then
    ok "a live agent still overrides a declared pause, exactly as before"
  else
    fail "declared pause + live agent must classify none, got '$out'"
  fi
}

test_active_pipeline_blocks_escalation() {
  local dir out now
  dir=$(make_wedge_case pipeline-active pa 'working: implementing' 'mode=no-mistakes')
  export FM_FAKE_AXI_STATUS='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting'
  out=$(run_in_watcher "$dir" pipeline_recently_active pa && printf active || printf quiet)
  unset FM_FAKE_AXI_STATUS
  if [ "$out" = active ]; then
    ok "a run whose last activity is inside the stale window reads as active"
  else
    fail "an in-window running pipeline must read active, got '$out'"
  fi
}

test_quiet_pipeline_and_idle_pane_escalates() {
  local dir out stale_since ewf state
  dir=$(make_wedge_case pipeline-quiet pq 'working: implementing' 'mode=no-mistakes')
  state="$dir/state"
  # A step that has gone quiet far past the window is not a live second signal.
  # This is the exact shape a worker stopped on a green PR reports: the run is
  # still `running` (its ci step monitors the open PR), but nothing has happened
  # in it for the better part of an hour.
  export FM_FAKE_AXI_STATUS='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,15h29m,"quiet 51m55s ago: log: base branch advanced, re-arming CI monitor timeout","",starting' 
  out=$(run_in_watcher "$dir" pipeline_recently_active pq && printf active || printf quiet)
  if [ "$out" != quiet ]; then
    fail "a terminal run must not count as a live pipeline, got '$out'"
    unset FM_FAKE_AXI_STATUS
    return
  fi
  # With both signals quiet, the wedge timer must actually escalate: seed a
  # since-file already past the window and assert a wake is queued.
  stale_since="$state/.stale-since-fmtest_fm-pq"
  ewf="$state/.wedge-escalations-fmtest_fm-pq"
  printf '%s' "$(( $(date +%s) - 99999 ))" > "$stale_since"
  run_in_watcher "$dir" wedge_timer_check fmtest:fm-pq "$stale_since" "test stale" "$ewf" >/dev/null 2>&1
  unset FM_FAKE_AXI_STATUS
  if grep -q 'possible wedge' "$state/.wake-queue" 2>/dev/null; then
    ok "a quiet pipeline plus an idle pane still escalates as a possible wedge"
  else
    fail "both signals quiet must escalate; no wedge wake was queued"
  fi
}

test_active_pipeline_resets_the_wedge_timer() {
  local dir state stale_since ewf
  dir=$(make_wedge_case pipeline-hold ph 'working: validating' 'mode=no-mistakes')
  state="$dir/state"
  stale_since="$state/.stale-since-fmtest_fm-ph"
  ewf="$state/.wedge-escalations-fmtest_fm-ph"
  printf '%s' "$(( $(date +%s) - 99999 ))" > "$stale_since"
  export FM_FAKE_AXI_STATUS='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting' 
  run_in_watcher "$dir" wedge_timer_check fmtest:fm-ph "$stale_since" "test stale" "$ewf" >/dev/null 2>&1
  unset FM_FAKE_AXI_STATUS
  if grep -q 'possible wedge' "$state/.wake-queue" 2>/dev/null; then
    fail "an active pipeline must block the wedge escalation, but one was queued"
  else
    ok "an active pipeline resets the wedge timer instead of escalating"
  fi
}

test_green_pr_with_armed_watch_is_paused() {
  local dir out state
  dir=$(make_wedge_case green-pr gp \
    'done: PR https://github.com/EvanAgee/firstmate/pull/1 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/gp.check.sh"
  chmod 0700 "$state/gp.check.sh"
  agent_gone
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-gp gp)
  unset FM_FAKE_CREW_STATE
  if [ "$out" = paused ]; then
    ok "a gone agent with a green PR and an armed merge watch is paused, not wedged"
  else
    fail "green PR + armed watch + gone agent must classify paused, got '$out'"
  fi
}

test_dead_agent_with_nothing_still_escalates() {
  local dir out
  dir=$(make_wedge_case dead-bare db 'working: implementing' 'mode=no-mistakes')
  agent_gone
  export FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-db db)
  unset FM_FAKE_CREW_STATE
  if [ "$out" = none ]; then
    ok "a gone agent with no pause, no watch, and no pipeline still surfaces"
  else
    fail "the genuinely dead case must classify none, got '$out'"
  fi
}

# A task with no mode= drives no pipeline, so the gate must skip the axi call
# entirely rather than paying for it on every scout and secondmate.
test_no_mode_skips_the_pipeline_read() {
  local dir out with_mode
  dir=$(make_wedge_case no-mode nm 'working: investigating')
  export FM_FAKE_AXI_STATUS='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting'
  # Control: the identical fixture WITH a delivery mode must read active, so a
  # `quiet` verdict below is the mode gate deciding and not a missing function,
  # an unparsed status, or any other silent no-op.
  printf 'mode=no-mistakes\n' >> "$dir/state/nm.meta"
  with_mode=$(run_in_watcher "$dir" pipeline_recently_active nm && printf active || printf quiet)
  sed -i.bak '/^mode=no-mistakes$/d' "$dir/state/nm.meta"
  rm -f "$dir/state/nm.meta.bak"
  out=$(run_in_watcher "$dir" pipeline_recently_active nm && printf active || printf quiet)
  unset FM_FAKE_AXI_STATUS
  if [ "$with_mode" != active ]; then
    fail "control failed: the same fixture with mode= must read active, got '$with_mode'"
  elif [ "$out" = quiet ]; then
    ok "a task with no delivery mode skips the pipeline read"
  else
    fail "a task with no mode= must not read a pipeline, got '$out'"
  fi
}

test_declared_pause_beats_run_step_done
test_declared_pause_with_live_agent_stays_none
test_active_pipeline_blocks_escalation
test_quiet_pipeline_and_idle_pane_escalates
test_active_pipeline_resets_the_wedge_timer
test_green_pr_with_armed_watch_is_paused
test_dead_agent_with_nothing_still_escalates
test_no_mode_skips_the_pipeline_read
test_stale_working_run_step_does_not_beat_a_pause
test_live_agent_with_working_run_stays_working

exit "$FAILED"
