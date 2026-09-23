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
# Fixture subshells deliberately keep their environment changes out of later cases.
# shellcheck disable=SC2030,SC2031
# Tests and their helpers are reached through the selector dispatch loop.
# shellcheck disable=SC2329
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
# The branch every fixture worktree is created on, and the branch an attributed
# axi status answer must name.
WEDGE_BRANCH=fm/wedge-fixture

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
  # A real git worktree on a known branch: the pipeline probe attributes an axi
  # status answer to this task by comparing the run's branch and head against
  # the worktree's own, exactly as fm-crew-state.sh and fm-teardown.sh do.
  mkdir -p "$dir/wt"
  git -C "$dir/wt" init -q -b "$WEDGE_BRANCH" >/dev/null 2>&1
  git -C "$dir/wt" config user.email test@example.invalid
  git -C "$dir/wt" config user.name 'Wedge Test'
  : > "$dir/wt/seed"
  git -C "$dir/wt" add seed >/dev/null 2>&1
  git -C "$dir/wt" commit -qm seed >/dev/null 2>&1
  printf '%s\n' "$status_line" > "$state/$id.status"
  printf '%s\n' "$dir"
}

# Wrap <rows> (the active_steps table and any sibling tables) in the run header
# a real `axi status` answer carries, attributed to <dir>'s worktree so the
# probe accepts it as this task's own run. Cases that need an UNATTRIBUTED
# answer build their own header instead.
axi_status_for() {  # <dir> <rows>
  local dir=$1 rows=$2 head
  head=$(git -C "$dir/wt" rev-parse HEAD 2>/dev/null)
  printf 'run:\n  id: "01RUN"\n  branch: %s\n  status: running\n  head: "%s"\n%s\n' \
    "$WEDGE_BRANCH" "$head" "$rows"
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
    # PATH is deliberately scoped to this subshell: the fakebin must cover the
    # sourced watcher and every command it calls, and must not leak back to the
    # caller. That containment is the whole point of this helper, so the two
    # PATH warnings below are the intended design rather than a mistake.
    # shellcheck disable=SC2030 # Subshell-local PATH is this helper's isolation.
    PATH="$dir/fakebin:$PATH"
    FM_HOME="$dir"
    FM_STATE_OVERRIDE="$dir/state"
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
    export PATH FM_HOME FM_STATE_OVERRIDE FM_CREW_STATE_BIN
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    case "$1" in
      shared_episode_retire_waiting_delivery)
        shift
        shared_episode_retire_waiting_delivery "$@"
        ;;
      *) "$@" ;;
    esac
  )
}

# --- driving the real watcher process ---------------------------------------
#
# The stale DISPATCH (which branch of the poll loop a worker lands in) cannot be
# reached by calling a classifier directly, so the finished-awaiting-merge cases
# below run bin/fm-watch.sh itself over a seeded state dir and assert what the
# poll actually did: the wake queue, the pause markers, and the wedge timer.
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Arm a genuine PR merge poll for <id> against <url>, the same way
# bin/fm-pr-check.sh arms one: the pr= meta field plus the <id>.pr-poll and
# <id>.pr-poll-registration sidecars alongside <id>.check.sh. This is what
# fm_pr_poll_artifacts_valid recognizes, and only this counts as an armed merge
# watch. Prepared and published offline through the same fm-pr-lib.sh entry
# points, so no network call is needed.
arm_pr_poll() {  # <state> <id> <url>
  local state=$1 id=$2 url=$3 meta host path number fakebin
  # An armed poll is a LIVE poll: the watcher runs it every check cycle. Give it
  # a gh that reports the PR still OPEN, which is exactly the state of a worker
  # awaiting the merge queue, so the poll stays silent and the case measures the
  # stale dispatch rather than a merge notification.
  fakebin=${state%/state}/fakebin
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  *" state "*) printf 'OPEN\n' ;;
esac
SH
  chmod +x "$fakebin/gh"
  meta="$state/$id.meta"
  host=${url#https://}; host=${host%%/*}
  path=${url#https://"$host"/}; path=${path%%/pull/*}
  number=${url##*/}
  grep -v '^pr=' "$meta" > "$meta.tmp" 2>/dev/null || true
  printf 'pr=%s\n' "$url" >> "$meta.tmp"
  mv -f "$meta.tmp" "$meta"
  chmod 0600 "$meta"
  (
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_prepare "$state" "$id" github "$url" "$host" "$path" "$number" \
      "$ROOT/bin/fm-pr-poll.sh" || exit 1
    fm_pr_poll_publish_prepared files-only || exit 1
  )
}

# Arm an UNRELATED registered custom watcher check for <id>: a real, registered
# <id>.check.sh that is not a PR poll at all (a deploy probe, a fixture watcher).
# bin/fm-check-register.sh is the supported way to bind arbitrary intentional
# check bytes, and the watcher's own sweep already distinguishes this from a PR
# poll. A worker holding one of these is NOT awaiting a merge.
arm_custom_check() {  # <state> <id>
  local state=$1 id=$2
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/$id.check.sh" || return 1
  chmod 0700 "$state/$id.check.sh" || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null 2>&1
}

# Seed a case so the watcher's poll reaches the stale path on its first look:
# a recorded window, a matching pane hash already counted as seen, and a primed
# .seen-* suppressor so the signal scan does not pre-empt the stale dispatch.
seed_stale_pane() {  # <dir> <id> <window> <pane-text>
  local dir=$1 id=$2 window=$3 text=$4 state key
  state="$dir/state"
  printf '%s' "$text" > "$dir/pane.txt"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_signal_sig "$2"' _ "$ROOT" "$state/$id.status")" \
    > "$state/.seen-${id}_status"
}

# Run the watcher over <dir>'s state until it has classified the stale pane,
# then stop it. The first poll only records the pane hash; the stale dispatch
# runs on a later one, so wait for the .stale-<key> suppressor the dispatch
# writes (or for the wake queue) rather than guessing a sleep. The caller
# inspects the state dir and the captured stdout at <dir>/watch.out.
# Run the watcher over <dir>'s state until <marker> appears or a wake is queued,
# then stop it. For cases whose .stale-<key> suppressor is pre-seeded, so the
# generic "has it been classified yet" wait would return before the poll acts.
# Run the watcher over <dir>'s state for <seconds>, letting it complete several
# poll cycles, then stop it. The throttle defect only shows from the SECOND poll
# onward, so a case that stops at the first marker cannot see it.
run_for_seconds() {  # <dir> <window> <seconds> [extra-env-assignments...]
  local dir=$1 window=$2 secs=$3 pid deadline
  shift 3
  # shellcheck disable=SC2031 # A per-command PATH prefix; nothing here reads the helper subshell's PATH.
  env PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  reap "$pid"
}

# Stale wakes queued for <window>, as a plain integer.
count_stale_wakes() {  # <state> <window>
  local n
  n=$(grep -e stale "$1/.wake-queue" 2>/dev/null | grep -c -F "$2" || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Acknowledge whatever the last watcher run queued, the way the real supervisor
# does between restarts, so the next run starts from a settled queue.
drain_wakes() {  # <state>
  FM_STATE_OVERRIDE="$1" "$DRAIN" >/dev/null 2>&1 || true
}

run_until_marker() {  # <dir> <marker-path>
  local dir=$1 marker=$2 state pid i=0
  state="$dir/state"
  # shellcheck disable=SC2031 # A per-command PATH prefix; nothing here reads the helper subshell's PATH.
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="${FM_WEDGE_WINDOW:-}" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -e "$marker" ] || [ -s "$state/.wake-queue" ]; then
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
}

run_until_stale_classified() {  # <dir> <window>
  local dir=$1 window=$2 state key pid i=0
  state="$dir/state"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # shellcheck disable=SC2031 # A per-command PATH prefix; nothing here reads the helper subshell's PATH.
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -e "$state/.stale-$key" ] || [ -e "$state/.paused-$key" ] || [ -s "$state/.wake-queue" ]; then
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
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
    'paused: [key=await-merge] PR https://github.com/EvanAgee/firstmate/pull/1 green; waiting for the serial merge queue' \
    'mode=no-mistakes')
  agent_gone
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  # The live shape, captured from the installed binary on 2026-09-09: the ci
  # step is still `running` because the PR is open, but nothing has happened in
  # it for the better part of an hour.
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,15h29m,"quiet 51m55s ago: log: base branch advanced, re-arming CI monitor timeout","",starting')
  export FM_FAKE_AXI_STATUS
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
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting')
  export FM_FAKE_AXI_STATUS
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-wl wl)
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND FM_FAKE_AXI_STATUS
  if [ "$out" = none ] || [ "$out" = working ]; then
    ok "a live agent with a moving run is never re-routed onto the pause cadence"
  else
    fail "live agent + working run must not classify paused, got '$out'"
  fi
}

# Required behavior 3, driven through the real stale DISPATCH rather than the
# helper alone. A `done: PR <url> checks green` line is captain-relevant, so the
# poll routes this worker into the terminal branch - the branch that never
# consults pause_state_class. With the agent gone and the merge watch armed, it
# must be absorbed on the long pause cadence, not surfaced and not wedge-timed.
test_green_pr_awaiting_merge_is_absorbed_by_the_real_poll() {
  local dir state window key
  dir=$(make_wedge_case merge-dispatch md \
    'done: PR https://github.com/EvanAgee/firstmate/pull/7 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-md
  key=$(printf '%s' "$window" | tr ':/.' '___')
  arm_pr_poll "$state" md https://github.com/EvanAgee/firstmate/pull/7 \
    || { fail "could not arm the merge watch fixture"; return; }
  seed_stale_pane "$dir" md "$window" 'idle waiting for merge'
  # The window must stay in the tmux inventory for the pane capture the poll
  # needs, so the agent is made dead the other way the classifier allows: its
  # pane's foreground command is a bare shell, never a harness.
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  run_until_stale_classified "$dir" "$window"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  if [ -s "$state/.wake-queue" ]; then
    fail "a green-PR worker awaiting merge was surfaced: $(cat "$state/.wake-queue")"
  elif [ -e "$state/.stale-since-$key" ]; then
    fail "a green-PR worker awaiting merge started the wedge timer"
  elif [ ! -e "$state/.paused-$key" ]; then
    fail "a green-PR worker awaiting merge was not absorbed on the pause cadence"
  else
    ok "a green PR with an armed merge watch is absorbed by the real stale dispatch"
  fi
}

test_stalled_validation_overrides_previous_merge_wait() {
  local dir state window key hash_state reason recovery_token
  for hash_state in new absorbed; do
    dir=$(make_wedge_case "stalled-merge-$hash_state" sm \
      'done: PR https://github.com/EvanAgee/firstmate/pull/7 checks green' \
      'mode=no-mistakes')
    state="$dir/state"
    window=fmtest:fm-sm
    key=fmtest_fm-sm
    arm_pr_poll "$state" sm https://github.com/EvanAgee/firstmate/pull/7 \
      || { fail "could not arm the merge watch fixture"; return; }
    seed_stale_pane "$dir" sm "$window" 'idle waiting for merge'
    export FM_FAKE_TMUX_CURRENT_COMMAND=zsh
    if [ "$hash_state" = absorbed ]; then
      export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
      run_until_stale_classified "$dir" "$window"
      [ -e "$state/.paused-$key" ] || fail "ordinary merge wait was not absorbed"
      [ ! -s "$state/.wake-queue" ] || fail "ordinary merge wait unexpectedly queued a wake"
      [ "$(cat "$state/.stale-$key" 2>/dev/null)" = "$(cat "$state/.hash-$key")" ] \
        || fail "ordinary merge wait did not record the pane hash"
      IFS= read -r recovery_token < "$state/.watcher-down"
      run_in_watcher "$dir" fm_recovery_marker_ack "$state/.watcher-down" "${recovery_token##*:}" \
        || { fail "could not acknowledge fixture watcher restart"; return; }
    fi
    export FM_FAKE_CREW_STATE='state: stalled · source: run-step · pipeline stalled 13h at review, run 01RUN, agent none'
    run_for_seconds "$dir" "$window" 60
    reason="stale: $window (pipeline stalled 13h at review, run 01RUN, agent none)"
    grep -qF "$reason" "$state/.wake-queue" 2>/dev/null \
      || fail "stalled validation behind $hash_state merge wait did not surface its diagnosis"
    [ ! -e "$state/.paused-$key" ] || fail "stalled validation retained merge-wait absorption"
    [ ! -e "$state/.stale-since-$key" ] || fail "stalled validation started a wedge timer"
  done
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  ok "stalled validation overrides an old green-PR announcement and armed merge watch"
}

# The negative that keeps the terminal branch honest: the SAME captain-relevant
# done: line with no armed merge watch must still surface exactly as before.
test_green_pr_without_an_armed_watch_still_surfaces() {
  local dir state window
  dir=$(make_wedge_case merge-dispatch-none mn \
    'done: PR https://github.com/EvanAgee/firstmate/pull/8 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-mn
  seed_stale_pane "$dir" mn "$window" 'idle with no watch'
  # Same dead-agent shape as the case above, so the ONLY difference between the
  # two is the armed merge watch.
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  run_until_stale_classified "$dir" "$window"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  if grep -qF "stale: $window" "$state/.wake-queue" 2>/dev/null; then
    ok "a done: PR line with no armed watch still surfaces as it did before"
  else
    fail "a done: line without an armed merge watch must still surface; queue: $(cat "$state/.wake-queue" 2>/dev/null)"
  fi
}

# The stalled tell (bin/fm-crew-state.sh's `state: stalled`) must never be
# absorbed by pause_state_class, exactly like any other non-working verdict.
test_stalled_run_step_is_not_absorbed_by_pause_class() {
  local dir out
  dir=$(make_wedge_case stalled-pause sp 'working: implementing' 'mode=no-mistakes')
  agent_gone
  export FM_FAKE_CREW_STATE='state: stalled · source: run-step · pipeline stalled 25m at review, run 01RUN, agent none'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-sp sp)
  unset FM_FAKE_CREW_STATE
  if [ "$out" = none ]; then
    ok "a stalled run-step is not absorbed by pause_state_class"
  else
    fail "a stalled run-step must classify none (surface), got '$out'"
  fi
}

test_declared_pause_preserves_stalled_diagnosis() {
  local dir state out timing presence
  for timing in fresh expired; do
    for presence in dead alive; do
      dir=$(make_wedge_case "stalled-$timing-$presence" sp 'paused: [key=await-merge] waiting for merge' 'mode=no-mistakes')
      state="$dir/state"
      : > "$state/.paused-fmtest_fm-sp"
      if [ "$timing" = fresh ]; then
        date +%s > "$state/.paused-rechecked-fmtest_fm-sp"
      else
        touch -t 200001010000 "$state/.paused-rechecked-fmtest_fm-sp"
      fi
      export FM_FAKE_TMUX_CURRENT_COMMAND=claude
      if [ "$presence" = alive ]; then agent_present sp; else agent_gone; fi
      export FM_FAKE_CREW_STATE='state: stalled · source: run-step · pipeline stalled 13h at review, run 01RUN, agent none'
      out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-sp sp)
      [ "$out" = stalled ] || fail "declared pause hid stalled diagnosis with $timing recheck and $presence agent: $out"
      [ ! -e "$state/.paused-rechecked-fmtest_fm-sp" ] || fail "stalled diagnosis retained pause recheck marker"
    done
  done
  unset FM_FAKE_CREW_STATE
  agent_gone
  unset FM_FAKE_TMUX_CURRENT_COMMAND
  ok "stalled diagnosis overrides declared pause before and after the recheck window"
}

test_paused_stalled_pipeline_surfaces_on_new_and_same_hash() {
  local dir state window key timing hash_state reason
  for timing in fresh expired; do
    for hash_state in new same; do
      dir=$(make_wedge_case "stalled-wake-$timing-$hash_state" sp 'paused: [key=await-merge] waiting for merge' 'mode=no-mistakes')
      state="$dir/state"
      window=fmtest:fm-sp
      key=fmtest_fm-sp
      seed_stale_pane "$dir" sp "$window" 'idle, agent gone'
      : > "$state/.paused-$key"
      date +%s > "$state/.paused-resurfaced-$key"
      if [ "$timing" = fresh ]; then
        date +%s > "$state/.paused-rechecked-$key"
      else
        touch -t 200001010000 "$state/.paused-rechecked-$key"
      fi
      if [ "$hash_state" = same ]; then
        cp "$state/.hash-$key" "$state/.stale-$key"
      fi
      agent_gone
      export FM_FAKE_CREW_STATE='state: stalled · source: run-step · pipeline stalled 13h at review, run 01RUN, agent none'
      FM_WEDGE_WINDOW=$window run_until_marker "$dir" "$state/.wake-queue"
      reason="stale: $window (pipeline stalled 13h at review, run 01RUN, agent none)"
      grep -qF "$reason" "$state/.wake-queue" 2>/dev/null || fail "paused stalled pipeline did not surface on $hash_state hash with $timing recheck"
      [ ! -e "$state/.stale-since-$key" ] || fail "stalled pipeline started a wedge timer"
    done
  done
  unset FM_FAKE_CREW_STATE
  ok "paused stalled pipelines surface detailed wakes for new and unchanged hashes"
}

# End-to-end: a worker whose status log carries a non-captain-relevant
# `working:` line (the ordinary shape while a pipeline is live) but whose
# crew state has gone `stalled` must surface through the real watcher process,
# with the crew's own diagnosis appended to the wake line - not a bare
# "stale: <endpoint>". Direct regression for the 2026-09-01 aos incident: four
# PRs sat 13 hours because their workers hit the Claude usage limit and the
# watcher's stale path absorbed the still-`running` pipeline as healthy work.
test_stalled_pipeline_surfaces_with_detail_on_the_wake_line() {
  local dir state window
  dir=$(make_wedge_case stalled-surface ss 'working: implementing' 'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-ss
  seed_stale_pane "$dir" ss "$window" 'idle, agent gone'
  export FM_FAKE_CREW_STATE='state: stalled · source: run-step · pipeline stalled 13h at review, run 01RUN, agent none'
  run_until_stale_classified "$dir" "$window"
  unset FM_FAKE_CREW_STATE
  if ! grep -qF "stale: $window" "$state/.wake-queue" 2>/dev/null; then
    fail "a stalled pipeline must surface; queue: $(cat "$state/.wake-queue" 2>/dev/null)"
  elif ! grep -qF "pipeline stalled 13h at review, run 01RUN, agent none" "$state/.wake-queue" 2>/dev/null; then
    fail "the wake line must carry the crew's stalled detail; queue: $(cat "$state/.wake-queue" 2>/dev/null)"
  else
    ok "a stalled pipeline surfaces with its detail appended to the wake line"
  fi
}

# The secondmate fail-open must not cost the cheap pause-cadence short-circuit.
# A secondmate whose crew state reports paused still writes the recheck marker,
# exactly where the pre-change code wrote it, so later polls short-circuit
# instead of re-running the expensive crew-state read every time.
test_secondmate_paused_still_writes_the_recheck_marker() {
  local dir state out
  dir=$(make_wedge_case secondmate-marker sk \
    'paused: [key=await-answer] waiting on captain')
  state="$dir/state"
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$state/sk.meta"
  rm -f "$state/sk.meta.bak"
  agent_gone
  export FM_FAKE_CREW_STATE='state: paused · source: run-step · awaiting an external decision'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-sk sk)
  unset FM_FAKE_CREW_STATE
  if [ "$out" != paused ]; then
    fail "a secondmate whose crew state is paused must classify paused, got '$out'"
  elif [ ! -e "$state/.paused-rechecked-fmtest_fm-sk" ]; then
    fail "a paused secondmate must still arm the pause-cadence recheck marker"
  else
    ok "a paused secondmate still writes its recheck marker"
  fi
}

# axi status renders sibling TOON tables from the same output. A `running` row
# in one of those is not an active step, and reading it as one would reset the
# wedge timer forever for a worker whose pipeline has actually stopped.
test_sibling_table_rows_are_not_active_steps() {
  local dir out
  dir=$(make_wedge_case sibling-table st 'working: implementing' 'mode=no-mistakes')
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[0]{step,status,active_for,last_activity,agent_pid,round}:
  gates[2]{gate,status,active_for,last_activity}:
    review,running,5m,"3s ago: reviewing the diff"
    tests,pending,0s,"never"')
  export FM_FAKE_AXI_STATUS
  out=$(run_in_watcher "$dir" pipeline_recently_active st && printf active || printf quiet)
  unset FM_FAKE_AXI_STATUS
  if [ "$out" = quiet ]; then
    ok "a running row in a sibling table is not read as an active step"
  else
    fail "an active_steps[0] table must yield no active step, got '$out'"
  fi
}

# `no-mistakes axi status` reports the active-or-most-recent run for the current
# branch, and falls back to some OTHER branch's run when this branch has none.
# On a fleet validating several crews at once, that unrelated run must not read
# as this task's live pipeline: it would reset the wedge timer and let a real
# wedge hide behind a sibling's activity forever.
test_unattributed_run_is_not_this_tasks_pipeline() {
  local dir out rc
  dir=$(make_wedge_case foreign-run fr 'working: implementing' 'mode=no-mistakes')
  # A perfectly fresh, actively running step - but on somebody else's branch.
  export FM_FAKE_AXI_STATUS='run:
  id: "01OTHER"
  branch: fm/some-other-crew
  status: running
  head: "0000000000000000000000000000000000000000"
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,2m,"3s ago: log: building","77305",starting'
  run_in_watcher "$dir" pipeline_activity_fresh fr
  rc=$?
  out=$(run_in_watcher "$dir" pipeline_recently_active fr && printf active || printf quiet)
  unset FM_FAKE_AXI_STATUS
  if [ "$rc" -ne 2 ]; then
    fail "an unattributed run must be the no-answer state (2), got $rc"
  elif [ "$out" != quiet ]; then
    fail "an unattributed run must not gate a wedge escalation, got '$out'"
  else
    ok "another branch's run is not read as this task's live pipeline"
  fi
}

# The awaiting-merge absorb must recognize a real announced PR, not the bare
# letters PR anywhere in free text. Absorbing an ordinary terminal worker is a
# worse failure than the false alarm this change fixes: it hides a finished
# worker that needed the captain behind the long pause cadence.
test_done_without_a_pr_url_is_not_awaiting_merge() {
  local dir state line
  for line in 'done: PR closed without merge' \
              'done: implemented; no PR yet' \
              'done: refactored PROVIDER lookup and stopped'; do
    dir=$(make_wedge_case "no-pr-$RANDOM" np "$line" 'mode=no-mistakes')
    state="$dir/state"
    arm_pr_poll "$state" np https://github.com/EvanAgee/firstmate/pull/3 \
      || { fail "could not arm the check fixture"; return; }
    agent_gone
    if run_in_watcher "$dir" finished_awaiting_merge fmtest:fm-np np; then
      fail "a done: line with no PR URL must not be absorbed as awaiting merge: $line"
      return
    fi
  done
  # Positive control: the same shape WITH a real PR URL must still be absorbed,
  # so the negatives above cannot be passing for an unrelated reason.
  dir=$(make_wedge_case with-pr wp2 \
    'done: PR https://github.com/EvanAgee/firstmate/pull/12 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  arm_pr_poll "$state" wp2 https://github.com/EvanAgee/firstmate/pull/12 \
    || { fail "could not arm the check fixture"; return; }
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  FM_FAKE_TMUX_WINDOW=fmtest:fm-wp2
  export FM_FAKE_TMUX_WINDOW
  if run_in_watcher "$dir" finished_awaiting_merge fmtest:fm-wp2 wp2; then
    ok "only a real announced PR URL counts as a finished worker awaiting merge"
  else
    fail "a done: line with a real PR URL must still be absorbed as awaiting merge"
  fi
  unset FM_FAKE_TMUX_CURRENT_COMMAND FM_FAKE_TMUX_WINDOW
}

# The declared row count bounds the scan, but only real data rows may spend it.
# A blank line between rows must not exhaust the budget and hide a running step
# further down - that reports a moving pipeline as quiet, the exact 2026-09-01
# false alarm this change targets.
test_blank_line_between_rows_does_not_hide_a_running_step() {
  local dir out
  dir=$(make_wedge_case spaced-rows sr 'working: implementing' 'mode=no-mistakes')
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[2]{step,status,active_for,last_activity,agent_pid,round}:
    lint,done,1m,"1s ago: log: lint clean","77300",starting

    ci,running,2m,"3s ago: log: building","77305",starting')
  export FM_FAKE_AXI_STATUS
  out=$(run_in_watcher "$dir" pipeline_recently_active sr && printf active || printf quiet)
  unset FM_FAKE_AXI_STATUS
  if [ "$out" = active ]; then
    ok "a blank line between rows does not hide a running step"
  else
    fail "a running row after a blank line must still read active, got '$out'"
  fi
}

# A running row IS positive evidence the run exists. If its last_activity cannot
# be read, that is a failure to measure freshness (the no-answer state), never
# proof the pipeline halted - otherwise a mid-run worker escalates as a wedge
# despite a visibly running step.
test_unreadable_activity_is_no_answer_not_a_stop() {
  local dir rc activity
  for activity in '"just now"' '""' '"starting"' '-'; do
    dir=$(make_wedge_case "odd-activity-$RANDOM" oa 'working: implementing' 'mode=no-mistakes')
    FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" "  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,2m,$activity,\"77305\",starting")
    export FM_FAKE_AXI_STATUS
    run_in_watcher "$dir" pipeline_activity_fresh oa
    rc=$?
    unset FM_FAKE_AXI_STATUS
    if [ "$rc" -ne 2 ]; then
      fail "a running row with unreadable activity $activity must be no-answer (2), got $rc"
      return
    fi
  done
  ok "an unreadable last_activity is the no-answer state, not a hard negative"
}

# The same finished green-PR worker on the REPEAT-hash sub-path of the terminal
# branch: a wedge timer is already running for this exact pane hash. The
# awaiting-merge absorb must win there too, or the worker keeps climbing the
# wedge ladder one poll later.
test_green_pr_awaiting_merge_absorbed_on_a_repeat_hash() {
  local dir state window key
  dir=$(make_wedge_case merge-repeat mr \
    'done: PR https://github.com/EvanAgee/firstmate/pull/9 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-mr
  key=$(printf '%s' "$window" | tr ':/.' '___')
  arm_pr_poll "$state" mr https://github.com/EvanAgee/firstmate/pull/9 \
    || { fail "could not arm the merge watch fixture"; return; }
  seed_stale_pane "$dir" mr "$window" 'idle awaiting merge again'
  # This hash was already classified, and a wedge timer is running past the
  # window: without the absorb, the next poll escalates it.
  printf '%s' "$(hash_text 'idle awaiting merge again')" > "$state/.stale-$key"
  printf '%s' "$(( $(date +%s) - 99999 ))" > "$state/.stale-since-$key"
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  # The .stale-<key> suppressor is already seeded here, so wait on the absorb's
  # own marker instead: the poll either writes .paused-<key> or queues a wake.
  FM_WEDGE_WINDOW=$window run_until_marker "$dir" "$state/.paused-$key"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  if grep -q 'possible wedge' "$state/.wake-queue" 2>/dev/null; then
    fail "a finished green-PR worker wedge-escalated on the repeat-hash path"
  elif [ -e "$state/.stale-since-$key" ]; then
    fail "a finished green-PR worker kept its wedge timer on the repeat-hash path"
  elif [ ! -e "$state/.paused-$key" ]; then
    fail "a finished green-PR worker was not absorbed on the repeat-hash path"
  else
    ok "the awaiting-merge absorb also wins on the repeat-hash path"
  fi
}

# state/<id>.check.sh is the GENERIC custom-check path, not a PR-watch marker:
# bin/fm-check-register.sh registers arbitrary bytes there for any task. A
# worker holding an unrelated custom check is not awaiting a merge, and parking
# it on the pause cadence would hide a finished worker who needed the captain.
test_unrelated_custom_check_is_not_an_armed_merge_watch() {
  local dir state window
  dir=$(make_wedge_case custom-check cc \
    'done: work complete, superseding https://github.com/EvanAgee/firstmate/pull/12 - needs a captain call' \
    'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-cc
  # A real, registered custom check that is NOT a PR poll.
  arm_custom_check "$state" cc || { fail "could not arm the custom check fixture"; return; }
  seed_stale_pane "$dir" cc "$window" 'idle after finishing'
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: done · source: run-step · finished'
  run_until_stale_classified "$dir" "$window"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  if grep -qF "stale: $window" "$state/.wake-queue" 2>/dev/null; then
    ok "an unrelated custom check is not an armed merge watch, so the worker surfaces"
  else
    fail "a worker with only a custom check must still surface; queue: $(cat "$state/.wake-queue" 2>/dev/null)"
  fi
}

# The decisive case, and the one the single-run cases cannot reach: wake() exits
# the watcher process after it reports one wake, so a supervisor restarts it and
# the next cycle begins with the same state on disk. handle_paused_stale fires at
# most one re-surface per PAUSE_RESURFACE_SECS, and .paused-resurfaced-<key> is
# what enforces that ACROSS those restarts. A wake every restart would be
# strictly worse than the wedge ladder this change replaced.
test_awaiting_merge_absorb_stays_throttled_across_restarts() {
  local dir state window wakes
  dir=$(make_wedge_case merge-throttle mt \
    'done: PR https://github.com/EvanAgee/firstmate/pull/11 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-mt
  arm_pr_poll "$state" mt https://github.com/EvanAgee/firstmate/pull/11 \
    || { fail "could not arm the merge watch fixture"; return; }
  # Backdate the status file past the re-surface window so the FIRST absorb is
  # entitled to one wake. This happens BEFORE seeding the pane, because
  # seed_stale_pane primes the .seen-* suppressor from the status signature.
  touch -t 202001010000 "$state/mt.status"
  seed_stale_pane "$dir" mt "$window" 'idle waiting for merge'
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  for _ in 1 2 3; do
    run_for_seconds "$dir" "$window" 14 FM_PAUSE_RESURFACE_SECS=3600
    drain_wakes "$state"
  done
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  wakes=$(count_stale_wakes "$state" "$window")
  if [ "$wakes" -gt 1 ]; then
    fail "a finished green-PR worker re-surfaced $wakes times inside one pause window"
  else
    ok "an absorbed green-PR worker re-surfaces at most once per pause window"
  fi
}

# The other side of that throttle: the absorb must not silence the worker
# forever. With a one-second window the recheck is due again immediately, so a
# permanently silenced worker would queue nothing at all.
test_awaiting_merge_absorb_resurfaces_once_the_window_elapses() {
  local dir state window wakes
  dir=$(make_wedge_case merge-resurface ms \
    'done: PR https://github.com/EvanAgee/firstmate/pull/13 checks green' \
    'mode=no-mistakes')
  state="$dir/state"
  window=fmtest:fm-ms
  arm_pr_poll "$state" ms https://github.com/EvanAgee/firstmate/pull/13 \
    || { fail "could not arm the merge watch fixture"; return; }
  touch -t 202001010000 "$state/ms.status"
  seed_stale_pane "$dir" ms "$window" 'idle waiting for merge'
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  run_for_seconds "$dir" "$window" 14 FM_PAUSE_RESURFACE_SECS=1
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  wakes=$(count_stale_wakes "$state" "$window")
  if [ "$wakes" -lt 1 ]; then
    fail "an absorbed green-PR worker never re-surfaced after its window elapsed"
  else
    ok "an absorbed green-PR worker still re-surfaces once its window elapses"
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

# Arm <id>'s busy-state contract and close its turn through the real writer,
# exactly as a fm-spawn-armed Claude worker's Stop hook leaves it.
record_turn_ended() {  # <state> <id>
  "$ROOT/bin/fm-busy-event.sh" arm "$1" "$2" >/dev/null \
    && "$ROOT/bin/fm-busy-event.sh" apply "$1" "$2" idle --current-gen \
      --source claude-hook --event stop >/dev/null
}

# Bare `stale: <window>` wakes queued for <window>, as a plain integer.
count_bare_stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || printf '0'
}

# The 2026-09-23 macpro-bench-branch shape: a live Claude worker declared a
# pause, armed its own CI monitor, and ended its turn. Every fresh idle pane it
# showed woke firstmate with a bare stale. A turn its own Stop hook closed holds
# no decision gate open, so its declared pause must win over its liveness.
test_parked_live_pause_absorbs_each_new_idle_pane() {
  local dir state window key round bare
  dir=$(make_wedge_case parked-live pk \
    'paused: [key=bench-runs] tuned run in progress, monitor armed')
  state="$dir/state"
  window=fmtest:fm-pk
  key=$(printf '%s' "$window" | tr ':/.' '___')
  record_turn_ended "$state" pk || { fail "could not record the ended turn"; return; }
  seed_stale_pane "$dir" pk "$window" 'idle at prompt · 1 monitor (round 1)'
  FM_FAKE_TMUX_CURRENT_COMMAND=claude
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · tuned run in progress, monitor armed'
  for round in 1 2 3; do
    printf 'idle at prompt · 1 monitor (round %s)' "$round" > "$dir/pane.txt"
    run_for_seconds "$dir" "$window" 8 FM_PAUSE_RESURFACE_SECS=3600
    drain_wakes "$state"
  done
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  bare=$(count_bare_stale_wakes "$state" "$window")
  if [ "$bare" -ne 0 ]; then
    fail "a parked live worker woke firstmate with $bare bare stale wakes across three idle panes"
  elif [ ! -e "$state/.paused-$key" ]; then
    fail "a parked live worker was not put on the pause cadence"
  else
    ok "a parked live worker's new idle panes join the pause cadence without a bare stale wake"
  fi
}

# The other side: parking must not silence the worker forever. Past the pause
# window the same worker re-surfaces once with the paused-recheck reason.
test_parked_live_pause_rechecks_on_the_long_cadence() {
  local dir state window bare recheck
  dir=$(make_wedge_case parked-recheck pq \
    'paused: [key=bench-runs] confirmation run in progress, monitor armed')
  state="$dir/state"
  window=fmtest:fm-pq
  record_turn_ended "$state" pq || { fail "could not record the ended turn"; return; }
  touch -t 202001010000 "$state/pq.status"
  seed_stale_pane "$dir" pq "$window" 'idle at prompt · 1 monitor'
  FM_FAKE_TMUX_CURRENT_COMMAND=claude
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · confirmation run in progress, monitor armed'
  run_for_seconds "$dir" "$window" 10 FM_PAUSE_RESURFACE_SECS=1
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND
  bare=$(count_bare_stale_wakes "$state" "$window")
  recheck=$(grep -F "stale: $window (paused " "$state/.wake-queue" 2>/dev/null \
    | grep -c -F 'awaiting external - declared pause, rechecked on a long cadence' || true)
  if [ "$bare" -ne 0 ]; then
    fail "a parked live worker surfaced a bare stale wake instead of its recheck"
  elif [ "${recheck:-0}" -ne 1 ]; then
    fail "a parked live worker past its pause window queued $recheck rechecks, want 1; queue: $(cat "$state/.wake-queue" 2>/dev/null)"
  else
    ok "a parked live worker re-surfaces once with the paused recheck past its window"
  fi
}

poll_stalled_case() {
  local dir=$1 win=$2 state key target pid deadline count recovery_token sequence reason completed=0
  state="$dir/state"
  key=$(printf '%s' "$win" | tr ':/.' '___')
  target=$(( $(cat "$state/.count-$key" 2>/dev/null || echo 0) + 2 ))
  sequence=$(cat "$state/.wake-queue.seq" 2>/dev/null || echo 0)
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      reason=$(cat "$dir/watch.out")
      if wait "$pid" && awk -F '\t' -v sequence="$sequence" -v reason="$reason" -v win="$win" '
        $2 > sequence && $3 == "stale" && $5 == reason &&
          ($4 == win || index($4, win "|pipeline-stall|") == 1) { found=1 }
        END { exit !found }
      ' "$state/.wake-queue" 2>/dev/null; then
        completed=1
        break
      fi
      fail "watcher exited before required polls or a new wake publication"
      return 1
    fi
    count=$(cat "$state/.count-$key" 2>/dev/null || echo 0)
    if [ "$count" -ge "$target" ] && [ ! -s "$state/.wake-queue" ]; then
      completed=1
      break
    fi
    sleep 0.2
  done
  reap "$pid"
  if [ ! -s "$state/.wake-queue" ] && [ -e "$state/.watcher-down" ]; then
    IFS= read -r recovery_token < "$state/.watcher-down"
    run_in_watcher "$dir" fm_recovery_marker_ack "$state/.watcher-down" "${recovery_token##*:}" \
      || { fail "could not acknowledge fixture watcher restart"; return 1; }
  fi
  [ "$completed" = 1 ] || { fail "watcher did not complete the polling sequence"; return 1; }
}

ack_poll_wake() {
  local dir=$1
  FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"
  ack_drain_err "$dir/state" "$dir/drain.err" >/dev/null \
    || { fail "could not acknowledge watcher wake"; return 1; }
}

poll_wake_payload() {
  cut -f5- "$1/state/.wake-queue"
}

set_poll_pipeline_activity() {
  local dir=$1 duration=$2
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" "  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,$duration,\"quiet $duration ago: log: last activity\",\"-\",fix 1")
  if [ "$duration" = 15m ]; then
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  else
    FM_FAKE_CREW_STATE="state: stalled · source: run-step · pipeline stalled $duration at review, run 01RUN, agent none"
  fi
  export FM_FAKE_AXI_STATUS FM_FAKE_CREW_STATE
}

poll_stall_after_generic_wedge() {
  local status=$1 dir state win key expected sequence
  dir=$(make_wedge_case "poll-wedge-$status" ps "$status: earlier validation work" 'mode=no-mistakes')
  state="$dir/state"
  win=fmtest:fm-ps
  key=fmtest_fm-ps
  seed_stale_pane "$dir" ps "$win" 'unchanged idle validation pane'
  cp "$state/.hash-$key" "$state/.stale-$key"
  printf '1\n' > "$state/.stale-since-$key"
  set_poll_pipeline_activity "$dir" 15m
  poll_stalled_case "$dir" "$win" || return
  case "$(poll_wake_payload "$dir")" in
    "stale: $win (idle "*"possible wedge"*) ;;
    *) fail "$status did not publish the initial generic wedge"; return ;;
  esac
  [ ! -e "$state/.stale-since-$key" ] || fail "$status generic wedge retained its timer"
  sequence=$(cat "$state/.wake-queue.seq")
  ack_poll_wake "$dir" || return
  set_poll_pipeline_activity "$dir" 25m
  poll_stalled_case "$dir" "$win" || return
  expected="stale: $win (pipeline stalled 25m at review, run 01RUN, agent none)"
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "$status poll lost the detailed stall after generic escalation"
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "$status stall did not publish exactly once"
  [ "$(cat "$state/.hash-$key")" = "$(cat "$state/.stale-$key")" ] || fail "$status pane hash changed during the transition"
  unset FM_FAKE_AXI_STATUS FM_FAKE_CREW_STATE
}

test_poll_reports_stall_after_generic_wedge_removed_timer() {
  poll_stall_after_generic_wedge working
  ok "full poll surfaces a stall after generic wedge timer removal"
}

test_poll_reports_stall_over_old_terminal_status_without_timer() {
  poll_stall_after_generic_wedge 'done'
  poll_stall_after_generic_wedge blocked
  ok "full poll surfaces stalls over old done and blocked statuses without timers"
}

run_poll_daemon() {
  local dir=$1
  shift
  (
    export PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state"
    export FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
    export FM_FAKE_TMUX_WINDOW=fmtest:fm-ps FM_FAKE_TMUX_CAPTURE="$dir/pane.txt"
    export FM_ESCALATE_BATCH_SECS=999999 FM_MAX_DEFER_SECS=999999 FM_STALE_ESCALATE_SECS=240
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-supervise-daemon.sh"
    # shellcheck disable=SC2034 # Read by the sourced daemon functions.
    LOG="$dir/daemon.log"
    "$@" "$dir/state"
  )
}

run_poll_daemon_confirmed_flush() {
  local dir=$1
  (
    export PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state"
    export FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
    export FM_FAKE_TMUX_WINDOW=fmtest:fm-ps FM_FAKE_TMUX_CAPTURE="$dir/pane.txt"
    # shellcheck source=bin/fm-supervise-daemon.sh
    . "$ROOT/bin/fm-supervise-daemon.sh"
    # shellcheck disable=SC2034 # Read by the sourced daemon functions.
    LOG="$dir/daemon.log"
    inject_msg() { return 0; }
    escalate_flush "$dir/state"
  )
}

test_away_poll_reports_stall_after_generic_escalation_removed_marker() {
  local dir state win key reason expected sequence generic expected_buffer
  dir=$(make_wedge_case poll-away-stall ps 'working: validating' 'mode=no-mistakes')
  state="$dir/state"
  win=fmtest:fm-ps
  key=fmtest_fm-ps
  seed_stale_pane "$dir" ps "$win" 'unchanged idle validation pane'
  : > "$state/.afk"
  set_poll_pipeline_activity "$dir" 15m
  poll_stalled_case "$dir" "$win" || return
  reason=$(poll_wake_payload "$dir")
  [ "$reason" = "stale: $win" ] || fail "ordinary away poll changed its wake"
  run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
    || { fail "daemon could not ingest and acknowledge the ordinary away wake"; return; }
  [ -e "$state/.subsuper-stale-ps" ] || fail "away wake did not start stale tracking"
  [ ! -s "$state/.wake-queue" ] || fail "daemon did not acknowledge the consumed wake"
  printf '1\n' > "$state/.subsuper-stale-ps"
  run_poll_daemon "$dir" housekeeping
  grep -q 'possible wedge' "$state/.subsuper-escalations" || fail "away persistence did not publish a generic wedge"
  [ ! -e "$state/.subsuper-stale-ps" ] || fail "away generic escalation retained its stale marker"
  generic=$(cat "$state/.subsuper-escalations")
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" = 1 ] || fail "generic escalation was not buffered exactly once"
  set_poll_pipeline_activity "$dir" 25m
  poll_stalled_case "$dir" "$win" || return
  expected="stale: $win (pipeline stalled 25m at review, run 01RUN, agent none)"
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "away poll hid the stalled transition after marker removal"
  run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
    || { fail "daemon could not ingest and acknowledge the stalled wake"; return; }
  expected_buffer=$(printf '%s\n%s' "$generic" "$expected")
  [ "$(cat "$state/.subsuper-escalations")" = "$expected_buffer" ] || fail "daemon changed or lost the detailed escalation buffer"
  [ "$(cat "$state/.subsuper-stalled-ps")" = 'review, run 01RUN, agent none' ] || fail "daemon did not record the stalled identity"
  sequence=$(cat "$state/.wake-queue.seq")
  [ ! -s "$state/.wake-queue" ] || fail "daemon did not acknowledge the consumed wake"
  set_poll_pipeline_activity "$dir" 26m
  poll_stalled_case "$dir" "$win" || return
  run_poll_daemon "$dir" housekeeping
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "away poll repeated the same stall"
  [ "$(cat "$state/.subsuper-escalations")" = "$expected_buffer" ] || fail "daemon repeated or changed a buffered escalation"
  unset FM_FAKE_AXI_STATUS FM_FAKE_CREW_STATE
  ok "away polling reports stalls after generic escalation and buffers them once"
}

test_away_recovery_rearms_stall_without_housekeeping() {
  local dir state win expected sequence episode expected_buffer
  dir=$(make_wedge_case away-recovery-episode ps 'working: validating' 'mode=no-mistakes')
  state="$dir/state"
  win=fmtest:fm-ps
  seed_stale_pane "$dir" ps "$win" 'unchanged idle validation pane'
  : > "$state/.afk"
  expected="stale: $win (pipeline stalled 25m at review, run 01RUN, agent none)"
  expected_buffer=""
  for episode in 1 2; do
    set_poll_pipeline_activity "$dir" 25m
    poll_stalled_case "$dir" "$win" || return
    [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "episode $episode lost its stalled wake"
    run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
      || { fail "episode $episode failed durable ingestion"; return; }
    if [ "$episode" = 1 ]; then expected_buffer=$expected; else expected_buffer=$(printf '%s\n%s' "$expected" "$expected"); fi
    [ "$(cat "$state/.subsuper-escalations")" = "$expected_buffer" ] || fail "daemon discarded or duplicated episode $episode"
    [ ! -s "$state/.wake-queue" ] || fail "daemon did not acknowledge episode $episode"
    sequence=$(cat "$state/.wake-queue.seq")
    set_poll_pipeline_activity "$dir" 26m
    poll_stalled_case "$dir" "$win" || return
    [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "episode $episode repeated on the watcher"
    append_wake "$state" stale "$win" "$expected"
    run_poll_daemon "$dir" handle_durable_wakes "$expected" \
      || { fail "episode $episode replay failed durable ingestion"; return; }
    [ "$(cat "$state/.subsuper-escalations")" = "$expected_buffer" ] || fail "daemon repeated episode $episode on replay"
    [ ! -s "$state/.wake-queue" ] || fail "daemon did not acknowledge episode $episode replay"
    if [ "$episode" = 1 ]; then
      set_poll_pipeline_activity "$dir" 15m
      poll_stalled_case "$dir" "$win" || return
      [ ! -e "$state/.stale-since-fmtest_fm-ps.stalled" ] || fail "watcher did not observe recovery"
      [ -e "$state/.subsuper-stalled-ps" ] || fail "fixture unexpectedly cleared daemon identity during recovery"
      if [ -s "$state/.wake-queue" ]; then
        run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
          || { fail "recovery poll failed durable ingestion"; return; }
      fi
    fi
  done
  unset FM_FAKE_AXI_STATUS FM_FAKE_CREW_STATE
  ok "watcher recovery rearms the same stalled identity without daemon housekeeping"
}

make_shared_episode_case() {
  local dir
  dir=$(make_wedge_case "$1" ps 'working: validating' 'mode=no-mistakes')
  seed_stale_pane "$dir" ps fmtest:fm-ps 'unchanged idle validation pane'
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/axi-status"
SH
  chmod +x "$dir/fakebin/no-mistakes"
  printf '#!/usr/bin/env bash\nset -o pipefail\nREAL_CREW_STATE=%q\n' "$ROOT/bin/fm-crew-state.sh" > "$dir/fakebin/fm-crew-state.sh"
  cat >> "$dir/fakebin/fm-crew-state.sh" <<'SH'
if [ -e "$FM_HOME/barriers" ] && [ -n "${FM_TEST_DETECTOR:-}" ] && [ ! -e "$FM_HOME/$FM_TEST_DETECTOR.read" ]; then
  : > "$FM_HOME/$FM_TEST_DETECTOR.read"
  while [ ! -e "$FM_HOME/$FM_TEST_DETECTOR.release" ]; do sleep 0.05; done
  : > "$FM_HOME/$FM_TEST_DETECTOR.departed"
fi
if [ -e "$FM_HOME/unknown" ]; then
  printf '%s\n' 'state: unknown · source: none · temporarily unreadable'
else
  "$REAL_CREW_STATE" "$@" | tee "$FM_HOME/crew-observation"
fi
SH
  shared_episode_status "$dir" -
  : > "$dir/state/.afk"
  printf '%s' "$dir"
}

shared_episode_status() {
  axi_status_for "$1" "  awaiting_agent: parked 25m
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,25m,\"quiet 25m ago: log: last activity\",\"$2\",fix 1" > "$1/axi-status"
}

shared_episode_recover() {
  local dir=$1 reader=${2:-daemon} pid result
  sleep 120 &
  pid=$!
  shared_episode_status "$dir" "$pid"
  if [ "$reader" = daemon ]; then
    run_poll_daemon "$dir" housekeeping
  else
    run_in_watcher "$dir" crew_state_line ps > "$dir/recovery-observation"
  fi
  result=$?
  reap "$pid"
  shared_episode_status "$dir" -
  [ "$result" = 0 ] || { fail "shared episode recovery read failed"; return 1; }
  [ "$(cat "$dir/crew-observation")" = 'state: working · source: run-step · validating (running)' ] \
    || { fail "recovery did not observe a live awaiting-agent PID"; return 1; }
}

shared_episode_ingest() {
  run_poll_daemon "$1" handle_durable_wakes 'stale: fmtest:fm-ps' \
    || { fail "shared episode durable ingestion failed"; return 1; }
  [ ! -s "$1/state/.wake-queue" ] || { fail "shared episode rows were not acknowledged"; return 1; }
}

shared_episode_buffer() {
  local dir=$1 count=$2 expected='' i
  for ((i=0; i<count; i++)); do
    [ -z "$expected" ] || expected="$expected"$'\n'
    expected="${expected}stale: fmtest:fm-ps (pipeline stalled 25m at review, run 01RUN, agent none)"
  done
  [ "$(cat "$dir/state/.subsuper-escalations" 2>/dev/null)" = "$expected" ] \
    || fail "expected exactly $count detailed episode lines"
}

shared_episode_pending_poll() {
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" > "$1/pending-drain.out" 2> "$1/pending-drain.err" || return 1
  FM_WATCH_HANDLING_SUCCESSOR=1 poll_stalled_case "$1" fmtest:fm-ps
}

shared_episode_wait_file() {
  local deadline=$(( $(date +%s) + 90 ))
  while [ ! -e "$1" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { fail "timed out waiting for $1"; return 1; }
    sleep 0.05
  done
}

fail_stall_publication_after_queue() {
  local dir=$1 state marker detail pane_hash
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  detail='pipeline stalled 25m at review, run 01RUN, agent none'
  pane_hash=$(cat "$state/.hash-fmtest_fm-ps")
  mkdir "$marker"
  if run_in_watcher "$dir" crew_stall_transition "$state" ps fmtest:fm-ps begin "$detail" "$pane_hash" 0 \
    > "$dir/failed-publication.out" 2> "$dir/failed-publication.err"; then
    fail "active marker write fault was reported as success"
    rmdir "$marker"
    return 1
  fi
  rmdir "$marker"
  [ "$(wc -l < "$state/.wake-queue" | tr -d ' ')" = 1 ] || { fail "publication fault did not retain exactly one queued episode"; return 1; }
  [ "$(cat "$marker.generation")" = 1 ] || { fail "publication fault did not retain its generation"; return 1; }
}

poll_resumed_stall_case() {
  local dir=$1 win=$2 expected=$3 state pid deadline sequence
  state="$dir/state"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/resumed-drain.out" 2> "$dir/resumed-drain.err" \
    || { fail "daemon handoff could not select the queued episode"; return 1; }
  sequence=$(cat "$state/.wake-queue.seq")
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/resumed-watch.out" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + 60 ))
  while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null; then
    reap "$pid"
    fail "watcher did not resume the queued episode"
    return 1
  fi
  wait "$pid" || { fail "watcher failed while resuming the queued episode"; return 1; }
  [ "$(cat "$dir/resumed-watch.out")" = "$expected" ] \
    || { fail "resumed watcher lost the stalled wake: $(cat "$dir/resumed-watch.out")"; return 1; }
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || { fail "resumed watcher appended a second episode"; return 1; }
}

test_stall_publication_fault_resumes_queued_episode() {
  local dir state marker detail expected episode
  dir=$(make_shared_episode_case publication-resume)
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  detail='pipeline stalled 25m at review, run 01RUN, agent none'
  expected="stale: fmtest:fm-ps ($detail)"
  fail_stall_publication_after_queue "$dir" || return
  episode=$(cut -f4 "$state/.wake-queue")
  poll_resumed_stall_case "$dir" fmtest:fm-ps "$expected" || return
  [ "$(cut -f4 "$state/.wake-queue")" = "$episode" ] || fail "resumed publication changed its immutable binding"
  [ "$(cat "$marker")" = 'review, run 01RUN, agent none' ] || fail "resumed publication did not restore its active identity"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 1
  [ "$(sed -n '2,$p' "$state/.subsuper-stalled-ps.generation")" = '1|review, run 01RUN, agent none' ] \
    || fail "resumed publication did not commit one receipt identity"
  ok "publication replay resumes one queued episode without advancing its generation"
}

test_recovery_prevents_resuming_an_old_queued_episode() {
  local dir state keys
  dir=$(make_shared_episode_case publication-recovery)
  state="$dir/state"
  fail_stall_publication_after_queue "$dir" || return
  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  keys=$(cut -f4 "$state/.wake-queue")
  [ "$keys" = "$(printf '%s\n%s' \
    'fmtest:fm-ps|pipeline-stall|1|review, run 01RUN, agent none' \
    'fmtest:fm-ps|pipeline-stall|3|review, run 01RUN, agent none')" ] \
    || fail "known recovery resumed an older queued episode"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  [ "$(sed -n '2,$p' "$state/.subsuper-stalled-ps.generation" | wc -l | tr -d ' ')" = 2 ] \
    || fail "known recovery did not deliver both true episodes once"
  ok "known recovery keeps the old binding and publishes a fresh episode"
}

shared_episode_barrier_after_read() {
  printf '#!/usr/bin/env bash\nREAL_CREW_STATE=%q\n' "$ROOT/bin/fm-crew-state.sh" > "$1/fakebin/fm-crew-state.sh"
  cat >> "$1/fakebin/fm-crew-state.sh" <<'SH'
line=$("$REAL_CREW_STATE" "$@") || exit $?
printf '%s\n' "$line" > "$FM_HOME/crew-observation"
if [ -n "${FM_TEST_DETECTOR:-}" ] && [ ! -e "$FM_HOME/$FM_TEST_DETECTOR.departed" ]; then
  printf '%s\n' "$line" > "$FM_HOME/$FM_TEST_DETECTOR.read"
  while [ ! -e "$FM_HOME/$FM_TEST_DETECTOR.release" ]; do sleep 0.05; done
  : > "$FM_HOME/$FM_TEST_DETECTOR.departed"
fi
printf '%s\n' "$line"
SH
}

test_late_healthy_observation_cannot_rearm_current_stall() {
  local dir state marker daemon_pid live_pid generation queued sequence receipt
  dir=$(make_shared_episode_case late-healthy-observation)
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_ingest "$dir" || return
  shared_episode_recover "$dir" || return
  generation=$(cat "$marker.generation")
  [ ! -e "$marker" ] || fail "reverse barrier started with an active marker"
  shared_episode_barrier_after_read "$dir"
  sleep 120 &
  live_pid=$!
  shared_episode_status "$dir" "$live_pid"
  FM_TEST_DETECTOR=daemon run_poll_daemon "$dir" housekeeping > "$dir/daemon-run.out" 2>&1 &
  daemon_pid=$!
  shared_episode_wait_file "$dir/daemon.read" || { reap "$daemon_pid"; reap "$live_pid"; return 1; }
  [ "$(cat "$dir/daemon.read")" = 'state: working · source: run-step · validating (running)' ] || fail "reverse barrier did not capture a healthy observation"
  reap "$live_pid"
  shared_episode_status "$dir" -
  poll_stalled_case "$dir" fmtest:fm-ps || { reap "$daemon_pid"; return 1; }
  queued=$(cat "$state/.wake-queue")
  [ "$(cat "$marker.generation")" -eq "$((generation + 1))" ] || fail "begin did not fence the delayed healthy observation"
  : > "$dir/daemon.release"
  wait "$daemon_pid" || { fail "delayed daemon recovery failed"; return 1; }
  [ "$(cat "$marker.generation")" -eq "$((generation + 1))" ] && [ -e "$marker" ] || fail "superseded healthy observation rearmed the current death"
  [ "$(cat "$state/.wake-queue")" = "$queued" ] || fail "delayed recovery changed the queued binding"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" fmtest:fm-ps || return
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "unchanged poll repeated the current death"
  [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "unchanged episode changed its receipt"
  [ "$(cat "$marker.generation")" -eq "$((generation + 1))" ] || fail "joining the current identity advanced the fence"
  shared_episode_buffer "$dir" 2
  ok "a delayed healthy daemon read cannot rearm a newer watcher stall"
}

test_changed_stall_identity_supersedes_older_observation() {
  local dir state marker daemon_pid generation expected receipt sequence
  dir=$(make_shared_episode_case changed-stall-identity)
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_ingest "$dir" || return
  generation=$(cat "$marker.generation")
  shared_episode_barrier_after_read "$dir"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  FM_TEST_DETECTOR=daemon run_poll_daemon "$dir" handle_durable_wakes 'stale: fmtest:fm-ps' > "$dir/daemon-run.out" 2>&1 &
  daemon_pid=$!
  shared_episode_wait_file "$dir/daemon.read" || { reap "$daemon_pid"; return 1; }
  [ "$(cat "$dir/daemon.read")" = 'state: stalled · source: run-step · pipeline stalled 25m at review, run 01RUN, agent none' ] || fail "changed-identity barrier lost its older observation"
  sed 's/review,running/lint,running/' "$dir/axi-status" > "$dir/axi.changed"
  mv "$dir/axi.changed" "$dir/axi-status"
  FM_WATCH_HANDLING_SUCCESSOR=1 poll_stalled_case "$dir" fmtest:fm-ps || { reap "$daemon_pid"; return 1; }
  [ "$(cat "$marker.generation")" -eq "$((generation + 1))" ] || fail "changed identity did not advance the fence"
  : > "$dir/daemon.release"
  wait "$daemon_pid" || { fail "old generic observation failed acknowledgement"; return 1; }
  shared_episode_ingest "$dir" || return
  expected=$(printf '%s\n%s' 'stale: fmtest:fm-ps (pipeline stalled 25m at review, run 01RUN, agent none)' 'stale: fmtest:fm-ps (pipeline stalled 25m at lint, run 01RUN, agent none)')
  [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "old observation duplicated or replaced the changed identity"
  [ "$(cat "$marker")" = 'lint, run 01RUN, agent none' ] || fail "old observation restored its superseded identity"
  [ "$(cat "$marker.generation")" -eq "$((generation + 1))" ] || fail "old observation changed the fence"
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" fmtest:fm-ps || return
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "changed identity repeated on the watcher"
  [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] && [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "changed identity repeated on the daemon"
  ok "a changed stalled identity fences older samples and delivers once"
}

shared_episode_retire_waiting_delivery() {
  local dir=$1 meta_lock
  meta_lock=$(fm_meta_lock_path "$dir/state/ps.meta") || return 1
  fm_lock_acquire_wait "$meta_lock" || return 1
  trap 'fm_lock_release "$FM_WAKE_QUEUE_LOCK"; fm_lock_release "$meta_lock"' EXIT
  : > "$dir/retirement-ready"
  shared_episode_wait_file "$dir/delivery-waiting" || return 1
  fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK" || { fail "delivery held the queue lock while waiting for metadata"; return 1; }
  rm "$dir/state/ps.meta"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fm_lock_release "$meta_lock"
  trap - EXIT
}

test_retired_task_drops_queued_stall_without_touching_receipts() {
  local prior dir state receipt queued holder daemon_pid expected
  for prior in absent present; do
    dir=$(make_shared_episode_case "retired-stall-$prior")
    state="$dir/state"
    receipt="$state/.subsuper-stalled-ps"
    poll_stalled_case "$dir" fmtest:fm-ps || return
    expected=''
    if [ "$prior" = present ]; then
      shared_episode_ingest "$dir" || return
      shared_episode_recover "$dir" || return
      poll_stalled_case "$dir" fmtest:fm-ps || return
      cp "$receipt" "$dir/prior-receipt"
      cp "$receipt.generation" "$dir/prior-generation"
      expected=$(cat "$state/.subsuper-escalations")
    fi
    queued=$(cat "$state/.wake-queue")
    run_in_watcher "$dir" shared_episode_retire_waiting_delivery "$dir" > "$dir/retirement.out" 2>&1 &
    holder=$!
    shared_episode_wait_file "$dir/retirement-ready" || { reap "$holder"; return 1; }
    printf '#!/usr/bin/env bash\nREAL_SLEEP=%q\n' "$(command -v sleep)" > "$dir/fakebin/sleep"
    cat >> "$dir/fakebin/sleep" <<'SH'
if [ "${FM_TEST_DETECTOR:-}" = daemon ] && [ "${1:-}" = 0.1 ]; then
  : > "$FM_HOME/delivery-waiting"
fi
exec "$REAL_SLEEP" "$@"
SH
    chmod +x "$dir/fakebin/sleep"
    FM_TEST_DETECTOR=daemon run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" > "$dir/daemon-run.out" 2>&1 &
    daemon_pid=$!
    wait "$holder" || { reap "$daemon_pid"; fail "retirement could not complete under the metadata lock"; return 1; }
    wait "$daemon_pid" || { fail "retired detailed row was not handled"; return 1; }
    [ -n "$queued" ] && [ ! -s "$state/.wake-queue" ] || fail "retired detailed row was not acknowledged"
    [ ! -e "$state/ps.meta" ] || fail "retirement fixture retained metadata"
    append_wake "$state" stale "$(printf '%s\n' "$queued" | cut -f4)" "$(printf '%s\n' "$queued" | cut -f5-)"
    shared_episode_ingest "$dir" || return
    [ "$(cat "$state/.subsuper-escalations" 2>/dev/null)" = "$expected" ] || fail "retired task produced an alert"
    if [ "$prior" = present ]; then
      if ! cmp -s "$receipt" "$dir/prior-receipt" \
        || ! cmp -s "$receipt.generation" "$dir/prior-generation"; then
        fail "retirement modified an existing receipt"
      fi
    else
      [ ! -e "$receipt" ] && [ ! -e "$receipt.generation" ] || fail "retirement created a delivery receipt"
    fi
    ok "retired queued stall acknowledges with $prior receipts untouched"
  done
}

test_daemon_first_multiple_generic_stales_share_one_episode() {
  local dir state selected
  dir=$(make_shared_episode_case daemon-first-generics)
  state="$dir/state"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps (agent gone)'
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps (idle 300s, possible wedge, escalation 1/3)'
  selected=$(run_in_watcher "$dir" fm_wake_print_deduped "$state/.wake-queue")
  [ "$(printf '%s\n' "$selected" | cut -f2)" = 3 ] || fail "generic dedup did not retain the newest row"
  shared_episode_ingest "$dir" || return
  [ "$(cat "$state/.stale-since-fmtest_fm-ps.stalled")" = 'review, run 01RUN, agent none' ] || fail "daemon-first detection did not begin a shared episode"
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 1 ] || fail "daemon-first episode did not advance the observation fence"
  shared_episode_buffer "$dir" 1
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 1
  ok "generic stale rows in and across drains join one daemon-first episode"
}

test_daemon_first_recovery_separates_identical_stall() {
  local dir state
  dir=$(make_shared_episode_case daemon-first-recovery)
  state="$dir/state"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  shared_episode_recover "$dir" || return
  [ "$(cat "$state/.stale-since-fmtest_fm-ps.stalled.generation")" = 2 ] || fail "daemon-first recovery did not advance generation"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 3 ] || fail "identical second daemon-first stall was lost"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  ok "daemon-first recovery separates identical stalled episodes"
}

test_delayed_detailed_delivery_keeps_publication_episode() {
  local dir state keys selected sequence
  dir=$(make_shared_episode_case delayed-episodes)
  state="$dir/state"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  keys=$(cut -f4 "$state/.wake-queue")
  [ "$keys" = "$(printf '%s\n%s' 'fmtest:fm-ps|pipeline-stall|1|review, run 01RUN, agent none' 'fmtest:fm-ps|pipeline-stall|3|review, run 01RUN, agent none')" ] || fail "detailed wakes did not retain distinct publication episodes"
  selected=$(run_in_watcher "$dir" fm_wake_print_deduped "$state/.wake-queue")
  [ "$(printf '%s\n' "$selected" | wc -l | tr -d ' ')" = 2 ] || fail "dedup discarded a delayed episode"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 3 ] || fail "delayed delivery consumed the next episode or moved the receipt backward"
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" fmtest:fm-ps || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "delayed second episode repeated"
  shared_episode_buffer "$dir" 2
  ok "delayed detailed wakes retain both publication episodes through recovery"
}

test_concurrent_watcher_and_daemon_detection_share_episode() {
  local first second dir state daemon_pid watcher_pid lock_pid result sequence receipt
  for first in watcher daemon; do
    if [ "$first" = watcher ]; then second=daemon; else second=watcher; fi
    dir=$(make_shared_episode_case "concurrent-$first")
    state="$dir/state"
    : > "$dir/barriers"
    append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
    FM_TEST_DETECTOR=daemon run_poll_daemon "$dir" handle_durable_wakes 'stale: fmtest:fm-ps' > "$dir/daemon-run.out" 2>&1 &
    daemon_pid=$!
    shared_episode_wait_file "$dir/daemon.read" || { reap "$daemon_pid"; return; }
    FM_TEST_DETECTOR=watcher FM_WATCH_HANDLING_SUCCESSOR=1 poll_stalled_case "$dir" fmtest:fm-ps > "$dir/poll-run.out" 2>&1 &
    watcher_pid=$!
    shared_episode_wait_file "$dir/watcher.read" || { reap "$daemon_pid"; reap "$watcher_pid"; return; }
    (
      export FM_STATE_OVERRIDE="$state"
      # shellcheck source=/dev/null
      . "$ROOT/bin/fm-wake-lib.sh"
      fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
      : > "$dir/lock-held"
      shared_episode_wait_file "$dir/lock-release"
      result=$?
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      exit "$result"
    ) &
    lock_pid=$!
    shared_episode_wait_file "$dir/lock-held" || { reap "$daemon_pid"; reap "$watcher_pid"; reap "$lock_pid"; return; }
    : > "$dir/$first.release"
    shared_episode_wait_file "$dir/$first.departed" || return
    [ ! -e "$state/.stale-since-fmtest_fm-ps.stalled" ] || fail "detector bypassed the held queue lock"
    : > "$dir/lock-release"
    wait "$lock_pid" || fail "queue barrier failed"
    shared_episode_wait_file "$state/.stale-since-fmtest_fm-ps.stalled" || return
    : > "$dir/$second.release"
    wait "$daemon_pid" || fail "$first-first daemon ingestion failed"
    wait "$watcher_pid" || fail "$first-first watcher poll failed"
    if [ -s "$state/.wake-queue" ]; then shared_episode_ingest "$dir" || return; fi
    [ "$(cat "$state/.stale-since-fmtest_fm-ps.stalled")" = "$(cat "$state/.subsuper-stalled-ps")" ] || fail "detectors disagreed on active identity"
    [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 1 ] || fail "concurrent detectors created distinct generations"
    [ ! -s "$state/.wake-queue" ] || fail "concurrent rows were not acknowledged"
    shared_episode_buffer "$dir" 1
    sequence=$(cat "$state/.wake-queue.seq")
    receipt=$(cat "$state/.subsuper-stalled-ps.generation")
    poll_stalled_case "$dir" fmtest:fm-ps || return
    append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
    shared_episode_ingest "$dir" || return
    [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "concurrent episode repeated on a fresh watcher poll"
    [ "$(cat "$state/.stale-since-fmtest_fm-ps.stalled.generation")" = 1 ] || fail "concurrent repeated begin advanced the fence"
    [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "concurrent episode repeated during fresh ingestion"
    shared_episode_buffer "$dir" 1
  done
  ok "both serialized concurrent detector orderings share one episode"
}

test_unknown_observation_preserves_active_episode() {
  local dir state marker receipt before after key payload
  dir=$(make_shared_episode_case unknown-episode)
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  receipt="$state/.subsuper-stalled-ps"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  key=$(cut -f4 "$state/.wake-queue")
  payload=$(poll_wake_payload "$dir")
  shared_episode_ingest "$dir" || return
  before=$(cat "$marker" "$marker.hash" "$receipt" "$receipt.generation")
  : > "$dir/unknown"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  run_poll_daemon "$dir" housekeeping
  after=$(cat "$marker" "$marker.hash" "$receipt" "$receipt.generation")
  [ "$before" = "$after" ] || fail "unknown reads changed episode records"
  [ "$(run_in_watcher "$dir" crew_stalled_generation "$marker.generation")" = 1 ] || fail "unknown reads advanced the generation"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  append_wake "$state" stale "$key" "$payload"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 1
  rm -f "$dir/unknown"
  shared_episode_recover "$dir" || return
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_ingest "$dir" || return
  [ "$(head -n 1 "$receipt.generation")" = 3 ] || fail "known recovery after unknown did not rearm"
  shared_episode_buffer "$dir" 2
  ok "unknown observations preserve episode records and repeated delivery suppression"
}

test_deduped_stall_rows_are_handled_in_sequence_order() {
  local dir state detail next_detail episode zero one i selected expected
  dir=$(make_shared_episode_case episode-sequence-order)
  state="$dir/state"
  detail='pipeline stalled 25m at review, run 01RUN, agent none'
  next_detail='pipeline stalled 26m at review, run 01RUN, agent none'
  episode=$(run_in_watcher "$dir" crew_stall_transition "$state" ps fmtest:fm-ps begin "$detail" "" 0)
  zero="fmtest:fm-ps|pipeline-stall|${episode#*|}"
  shared_episode_recover "$dir" watcher || return
  episode=$(run_in_watcher "$dir" crew_stall_transition "$state" ps fmtest:fm-ps begin "$next_detail" "" 2)
  one="fmtest:fm-ps|pipeline-stall|${episode#*|}"
  for ((i=0; i<8; i++)); do append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'; done
  append_wake "$state" stale "$zero" "stale: fmtest:fm-ps ($detail)"
  append_wake "$state" stale "$one" "stale: fmtest:fm-ps ($next_detail)"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps (agent gone)'
  selected=$(run_in_watcher "$dir" fm_wake_print_deduped "$state/.wake-queue")
  [ "$(printf '%s\n' "$selected" | cut -f2)" = "$(printf '11\n9\n10')" ] || fail "fixture did not exercise newest-per-key presentation order"
  shared_episode_ingest "$dir" || return
  expected=$(printf '%s\n%s' "stale: fmtest:fm-ps ($detail)" "stale: fmtest:fm-ps ($next_detail)")
  [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "selected episodes were not buffered in numeric queue order"
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 3 ] || fail "selected rows moved the receipt backward"
  append_wake "$state" stale "$one" "stale: fmtest:fm-ps ($next_detail)"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir" || return
  [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "acknowledged episode replay changed the delivered order"
  ok "selected durable rows are delivered in numeric sequence order"
}

test_stalled_observation_cannot_cross_daemon_recovery() {
  local dir state marker receipt watcher_pid live_pid result sequence generation sampled_generation recovered=${1:-0}
  dir=$(make_shared_episode_case "observed-stall-recovery-$recovered")
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_ingest "$dir" || return
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")
  if [ "$recovered" = 1 ]; then
    shared_episode_recover "$dir" || return
    [ ! -e "$marker" ] && [ ! -e "$marker.hash" ] || fail "recovery-before-begin fixture retained an active episode"
    [ "$(cat "$marker.generation")" = 2 ] || fail "initial recovery did not advance its sampled generation"
    [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "initial recovery changed the acknowledged receipt"
  fi
  sampled_generation=$(run_in_watcher "$dir" crew_stalled_generation "$marker.generation")
  printf '#!/usr/bin/env bash\nREAL_CREW_STATE=%q\n' "$ROOT/bin/fm-crew-state.sh" > "$dir/fakebin/fm-crew-state.sh"
  cat >> "$dir/fakebin/fm-crew-state.sh" <<'SH'
line=$("$REAL_CREW_STATE" "$@") || exit $?
printf '%s\n' "$line" > "$FM_HOME/crew-observation"
if [ "${FM_TEST_DETECTOR:-}" = watcher ] && [ ! -e "$FM_HOME/watcher.departed" ]; then
  printf '%s\n' "$line" > "$FM_HOME/watcher.read"
  while [ ! -e "$FM_HOME/watcher.release" ]; do sleep 0.05; done
  : > "$FM_HOME/watcher.departed"
fi
printf '%s\n' "$line"
SH
  FM_TEST_DETECTOR=watcher poll_stalled_case "$dir" fmtest:fm-ps > "$dir/poll-run.out" 2>&1 &
  watcher_pid=$!
  shared_episode_wait_file "$dir/watcher.read" || { reap "$watcher_pid"; return; }
  [ "$(cat "$dir/watcher.read")" = 'state: stalled · source: run-step · pipeline stalled 25m at review, run 01RUN, agent none' ] || fail "barrier did not follow a real stalled observation"
  sleep 120 &
  live_pid=$!
  shared_episode_status "$dir" "$live_pid"
  run_poll_daemon "$dir" housekeeping
  result=$?
  if [ "$result" -ne 0 ]; then
    reap "$watcher_pid"
    reap "$live_pid"
    fail "daemon recovery failed while the stale observer waited"
    return
  fi
  [ "$(cat "$dir/crew-observation")" = 'state: working · source: run-step · validating (running)' ] || fail "daemon did not observe the live agent"
  [ "$(cat "$marker.generation")" -eq "$((sampled_generation + 1))" ] && [ ! -e "$marker" ] || fail "daemon did not advance recovery before stale publication"
  : > "$dir/watcher.release"
  wait "$watcher_pid"
  result=$?
  if [ "$result" -ne 0 ]; then
    reap "$live_pid"
    fail "stale observer did not finish its full polling sequence"
    return
  fi
  kill -0 "$live_pid" 2>/dev/null || fail "agent died before stale-observer assertions"
  [ ! -e "$marker" ] && [ "$(cat "$marker.generation")" -gt "$sampled_generation" ] || fail "stale observation began an episode after recovery"
  awk -F '\t' '$4 ~ /\|pipeline-stall\|/ { exit 1 }' "$state/.wake-queue" || fail "stale observation published a healthy-state stall"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_ingest "$dir"
  result=$?
  reap "$live_pid"
  [ "$result" -eq 0 ] || return 1
  [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "stale observation added a delivery receipt"
  shared_episode_buffer "$dir" 1
  generation=$(cat "$marker.generation")
  shared_episode_status "$dir" -
  poll_stalled_case "$dir" fmtest:fm-ps || return
  [ "$(cut -f4 "$state/.wake-queue")" = "fmtest:fm-ps|pipeline-stall|$((generation + 1))|review, run 01RUN, agent none" ] || fail "fresh death did not retain its recovered generation"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" fmtest:fm-ps || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] && [ ! -s "$state/.wake-queue" ] || fail "fresh episode repeated after acknowledgement"
  shared_episode_buffer "$dir" 2
  ok "a stale watcher observation cannot cross daemon recovery with prior recovery=$recovered, and fresh death still delivers once"
}

test_recovery_before_first_stall_begin_supersedes_observation() {
  test_stalled_observation_cannot_cross_daemon_recovery 1
}

test_queued_stall_binding_survives_watcher_recovery_during_daemon_read() {
  local dir state marker queued_row queued_key daemon_pid watcher_pid live_pid result generation sequence
  dir=$(make_shared_episode_case queued-stall-recovery-barrier)
  state="$dir/state"
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  queued_row=$(cat "$state/.wake-queue")
  queued_key=$(cut -f4 "$state/.wake-queue")
  [ "$queued_key" = 'fmtest:fm-ps|pipeline-stall|1|review, run 01RUN, agent none' ] || fail "initial publication did not bind its advanced fence"
  printf '#!/usr/bin/env bash\nREAL_CREW_STATE=%q\n' "$ROOT/bin/fm-crew-state.sh" > "$dir/fakebin/fm-crew-state.sh"
  cat >> "$dir/fakebin/fm-crew-state.sh" <<'SH'
line=$("$REAL_CREW_STATE" "$@") || exit $?
printf '%s\n' "$line" > "$FM_HOME/crew-observation"
if [ "${FM_TEST_DETECTOR:-}" = daemon ] && [ ! -e "$FM_HOME/daemon.departed" ]; then
  printf '%s\n' "$line" > "$FM_HOME/daemon.read"
  while [ ! -e "$FM_HOME/daemon.release" ]; do sleep 0.05; done
  : > "$FM_HOME/daemon.departed"
fi
printf '%s\n' "$line"
SH
  FM_TEST_DETECTOR=daemon run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" > "$dir/daemon-run.out" 2>&1 &
  daemon_pid=$!
  shared_episode_wait_file "$dir/daemon.read" || { reap "$daemon_pid"; return; }
  [ "$(cat "$dir/daemon.read")" = 'state: stalled · source: run-step · pipeline stalled 25m at review, run 01RUN, agent none' ] || fail "daemon barrier did not follow the queued stall observation"
  sleep 120 &
  live_pid=$!
  shared_episode_status "$dir" "$live_pid"
  FM_WATCH_HANDLING_SUCCESSOR=1 poll_stalled_case "$dir" fmtest:fm-ps > "$dir/poll-run.out" 2>&1 &
  watcher_pid=$!
  local deadline=$(( $(date +%s) + 60 ))
  while [ -e "$marker" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      reap "$daemon_pid"
      reap "$watcher_pid"
      reap "$live_pid"
      fail "watcher did not finish recovery before queued delivery"
      return 1
    fi
    sleep 0.05
  done
  generation=$(run_in_watcher "$dir" crew_stall_transition "$state" ps fmtest:fm-ps observe)
  [ "$generation" -gt 0 ] && [ ! -e "$marker" ] || fail "watcher did not recover before queued delivery"
  [ "$(cat "$dir/crew-observation")" = 'state: working · source: run-step · validating (running)' ] || fail "full watcher poll did not observe a live agent"
  [ "$(awk -F '\t' '$2 == 1' "$state/.wake-queue")" = "$queued_row" ] || fail "recovery changed the queued episode binding"
  [ ! -e "$state/.subsuper-stalled-ps.generation" ] || fail "recovery created a delivery receipt"
  : > "$dir/daemon.release"
  wait "$daemon_pid"
  result=$?
  if [ "$result" -ne 0 ]; then
    reap "$watcher_pid"
    reap "$live_pid"
    fail "queued episode failed durable ingestion after recovery"
    return
  fi
  wait "$watcher_pid"
  result=$?
  if [ "$result" -ne 0 ]; then
    reap "$live_pid"
    fail "recovery watcher did not finish its full polling sequence"
    return
  fi
  awk -F '\t' '$2 == 1 { exit 1 }' "$state/.wake-queue" || fail "daemon did not acknowledge the original queued episode"
  if [ -s "$state/.wake-queue" ]; then
    shared_episode_ingest "$dir" || { reap "$live_pid"; return 1; }
  fi
  kill -0 "$live_pid" 2>/dev/null || fail "agent died before queued delivery finished"
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 1 ] || fail "queued delivery acquired a healthy observation's generation"
  [ "$(sed -n '2,$p' "$state/.subsuper-stalled-ps.generation")" = '1|review, run 01RUN, agent none' ] || fail "queued delivery changed its immutable episode receipt"
  shared_episode_buffer "$dir" 1
  generation=$(cat "$marker.generation")
  reap "$live_pid"
  shared_episode_status "$dir" -
  poll_stalled_case "$dir" fmtest:fm-ps || return
  [ "$(cut -f4 "$state/.wake-queue")" = "fmtest:fm-ps|pipeline-stall|$((generation + 1))|review, run 01RUN, agent none" ] || fail "later true stall did not use its fresh observation fence"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" fmtest:fm-ps || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] && [ ! -s "$state/.wake-queue" ] || fail "later episode repeated after acknowledgement"
  shared_episode_buffer "$dir" 2
  ok "queued detail keeps its binding across watcher recovery during daemon ingestion, and a later stall delivers once"
}

test_generic_before_detailed_episodes_delivers_each_once() {
  local dir state keys
  dir=$(make_shared_episode_case generic-before-episodes)
  state="$dir/state"
  append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
  shared_episode_pending_poll "$dir" || return
  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  [ "$(cut -f2 "$state/.wake-queue")" = "$(printf '1\n2\n3')" ] || fail "generic-first fixture has unexpected queue sequences"
  keys=$(cut -f4 "$state/.wake-queue")
  [ "$keys" = "$(printf '%s\n%s\n%s' fmtest:fm-ps 'fmtest:fm-ps|pipeline-stall|1|review, run 01RUN, agent none' 'fmtest:fm-ps|pipeline-stall|3|review, run 01RUN, agent none')" ] || fail "generic-first fixture lost its publication episodes"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 3 ] || fail "older detailed row moved the delivery generation backward"
  [ "$(sed -n '2,$p' "$state/.subsuper-stalled-ps.generation" | sort)" = "$(printf '%s\n%s' '1|review, run 01RUN, agent none' '3|review, run 01RUN, agent none')" ] || fail "delivery receipt did not retain both delivered episodes"
  ok "a generic stale before two detailed episodes buffers each episode once"
}

test_selected_wake_sort_failure_retains_unhandled_episodes() {
  local dir state rows mode
  dir=$(make_shared_episode_case episode-sort-failure)
  state="$dir/state"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  rows=$(cat "$state/.wake-queue")
  [ "$(wc -l < "$state/.wake-queue" | tr -d ' ')" = 2 ] || fail "sort fixture needs both detailed episodes"
  printf '#!/usr/bin/env bash\nREAL_SORT=%q\n' "$(command -v sort)" > "$dir/fakebin/sort"
  cat >> "$dir/fakebin/sort" <<'SH'
case " $* " in
  *' -k2,2n '*)
    if [ "$FM_TEST_SORT_OUTPUT" = partial ]; then head -n 1 "${!#}"; fi
    printf 'selected wake sort failed\n' >&2
    exit 23 ;;
esac
exec "$REAL_SORT" "$@"
SH
  chmod +x "$dir/fakebin/sort"
  for mode in empty partial; do
    if FM_TEST_SORT_OUTPUT="$mode" run_poll_daemon "$dir" handle_durable_wakes 'check: unhandled fallback' > "$dir/sort.out" 2> "$dir/sort.err"; then
      fail "$mode sort failure was reported as success"
    fi
    grep -F 'selected wake sort failed' "$dir/sort.err" >/dev/null || fail "fixture did not reach selected-row sorting"
    [ "$(cat "$state/.wake-queue")" = "$rows" ] || fail "$mode sort failure consumed durable wakes"
    [ ! -s "$state/.subsuper-escalations" ] || fail "$mode sort failure handled a row or fallback"
    [ ! -e "$state/.subsuper-stalled-ps.generation" ] || fail "$mode sort failure recorded episode delivery"
  done
  rm "$dir/fakebin/sort"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  ok "failed selected-row sorting retains every episode until successful ingestion and acknowledgement"
}

test_poll_rejects_early_exit_with_existing_episode_evidence() {
  local dir state count receipt rows pending result
  dir=$(make_shared_episode_case early-poll-exit)
  state="$dir/state"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_ingest "$dir" || return
  count=$(cat "$state/.count-fmtest_fm-ps")
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  fm_test_pid_identity "$$" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  for pending in no yes; do
    if [ "$pending" = yes ]; then
      append_wake "$state" stale fmtest:fm-ps 'stale: fmtest:fm-ps'
    fi
    rows=$(cat "$state/.wake-queue")
    (poll_stalled_case "$dir" fmtest:fm-ps) > "$dir/poll-result" 2>&1
    result=$?
    [ "$result" -ne 0 ] || fail "premature watcher exit passed with pending wake $pending"
    grep -F 'watcher exited before required polls or a new wake publication' "$dir/poll-result" >/dev/null || fail "poll helper did not reject the premature exit"
    grep -F 'watcher: already running pid' "$dir/watch.out" >/dev/null || fail "fixture did not reach the real watcher early exit"
    [ "$(cat "$state/.count-fmtest_fm-ps")" = "$count" ] || fail "early-exit watcher completed a poll"
    [ "$(cat "$state/.wake-queue")" = "$rows" ] || fail "early-exit check changed pending rows"
    [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "early-exit check changed the episode receipt"
    shared_episode_buffer "$dir" 1
  done
  ok "real watcher early exits fail despite existing queue and receipt evidence"
}

test_detailed_episodes_do_not_repeat_after_failed_acknowledgement() {
  local dir state rows receipt
  dir=$(make_shared_episode_case episode-ack-replay)
  state="$dir/state"
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  rows=$(cat "$state/.wake-queue")
  [ "$(cut -f4 "$state/.wake-queue")" = "$(printf '%s\n%s' 'fmtest:fm-ps|pipeline-stall|1|review, run 01RUN, agent none' 'fmtest:fm-ps|pipeline-stall|3|review, run 01RUN, agent none')" ] || fail "replay fixture did not queue both detailed episodes"
  printf '#!/usr/bin/env bash\nREAL_MV=%q\n' "$(command -v mv)" > "$dir/fakebin/mv"
  cat >> "$dir/fakebin/mv" <<'SH'
last=${!#}
if [ "$last" = "$FM_HOME/state/.wake-queue" ]; then
  exit 1
fi
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  if run_poll_daemon "$dir" handle_durable_wakes 'stale: fmtest:fm-ps' > "$dir/failed-ack.out" 2> "$dir/failed-ack.err"; then
    fail "queue acknowledgement fault was reported as success"
  fi
  grep -F 'acknowledged wakes could not be consumed safely' "$dir/failed-ack.err" >/dev/null || fail "fixture did not reach the production acknowledgement failure"
  [ "$(cat "$state/.wake-queue")" = "$rows" ] || fail "failed acknowledgement consumed durable episode rows"
  shared_episode_buffer "$dir" 2
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")
  rm "$dir/fakebin/mv"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "replay rewrote previously delivered episodes"
  case "$(cat "$state/.watcher-down")" in
    acked:handling:*) ;;
    *) fail "retry did not acknowledge the durable recovery episode" ;;
  esac
  ok "acknowledgement retry consumes both detailed rows without buffering them again"
}

test_stalled_alert_receipt_faults_replay_each_episode_once() {
  local dir state rows receipt visible tagged plain
  dir=$(make_shared_episode_case episode-receipt-faults)
  state="$dir/state"
  visible='stale: fmtest:fm-ps (pipeline stalled 25m at review, run 01RUN, agent none)'
  poll_stalled_case "$dir" fmtest:fm-ps || return
  rows=$(cat "$state/.wake-queue")
  printf '#!/usr/bin/env bash\nREAL_MKTEMP=%q\n' "$(command -v mktemp)" > "$dir/fakebin/mktemp"
  cat >> "$dir/fakebin/mktemp" <<'SH'
case "${!#}" in
  *.subsuper-stalled-ps.generation.XXXXXX) exit 1 ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
  chmod +x "$dir/fakebin/mktemp"
  if run_poll_daemon "$dir" handle_durable_wakes 'stale: fmtest:fm-ps' > "$dir/before-buffer.out" 2>&1; then
    fail "receipt preparation fault before buffering was reported as success"
  fi
  [ "$(cat "$state/.wake-queue")" = "$rows" ] || fail "pre-buffer fault acknowledged the durable episode"
  [ ! -s "$state/.subsuper-escalations" ] || fail "pre-buffer fault appended an unreceipted alert"
  rm "$dir/fakebin/mktemp"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 1
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")

  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  rows=$(cat "$state/.wake-queue")
  printf '#!/usr/bin/env bash\nREAL_MV=%q\n' "$(command -v mv)" > "$dir/fakebin/mv"
  cat >> "$dir/fakebin/mv" <<'SH'
last=${!#}
if [ "$last" = "$FM_HOME/state/.subsuper-stalled-ps.generation" ]; then
  exit 1
fi
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  if run_poll_daemon "$dir" handle_durable_wakes 'stale: fmtest:fm-ps' > "$dir/after-buffer.out" 2>&1; then
    fail "receipt commit fault after buffering was reported as success"
  fi
  [ "$(cat "$state/.wake-queue")" = "$rows" ] || fail "post-buffer fault acknowledged the durable episode"
  [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "failed receipt commit changed the prior receipt"
  tagged=$(awk -F '\t' '$1 == "@pipeline-stall" { count++ } END { print count + 0 }' "$state/.subsuper-escalations")
  plain=$(grep -Fxc "$visible" "$state/.subsuper-escalations" || true)
  [ "$tagged" -eq 1 ] && [ "$plain" -eq 1 ] || fail "post-buffer fault lost the episode binding or duplicated visible output"
  rm "$dir/fakebin/mv"
  shared_episode_ingest "$dir" || return
  shared_episode_buffer "$dir" 2
  [ "$(sed -n '2,$p' "$state/.subsuper-stalled-ps.generation" | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "receipt replay did not retain both distinct episode identities"
  ok "buffer and receipt faults replay two identical-detail episodes exactly once"
}

test_retired_receipt_fault_drops_only_its_bound_episode() {
  local dir state rows receipt expected visible tagged
  dir=$(make_shared_episode_case retired-receipt-fault)
  state="$dir/state"
  visible='stale: fmtest:fm-ps (pipeline stalled 25m at review, run 01RUN, agent none)'
  poll_stalled_case "$dir" fmtest:fm-ps || return
  shared_episode_ingest "$dir" || return
  shared_episode_recover "$dir" watcher || return
  shared_episode_pending_poll "$dir" || return
  rows=$(cat "$state/.wake-queue")
  receipt=$(cat "$state/.subsuper-stalled-ps.generation")
  run_poll_daemon "$dir" escalate_add "$state" ordinary-before || return
  printf '#!/usr/bin/env bash\nREAL_MV=%q\n' "$(command -v mv)" > "$dir/fakebin/mv"
  cat >> "$dir/fakebin/mv" <<'SH'
last=${!#}
if [ "$last" = "$FM_HOME/state/.subsuper-stalled-ps.generation" ]; then
  exit 1
fi
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  if run_poll_daemon "$dir" handle_durable_wakes 'stale: fmtest:fm-ps' > "$dir/retired-fault.out" 2>&1; then
    fail "retirement fixture receipt fault was reported as success"
    return 1
  fi
  [ "$(cat "$state/.wake-queue")" = "$rows" ] || fail "receipt fault acknowledged the episode before retirement"
  tagged=$(awk -F '\t' '$1 == "@pipeline-stall" { count++ } END { print count + 0 }' "$state/.subsuper-escalations")
  [ "$tagged" = 1 ] || fail "receipt fault did not leave one bound episode"
  rm "$dir/fakebin/mv"
  run_poll_daemon "$dir" escalate_add "$state" ordinary-after || return
  rm "$state/ps.meta"
  shared_episode_ingest "$dir" || return
  [ "$(cat "$state/.subsuper-stalled-ps.generation")" = "$receipt" ] || fail "retired replay changed the existing receipt"
  expected=$(printf '%s\n%s\n%s' "$visible" ordinary-before ordinary-after)
  [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "retired replay changed unrelated buffer bytes or order"
  [ "$(grep -Fxc "$visible" "$state/.subsuper-escalations" || true)" = 1 ] || fail "retired replay exposed the dropped episode"
  run_poll_daemon_confirmed_flush "$dir" || { fail "retired bound episode blocked a later flush"; return; }
  [ ! -s "$state/.subsuper-escalations" ] || fail "later buffered notifications did not flush"
  ok "retired replay drops only its bound episode and leaves the buffer flushable"
}

test_daemon_only_recovery_rearms_same_stall_identity() {
  local dir state win marker receipt expected identity sequence generation pane_hash poll_count live_pid result
  dir=$(make_wedge_case daemon-only-recovery ps 'working: validating' 'mode=no-mistakes')
  state="$dir/state"
  win=fmtest:fm-ps
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  receipt="$state/.subsuper-stalled-ps"
  seed_stale_pane "$dir" ps "$win" 'unchanged idle validation pane'
  axi_status_for "$dir" '  awaiting_agent: parked 25m
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,25m,"quiet 25m ago: log: last activity","-",fix 1' > "$dir/axi.dead"
  cp "$dir/axi.dead" "$dir/axi-status"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/axi-status"
SH
  chmod +x "$dir/fakebin/no-mistakes"
  printf '#!/usr/bin/env bash\nset -o pipefail\nREAL_CREW_STATE=%q\n' "$ROOT/bin/fm-crew-state.sh" > "$dir/fakebin/fm-crew-state.sh"
  cat >> "$dir/fakebin/fm-crew-state.sh" <<'SH'
"$REAL_CREW_STATE" "$@" | tee "$FM_HOME/crew-observation"
SH
  : > "$state/.afk"
  poll_stalled_case "$dir" "$win" || return
  expected="stale: $win (pipeline stalled 25m at review, run 01RUN, agent none)"
  identity='review, run 01RUN, agent none'
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "daemon-only fixture lost the initial diagnosis"
  run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
    || { fail "daemon-only episode one failed durable ingestion"; return; }
  [ ! -s "$state/.wake-queue" ] || fail "episode one was not acknowledged"
  [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "episode one was not buffered once"
  [ "$(cat "$marker")" = "$identity" ] && [ "$(cat "$receipt")" = "$identity" ] || fail "episode one identities differ"
  generation=$(run_in_watcher "$dir" crew_stalled_generation "$marker.generation")
  [ "$(head -n 1 "$receipt.generation")" = "$generation" ] || fail "episode one generations differ"
  sequence=$(cat "$state/.wake-queue.seq")
  pane_hash=$(cat "$state/.hash-fmtest_fm-ps")
  poll_count=$(cat "$state/.count-fmtest_fm-ps")
  sleep 60 &
  live_pid=$!
  axi_status_for "$dir" "  awaiting_agent: parked 25m
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,25m,\"quiet 25m ago: log: last activity\",\"$live_pid\",fix 1" > "$dir/axi-status"
  run_poll_daemon "$dir" housekeeping
  result=$?
  reap "$live_pid"
  [ "$result" = 0 ] || { fail "daemon recovery housekeeping failed"; return; }
  [ "$(cat "$dir/crew-observation")" = 'state: working · source: run-step · validating (running)' ] || fail "daemon did not observe the live awaiting-agent PID"
  [ "$(cat "$state/.count-fmtest_fm-ps")" = "$poll_count" ] || fail "watcher polled during daemon-only recovery"
  [ ! -e "$marker" ] && [ ! -e "$marker.hash" ] || fail "daemon recovery left publication suppressed"
  [ "$(cat "$marker.generation")" -eq "$((generation + 1))" ] || fail "daemon recovery did not advance the shared generation once"
  [ "$(cat "$receipt")" = "$identity" ] && [ "$(head -n 1 "$receipt.generation")" = "$generation" ] || fail "recovery changed the prior delivery receipt"
  cp "$dir/axi.dead" "$dir/axi-status"
  poll_stalled_case "$dir" "$win" || return
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "daemon-only recovery hid the second agent death"
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "second episode did not publish exactly once"
  [ "$(cat "$state/.hash-fmtest_fm-ps")" = "$pane_hash" ] && [ "$(cat "$marker")" = "$identity" ] || fail "second episode changed the pane or stall identity"
  run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
    || { fail "daemon-only episode two failed durable ingestion"; return; }
  [ ! -s "$state/.wake-queue" ] || fail "episode two was not acknowledged"
  [ "$(head -n 1 "$receipt.generation")" -eq "$((generation + 2))" ] || fail "episode two retained the old delivered generation"
  [ "$(cat "$state/.subsuper-escalations")" = "$(printf '%s\n%s' "$expected" "$expected")" ] || fail "daemon did not buffer exactly two episodes"
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" "$win" || return
  run_poll_daemon "$dir" housekeeping
  [ ! -s "$state/.wake-queue" ] && [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "unchanged episode repeated its wake"
  [ "$(cat "$state/.subsuper-escalations")" = "$(printf '%s\n%s' "$expected" "$expected")" ] || fail "unchanged episode produced a third buffered line"
  ok "daemon-only recovery rearms the same stall through polling and durable acknowledgement"
}

test_changed_idle_pane_recovery_rearms_stall_before_housekeeping() {
  local dir state win expected sequence marker
  dir=$(make_wedge_case changed-pane-recovery ps 'paused: [key=await-merge] waiting for merge' 'mode=no-mistakes')
  state="$dir/state"
  win=fmtest:fm-ps
  marker="$state/.stale-since-fmtest_fm-ps.stalled"
  seed_stale_pane "$dir" ps "$win" 'unchanged idle validation pane'
  axi_status_for "$dir" '  awaiting_agent: parked 25m
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,25m,"quiet 25m ago: log: last activity","-",fix 1' > "$dir/axi.dead"
  axi_status_for "$dir" '  awaiting_agent: parked 25m
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,25m,"quiet 25m ago: log: last activity","@PID@",fix 1' > "$dir/axi.live"
  cp "$dir/axi.dead" "$dir/axi-status"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/axi-status"
SH
  chmod +x "$dir/fakebin/no-mistakes"
  printf '#!/usr/bin/env bash
REAL_CREW_STATE=%q
' "$ROOT/bin/fm-crew-state.sh" > "$dir/fakebin/fm-crew-state.sh"
  cat >> "$dir/fakebin/fm-crew-state.sh" <<'SH'
if [ -e "$FM_HOME/recover-once" ]; then
  rm -f "$FM_HOME/recover-once"
  sleep 60 &
  live_pid=$!
  trap 'kill "$live_pid" 2>/dev/null || true; wait "$live_pid" 2>/dev/null || true' EXIT
  sed "s/@PID@/$live_pid/" "$FM_HOME/axi.live" > "$FM_HOME/axi-status"
  "$REAL_CREW_STATE" "$@" > "$FM_HOME/recovery-line"
  cat "$FM_HOME/state/.count-fmtest_fm-ps" > "$FM_HOME/recovery-count"
  cp "$FM_HOME/axi.dead" "$FM_HOME/axi-status"
  cat "$FM_HOME/recovery-line"
else
  "$REAL_CREW_STATE" "$@"
fi
SH
  : > "$state/.afk"
  poll_stalled_case "$dir" "$win" || return
  expected="stale: $win (pipeline stalled 25m at review, run 01RUN, agent none)"
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "initial awaiting-agent death lost its diagnosis"
  run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
    || { fail "initial changed-pane episode failed durable ingestion"; return; }
  [ ! -s "$state/.wake-queue" ] || fail "initial episode was not acknowledged"
  [ "$(cat "$state/.subsuper-escalations")" = "$expected" ] || fail "initial episode was not buffered once"
  sequence=$(cat "$state/.wake-queue.seq")
  rm -f "$state/.afk"
  printf '%s' 'changed idle validation pane during recovery' > "$dir/pane.txt"
  : > "$dir/recover-once"
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$dir/recovery-line")" = 'state: working · source: run-step · validating (running)' ] || fail "live awaiting-agent PID did not prove recovery"
  [ "$(cat "$dir/recovery-count")" = 0 ] || fail "recovery was not observed on the changed-hash poll"
  [ "$(cat "$marker.generation")" = 3 ] || fail "changed-hash recovery did not rearm the stalled episode"
  [ "$(head -n 1 "$state/.subsuper-stalled-ps.generation")" = 1 ] || fail "daemon observed recovery before ingestion"
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "same-identity death after changed-hash recovery was hidden"
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "recovery or second death published extra wakes"
  : > "$state/.afk"
  run_poll_daemon "$dir" handle_durable_wakes "$(cat "$dir/watch.out")" \
    || { fail "second changed-pane episode failed durable ingestion"; return; }
  [ ! -s "$state/.wake-queue" ] || fail "second episode was not acknowledged"
  [ "$(cat "$state/.subsuper-escalations")" = "$(printf '%s\n%s' "$expected" "$expected")" ] || fail "daemon did not preserve exactly one notification per episode"
  sequence=$(cat "$state/.wake-queue.seq")
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "second episode repeated on another poll"
  append_wake "$state" stale "$win" "$expected"
  run_poll_daemon "$dir" handle_durable_wakes "$expected" \
    || { fail "second episode replay failed durable ingestion"; return; }
  [ ! -s "$state/.wake-queue" ] || fail "second episode replay was not acknowledged"
  [ "$(cat "$state/.subsuper-escalations")" = "$(printf '%s\n%s' "$expected" "$expected")" ] || fail "daemon duplicated the second episode"
  ok "changed idle pane recovery rearms a same-identity stall before daemon housekeeping"
}

test_acknowledged_stall_identity_does_not_repeat_on_same_episode() {
  local dir state win key expected sequence reported_hash
  dir=$(make_wedge_case poll-stall-identity ps 'working: validating' 'mode=no-mistakes')
  state="$dir/state"
  win=fmtest:fm-ps
  key=fmtest_fm-ps
  seed_stale_pane "$dir" ps "$win" 'unchanged idle validation pane'
  set_poll_pipeline_activity "$dir" 25m
  poll_stalled_case "$dir" "$win" || return
  expected="stale: $win (pipeline stalled 25m at review, run 01RUN, agent none)"
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "initial stall lost its diagnosis"
  [ "$(cat "$state/.stale-since-$key.stalled")" = 'review, run 01RUN, agent none' ] || fail "initial stall did not record its identity"
  reported_hash=$(cat "$state/.hash-$key")
  [ "$(cat "$state/.stale-since-$key.stalled.hash")" = "$reported_hash" ] || fail "stall publication did not associate its pane hash"
  sequence=$(cat "$state/.wake-queue.seq")
  ack_poll_wake "$dir" || return
  set_poll_pipeline_activity "$dir" 26m
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "acknowledging the stall rearmed a duplicate"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · temporarily unreadable'
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.stale-since-$key.stalled")" = 'review, run 01RUN, agent none' ] || fail "unknown state changed the stalled identity"
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "unknown state emitted a generic duplicate wake"
  printf '%s' 'a distinct idle pane after the reported stall' > "$dir/pane.txt"
  poll_stalled_case "$dir" "$win" || return
  [ "$(poll_wake_payload "$dir")" = "stale: $win" ] || fail "unknown state hid the changed pane's ordinary stale wake"
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "changed pane did not publish exactly one ordinary wake"
  [ "$(cat "$state/.stale-since-$key.stalled")" = 'review, run 01RUN, agent none' ] || fail "changed unknown pane cleared the stalled identity"
  [ "$(cat "$state/.stale-since-$key.stalled.hash")" = "$reported_hash" ] || fail "ordinary classification replaced the reported stall hash"
  sequence=$(cat "$state/.wake-queue.seq")
  ack_poll_wake "$dir" || return
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "ordinary stale-hash suppression repeated the changed pane wake"
  set_poll_pipeline_activity "$dir" 26m
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "unknown state rearmed a duplicate stall"
  set_poll_pipeline_activity "$dir" 15m
  poll_stalled_case "$dir" "$win" || return
  [ ! -e "$state/.stale-since-$key.stalled" ] || fail "known working observation did not clear the identity"
  [ ! -e "$state/.stale-since-$key.stalled.hash" ] || fail "known working observation retained the old stall hash"
  set_poll_pipeline_activity "$dir" 25m
  poll_stalled_case "$dir" "$win" || return
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "new stalled episode did not notify"
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "new stalled episode did not publish exactly once"
  unset FM_FAKE_AXI_STATUS FM_FAKE_CREW_STATE
  ok "full polls deduplicate the reported stall hash while surfacing changed unknown panes"
}

test_working_hash_transition_surfaces_stalled_diagnosis() {
  local dir state window key status_kind status_line seen reason
  for status_kind in working terminal; do
    case "$status_kind" in
      working) status_line='working: validating' ;;
      terminal) status_line='done: earlier checks green' ;;
    esac
    dir=$(make_wedge_case "working-stalled-$status_kind" ws "$status_line" 'mode=no-mistakes')
    state="$dir/state"
    window=fmtest:fm-ws
    key=fmtest_fm-ws
    seed_stale_pane "$dir" ws "$window" 'idle, unchanged validation pane'
    cp "$state/.hash-$key" "$state/.stale-$key"
    if [ "$status_kind" = terminal ]; then
      printf '1\n' > "$state/.stale-since-$key"
    else
      date +%s > "$state/.stale-since-$key"
    fi
    seen=$(cat "$state/.seen-ws_status")
    export FM_FAKE_CREW_STATE='state: stalled · source: run-step · pipeline stalled 13h at review, run 01RUN, agent none'
    FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,13h,"1s ago: log: last activity","-",fix 1')
    export FM_FAKE_AXI_STATUS
    run_for_seconds "$dir" "$window" 60
    reason="stale: $window (pipeline stalled 13h at review, run 01RUN, agent none)"
    grep -qF "$reason" "$state/.wake-queue" 2>/dev/null \
      || fail "$status_kind working-to-stalled transition lost its diagnosis on an unchanged hash"
    [ ! -e "$state/.stale-since-$key" ] || fail "stalled transition retained its working timer"
    [ ! -e "$state/.wedge-escalations-$key" ] || fail "stalled transition entered ordinary wedge escalation"
    [ "$(cat "$state/.seen-ws_status")" = "$seen" ] || fail "stalled transition changed the signal suppressor"
  done
  unset FM_FAKE_CREW_STATE FM_FAKE_AXI_STATUS
  ok "an unchanged working hash surfaces its stalled transition before wedge absorption"
}

test_active_pipeline_blocks_escalation() {
  local dir out now
  dir=$(make_wedge_case pipeline-active pa 'working: implementing' 'mode=no-mistakes')
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting')
  export FM_FAKE_AXI_STATUS
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
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,15h29m,"quiet 51m55s ago: log: base branch advanced, re-arming CI monitor timeout","",starting')
  export FM_FAKE_AXI_STATUS 
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
  run_in_watcher "$dir" wedge_timer_check fmtest:fm-pq "$stale_since" "test stale" "$ewf" 1 >/dev/null 2>&1
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
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting')
  export FM_FAKE_AXI_STATUS 
  run_in_watcher "$dir" wedge_timer_check fmtest:fm-ph "$stale_since" "test stale" "$ewf" 1 >/dev/null 2>&1
  unset FM_FAKE_AXI_STATUS
  if grep -q 'possible wedge' "$state/.wake-queue" 2>/dev/null; then
    fail "an active pipeline must block the wedge escalation, but one was queued"
  else
    ok "an active pipeline resets the wedge timer instead of escalating"
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
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting')
  export FM_FAKE_AXI_STATUS
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

# A secondmate gets no agent liveness read on this path, so it can never be
# shown alive here. It must therefore never be absorbed onto the long pause
# cadence by this rule - it surfaces so the captain sees it, exactly as it did
# before the two-signal change.
test_secondmate_with_declared_pause_is_not_absorbed() {
  local dir out
  dir=$(make_wedge_case secondmate-pause sm \
    'paused: [key=await-answer] waiting on captain')
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/state/sm.meta"
  rm -f "$dir/state/sm.meta.bak"
  agent_gone
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-sm sm)
  unset FM_FAKE_CREW_STATE
  if [ "$out" = none ]; then
    ok "a secondmate under a declared pause surfaces instead of being absorbed"
  else
    fail "secondmate + declared pause must classify none, got '$out'"
  fi
}

# The pipeline read belongs to the pane-IDLE paths only. A genuinely BUSY pane
# that has gone past BUSY_TURN_MAX_SECS with no completed turn is already its
# own second signal, so a live pipeline must not suppress its escalation.
test_busy_pane_escalates_even_with_an_active_pipeline() {
  local dir state stale_since ewf
  dir=$(make_wedge_case busy-active ba 'working: implementing' 'mode=no-mistakes')
  state="$dir/state"
  stale_since="$state/.stale-since-fmtest_fm-ba"
  ewf="$state/.wedge-escalations-fmtest_fm-ba"
  printf '%s' "$(( $(date +%s) - 99999 ))" > "$stale_since"
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,33m1s,"12s ago: log: building the new body","77305",starting')
  export FM_FAKE_AXI_STATUS
  run_in_watcher "$dir" wedge_timer_check fmtest:fm-ba "$stale_since" "busy (no completed turn)" "$ewf" >/dev/null 2>&1
  unset FM_FAKE_AXI_STATUS
  if grep -q 'possible wedge' "$state/.wake-queue" 2>/dev/null; then
    ok "a busy pane past its turn bound escalates even while its pipeline runs"
  else
    fail "the busy path must escalate regardless of pipeline activity; no wake was queued"
  fi
}

# crew_absorb_class prints `working` for source `run-step` OR source `pane`. An
# exactly-busy pane is direct evidence of a rendering agent and owes nothing to
# a no-mistakes run, so it must be honored without any pipeline gating.
test_pane_sourced_working_is_not_gated_on_the_pipeline() {
  local dir out
  dir=$(make_wedge_case pane-working pw \
    'paused: [key=await-x] waiting' \
    'mode=no-mistakes')
  agent_present pw
  FM_FAKE_TMUX_CURRENT_COMMAND=claude
  export FM_FAKE_TMUX_CURRENT_COMMAND
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy pane'
  # The pipeline behind it has gone quiet far past the window. That is the
  # run-step signal, and it must not veto the pane's own busy verdict.
  FM_FAKE_AXI_STATUS=$(axi_status_for "$dir" '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,15h29m,"quiet 51m55s ago: log: base branch advanced, re-arming CI monitor timeout","",starting')
  export FM_FAKE_AXI_STATUS
  out=$(run_in_watcher "$dir" pause_state_class fmtest:fm-pw pw)
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_CURRENT_COMMAND FM_FAKE_AXI_STATUS
  if [ "$out" = working ]; then
    ok "a pane-sourced working verdict is honored without a pipeline read"
  else
    fail "pane-sourced working must classify working, got '$out'"
  fi
}

if [ "$#" -eq 0 ]; then
  set -- \
    test_declared_pause_beats_run_step_done \
    test_declared_pause_with_live_agent_stays_none \
    test_parked_live_pause_absorbs_each_new_idle_pane \
    test_parked_live_pause_rechecks_on_the_long_cadence \
    test_poll_reports_stall_after_generic_wedge_removed_timer \
    test_poll_reports_stall_over_old_terminal_status_without_timer \
    test_away_poll_reports_stall_after_generic_escalation_removed_marker \
    test_away_recovery_rearms_stall_without_housekeeping \
    test_late_healthy_observation_cannot_rearm_current_stall \
    test_changed_stall_identity_supersedes_older_observation \
    test_retired_task_drops_queued_stall_without_touching_receipts \
    test_daemon_first_multiple_generic_stales_share_one_episode \
    test_daemon_first_recovery_separates_identical_stall \
    test_delayed_detailed_delivery_keeps_publication_episode \
    test_concurrent_watcher_and_daemon_detection_share_episode \
    test_unknown_observation_preserves_active_episode \
    test_deduped_stall_rows_are_handled_in_sequence_order \
    test_stalled_observation_cannot_cross_daemon_recovery \
    test_recovery_before_first_stall_begin_supersedes_observation \
    test_queued_stall_binding_survives_watcher_recovery_during_daemon_read \
    test_generic_before_detailed_episodes_delivers_each_once \
    test_selected_wake_sort_failure_retains_unhandled_episodes \
    test_poll_rejects_early_exit_with_existing_episode_evidence \
    test_detailed_episodes_do_not_repeat_after_failed_acknowledgement \
    test_stalled_alert_receipt_faults_replay_each_episode_once \
    test_stall_publication_fault_resumes_queued_episode \
    test_recovery_prevents_resuming_an_old_queued_episode \
    test_retired_receipt_fault_drops_only_its_bound_episode \
    test_daemon_only_recovery_rearms_same_stall_identity \
    test_changed_idle_pane_recovery_rearms_stall_before_housekeeping \
    test_acknowledged_stall_identity_does_not_repeat_on_same_episode \
    test_working_hash_transition_surfaces_stalled_diagnosis \
    test_active_pipeline_blocks_escalation \
    test_quiet_pipeline_and_idle_pane_escalates \
    test_active_pipeline_resets_the_wedge_timer \
    test_dead_agent_with_nothing_still_escalates \
    test_no_mode_skips_the_pipeline_read \
    test_stale_working_run_step_does_not_beat_a_pause \
    test_live_agent_with_working_run_stays_working \
    test_secondmate_with_declared_pause_is_not_absorbed \
    test_busy_pane_escalates_even_with_an_active_pipeline \
    test_pane_sourced_working_is_not_gated_on_the_pipeline \
    test_green_pr_awaiting_merge_is_absorbed_by_the_real_poll \
    test_stalled_validation_overrides_previous_merge_wait \
    test_green_pr_without_an_armed_watch_still_surfaces \
    test_stalled_run_step_is_not_absorbed_by_pause_class \
    test_declared_pause_preserves_stalled_diagnosis \
    test_paused_stalled_pipeline_surfaces_on_new_and_same_hash \
    test_stalled_pipeline_surfaces_with_detail_on_the_wake_line \
    test_secondmate_paused_still_writes_the_recheck_marker \
    test_sibling_table_rows_are_not_active_steps \
    test_unattributed_run_is_not_this_tasks_pipeline \
    test_done_without_a_pr_url_is_not_awaiting_merge \
    test_blank_line_between_rows_does_not_hide_a_running_step \
    test_unreadable_activity_is_no_answer_not_a_stop \
    test_green_pr_awaiting_merge_absorbed_on_a_repeat_hash \
    test_unrelated_custom_check_is_not_an_armed_merge_watch \
    test_awaiting_merge_absorb_stays_throttled_across_restarts \
    test_awaiting_merge_absorb_resurfaces_once_the_window_elapses
fi

for test_name in "$@"; do
  case "$test_name" in
    test_*) declare -F "$test_name" >/dev/null || { printf 'unknown test: %s\n' "$test_name" >&2; exit 2; } ;;
    *) printf 'unknown test: %s\n' "$test_name" >&2; exit 2 ;;
  esac
  "$test_name"
  test_status=$?
  [ "$test_status" -eq 0 ] || exit "$test_status"
done
exit "$FAILED"
