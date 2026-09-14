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
    "$@"
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
      run_until_marker "$dir" "$state/.wake-queue"
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

poll_stalled_case() {
  local dir=$1 win=$2 state key target pid deadline count recovery_token completed=0
  state="$dir/state"
  key=$(printf '%s' "$win" | tr ':/.' '___')
  target=$(( $(cat "$state/.count-$key" 2>/dev/null || echo 0) + 2 ))
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then completed=1; break; fi
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
  poll_stall_after_generic_wedge done
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
    . "$ROOT/bin/fm-supervise-daemon.sh"
    LOG="$dir/daemon.log"
    "$@" "$dir/state"
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

test_acknowledged_stall_identity_does_not_repeat_on_same_episode() {
  local dir state win key expected sequence
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
  sequence=$(cat "$state/.wake-queue.seq")
  ack_poll_wake "$dir" || return
  set_poll_pipeline_activity "$dir" 26m
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "acknowledging the stall rearmed a duplicate"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · temporarily unreadable'
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.stale-since-$key.stalled")" = 'review, run 01RUN, agent none' ] || fail "unknown state changed the stalled identity"
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "unknown state emitted a generic duplicate wake"
  set_poll_pipeline_activity "$dir" 26m
  poll_stalled_case "$dir" "$win" || return
  [ "$(cat "$state/.wake-queue.seq")" = "$sequence" ] || fail "unknown state rearmed a duplicate stall"
  set_poll_pipeline_activity "$dir" 15m
  poll_stalled_case "$dir" "$win" || return
  [ ! -e "$state/.stale-since-$key.stalled" ] || fail "known working observation did not clear the identity"
  set_poll_pipeline_activity "$dir" 25m
  poll_stalled_case "$dir" "$win" || return
  [ "$(poll_wake_payload "$dir")" = "$expected" ] || fail "new stalled episode did not notify"
  [ "$(cat "$state/.wake-queue.seq")" -eq "$((sequence + 1))" ] || fail "new stalled episode did not publish exactly once"
  unset FM_FAKE_AXI_STATUS FM_FAKE_CREW_STATE
  ok "full polls retain acknowledged and unknown identities until known recovery"
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

if [ "$#" -gt 0 ]; then
  for test_name in "$@"; do
    "$test_name"
  done
  exit "$FAILED"
fi

test_declared_pause_beats_run_step_done
test_declared_pause_with_live_agent_stays_none
test_poll_reports_stall_after_generic_wedge_removed_timer
test_poll_reports_stall_over_old_terminal_status_without_timer
test_away_poll_reports_stall_after_generic_escalation_removed_marker
test_acknowledged_stall_identity_does_not_repeat_on_same_episode
test_working_hash_transition_surfaces_stalled_diagnosis
test_active_pipeline_blocks_escalation
test_quiet_pipeline_and_idle_pane_escalates
test_active_pipeline_resets_the_wedge_timer
test_dead_agent_with_nothing_still_escalates
test_no_mode_skips_the_pipeline_read
test_stale_working_run_step_does_not_beat_a_pause
test_live_agent_with_working_run_stays_working
test_secondmate_with_declared_pause_is_not_absorbed
test_busy_pane_escalates_even_with_an_active_pipeline
test_pane_sourced_working_is_not_gated_on_the_pipeline
test_green_pr_awaiting_merge_is_absorbed_by_the_real_poll
test_stalled_validation_overrides_previous_merge_wait
test_green_pr_without_an_armed_watch_still_surfaces
test_stalled_run_step_is_not_absorbed_by_pause_class
test_declared_pause_preserves_stalled_diagnosis
test_paused_stalled_pipeline_surfaces_on_new_and_same_hash
test_stalled_pipeline_surfaces_with_detail_on_the_wake_line
test_secondmate_paused_still_writes_the_recheck_marker
test_sibling_table_rows_are_not_active_steps
test_unattributed_run_is_not_this_tasks_pipeline
test_done_without_a_pr_url_is_not_awaiting_merge
test_blank_line_between_rows_does_not_hide_a_running_step
test_unreadable_activity_is_no_answer_not_a_stop
test_green_pr_awaiting_merge_absorbed_on_a_repeat_hash
test_unrelated_custom_check_is_not_an_armed_merge_watch
test_awaiting_merge_absorb_stays_throttled_across_restarts
test_awaiting_merge_absorb_resurfaces_once_the_window_elapses

exit "$FAILED"
