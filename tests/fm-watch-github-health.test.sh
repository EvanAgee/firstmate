#!/usr/bin/env bash
# tests/fm-watch-github-health.test.sh - the watcher's GitHub-health hook in the
# slow-check block of bin/fm-watch.sh. The watcher calls
# bin/fm-github-health.sh transition once per CHECK_INTERVAL and queues one
# "check: github-health: <up|down>" wake on a real transition. The transition
# dedup itself (report once per change, silent otherwise) is unit-tested in
# tests/fm-github-health.test.sh against the health script directly; this suite
# proves the watcher actually wires that command into a durable wake and exits,
# and that a first-ever reachable baseline stays silent.
#
# Matrix:
#   (a) a down transition queues exactly one github-health wake and the watcher
#       exits (actionable), with the durable flag set
#   (b) a first-ever reachable baseline queues NO github-health wake (the watcher
#       keeps blocking, so we bound it and assert nothing was queued)
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-github-health-tests)

# Keep the per-task PR-check migration path quiet so the only thing the slow
# block can wake on is the github-health hook.
quiet_migration() {  # <state>
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

# Run a single watcher cycle with an immediate check cadence and a scripted
# reachability verdict. FM_CHECK_INTERVAL=0 makes the slow block due at once.
# FM_ROOT_OVERRIDE points the tangle guard at an inert dir. Returns the watcher's
# exit status; caller inspects <out> and the durable queue.
watch_bg() {  # <dir> <probe-cmd> <out>
  local dir=$1 probe=$2 out=$3 state="$1/state" fakebin="$1/fakebin"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" \
    FM_GH_HEALTH_PROBE_CMD="$probe" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_GUARD_GRACE=0 \
    "$WATCH" > "$out" 2>/dev/null &
}

test_down_transition_queues_one_wake_and_exits() {
  local dir state out pid rc
  dir=$(make_case gh-health-down)
  state="$dir/state"
  out="$dir/out"
  quiet_migration "$state"

  # A confirmed-down verdict is a transition from the (blank) baseline, so the
  # watcher must queue one wake and exit on its own - no kill needed.
  watch_bg "$dir" 'false' "$out"
  pid=$!
  rc=0
  wait_for_exit "$pid" 60 || rc=$?
  [ "$rc" -ne 124 ] || fail "down-transition: watcher did not exit on the github-health wake"

  grep -F 'check: github-health: down' "$out" >/dev/null \
    || fail "down-transition: watcher did not surface the down transition (out: $(cat "$out"))"
  assert_present "$state/.github-down" "down-transition: the durable outage flag was not set"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2>/dev/null \
    || fail "down-transition: drain failed"
  grep "$(printf '\tcheck\t')" "$dir/drain.out" | grep -F github-health \
    | grep -F 'check: github-health: down' >/dev/null \
    || fail "down-transition: the github-health wake was not durably queued"
  pass "watcher queues one github-health wake and exits on a down transition"
}

test_first_up_baseline_queues_no_wake() {
  local dir state out pid
  dir=$(make_case gh-health-first-up)
  state="$dir/state"
  out="$dir/out"
  quiet_migration "$state"

  # A first-ever reachable baseline is not a transition, so the watcher stays
  # silent and keeps blocking. Bound it, then assert nothing github-health was
  # queued and the flag was never set.
  watch_bg "$dir" 'true' "$out"
  pid=$!
  wait_for_exit "$pid" 20 || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  assert_absent "$state/.github-down" "first-up: reachable baseline must not set the flag"
  ! grep -F github-health "$out" >/dev/null \
    || fail "first-up: watcher surfaced a github-health wake on a silent baseline (out: $(cat "$out"))"
  if [ -f "$state/.wake-queue" ]; then
    ! grep -F github-health "$state/.wake-queue" >/dev/null \
      || fail "first-up: a github-health wake was durably queued on a silent baseline"
  fi
  pass "watcher stays silent and queues no wake on a first-ever reachable baseline"
}

test_down_transition_queues_one_wake_and_exits
test_first_up_baseline_queues_no_wake
