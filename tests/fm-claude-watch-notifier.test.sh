#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher notifier
# (bin/fm-claude-watch-notifier.sh, docs/watcher-continuity.md).
#
# The notifier is the former auto-arm, repurposed to PARK until it can exit 2 on a
# coordinator-published ready-to-notify record. These tests cover its retained
# entry gates - scope, session-lock identity, AFK, supervision need, single-flight,
# foreign-host stand-down, and the parent-TERM interrupted-epoch trap - and its new
# park-and-notify body. The gates are exercised hermetically as a child of a fake
# harness (a bash symlink named "claude") whose pid holds the fixture home's
# session lock; stale-owner cases leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh. The ready record is written directly by the test
# (the coordinator that publishes it for real is covered by
# tests/fm-claude-watch-coordinator.test.sh), so the notifier's park/notify
# decision is isolated from a live watcher.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-watch-notifier)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

install_notifier_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-watch-notifier.sh" "$dir/bin/fm-claude-watch-notifier.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-watch.sh" "$dir/bin/fm-watch.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-watch-notifier.sh" "$dir/bin/fm-lock.sh" "$dir/bin/fm-watch.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_notifier_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-notifier-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree (git-dir != git-common-dir): a child task worktree
# that must keep the notifier inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/notifier-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_notifier_scripts "$dir"
  printf '%s\n' "$dir"
}

# Write a ready-to-notify record for the given session owner and ready_seq. The
# coordinator generation embeds the owner, as the real coordinator writes it.
write_ready() {  # <dir> <session-owner> <ready-seq>
  local dir=$1 owner=$2 seq=$3
  {
    printf 'ready_seq=%s\n' "$seq"
    printf 'recovery_generation=none\n'
    printf 'predecessor_arm_pid=none\n'
    printf 'successor_watch_pid=12345\n'
    printf 'successor_watch_identity=fixture-identity\n'
    printf 'coordinator_generation=coord-%s-99\n' "$owner"
    printf 'session_owner=%s\n' "$owner"
    printf 'published_at=%s\n' "$(date +%s)"
  } > "$dir/state/.claude-ready-to-notify"
}

# Fabricate a live coordinator lock so a parked notifier keeps waiting instead of
# tripping its coordinator-absent bound. Echoes the holder pid to stop later.
COORD_HOLDER=
start_fake_coordinator() {  # <dir>
  local dir=$1
  sleep 120 &
  COORD_HOLDER=$!
  mkdir -p "$dir/state/.claude-coordinator.lock"
  printf '%s\n' "$COORD_HOLDER" > "$dir/state/.claude-coordinator.lock/pid"
  printf 'coordinator\n' > "$dir/state/.claude-coordinator.lock/role"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# Run the notifier as a child of the fake harness holding the session lock, with a
# bounded wall-clock so a genuine park does not hang the suite. Prints exit code on
# stdout via RC=. $1 = dir, remaining args are extra env assignments.
run_notifier_bounded() {  # <dir> <max-seconds> [env=val ...]
  local dir=$1 maxs=$2; shift 2
  local extra="$*" rc
  FM_HOME="$dir" NOTIF_EXTRA="$extra" NOTIF_MAX="$maxs" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    env $NOTIF_EXTRA "$FM_HOME/bin/fm-claude-watch-notifier.sh" >"$FM_HOME/state/n.out" 2>"$FM_HOME/state/n.err" &
    np=$!
    i=0
    while [ "$i" -lt $((NOTIF_MAX * 10)) ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$np" 2>/dev/null; then kill "$np" 2>/dev/null; echo PARKED > "$FM_HOME/state/n.rc"; else wait "$np"; echo "$?" > "$FM_HOME/state/n.rc"; fi
  ' </dev/null
  rc=$(cat "$dir/state/n.rc" 2>/dev/null)
  printf '%s\n' "$rc"
}

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir rc
  base="$TMP_ROOT/crew-base"; dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  rc=$(run_notifier_bounded "$dir" 3)
  [ "$rc" = 0 ] || fail "notifier must stay inert (exit 0) in a child task worktree, got $rc"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "notifier wrote an epoch inside a child worktree"
  pass "notifier: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-watch-notifier.sh" 2>&1); status=$?
  expect_code 0 "$status" "notifier must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "notifier wrote an epoch without a session lock"
  pass "notifier: inert with no session lock"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other rc owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-watch-notifier.sh"' 2>&1); rc=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$rc" "notifier must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "notifier replaced another live harness owner"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "notifier wrote an epoch while another session owned the lock"
  pass "notifier: inert without epoch or lock replacement when another live harness owns the home"
}

test_reclaims_stale_session_lock() {
  local dir rc expected actual
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  start_fake_coordinator "$dir"
  write_ready "$dir" 0 1  # a ready record; owner filled in after reclaim below is irrelevant to reclaim proof
  rc=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >/dev/null 2>&1 &
    np=$!
    i=0; while [ "$i" -lt 30 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    kill "$np" 2>/dev/null; echo done
  ' </dev/null)
  expected=$(cat "$dir/state/expected-owner")
  actual=$(cat "$dir/state/.lock")
  kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
  [ "$actual" = "$expected" ] || fail "stale session lock was not claimed by the current harness: expected $expected, got $actual"
  pass "notifier: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before parking"
}

test_inert_when_afk() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  rc=$(run_notifier_bounded "$dir" 3)
  [ "$rc" = 0 ] || fail "notifier must exit 0 while away mode owns triage, got $rc"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "notifier wrote an epoch while AFK"
  pass "notifier: inert while AFK owns supervision"
}

test_inert_when_fleet_idle() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  rc=$(run_notifier_bounded "$dir" 3)
  [ "$rc" = 0 ] || fail "notifier must exit 0 in an idle home, got $rc"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "notifier wrote an epoch in an idle home"
  pass "notifier: inert with nothing in flight and no X-mode need"
}

test_foreign_host_stands_down() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/foreign-host")
  : > "$dir/state/task.meta"
  # A Cursor-shaped payload (carries cursor_version) must make the notifier stand down.
  out=$(printf '%s\n' '{"session_id":"s","cursor_version":"2026.08.11"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-watch-notifier.sh"
      ' 2>&1); status=$?
  expect_code 0 "$status" "a Cursor-delivered payload must make the notifier stand down"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "notifier ran on a foreign-host payload"
  pass "notifier: stands down on a Cursor-delivered (foreign-host) payload"
}

# --- park and notify ----------------------------------------------------------

test_exits_two_on_fresh_ready_record() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/ready-exit2")
  : > "$dir/state/task.meta"
  # The notifier's session owner is its own harness pid, written into .lock by the
  # runner. Point the ready record's session_owner at that pid by pre-writing the
  # record after the runner sets the lock: instead, use a wrapper that writes the
  # ready record for its own pid, then runs the notifier.
  rc=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    {
      printf "ready_seq=5\n"
      printf "recovery_generation=none\n"
      printf "predecessor_arm_pid=none\n"
      printf "successor_watch_pid=12345\n"
      printf "successor_watch_identity=fixture\n"
      printf "coordinator_generation=coord-$$-99\n"
      printf "session_owner=$$\n"
      printf "published_at=$(date +%s)\n"
    } > "$FM_HOME/state/.claude-ready-to-notify"
    printf "%s\t5\tsignal\ttask.status\tblocked: needs a decision\n" "$(date +%s)" > "$FM_HOME/state/.wake-queue"
    printf "5\n" > "$FM_HOME/state/.wake-queue.seq"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >"$FM_HOME/state/n.out" 2>"$FM_HOME/state/n.err" &
    np=$!
    i=0; while [ "$i" -lt 60 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$np" 2>/dev/null; then kill "$np" 2>/dev/null; echo PARKED; else wait "$np"; echo "$?"; fi
  ' </dev/null)
  expect_code 2 "$rc" "a fresh ready record for this session must make the notifier exit 2"
  assert_contains "$(cat "$dir/state/n.err")" "firstmate watcher wake" "exit 2 must carry the rewake banner"
  assert_contains "$(cat "$dir/state/n.err")" "do NOT run bin/fm-watch-arm.sh" "the banner must forbid a duplicate manual arm"
  [ "$(cat "$dir/state/.claude-notifier-surfaced-seq")" = 5 ] || fail "surfaced high-water mark must advance to the ready_seq"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "notifier: a fresh ready record for this session triggers exactly one exit-2 rewake"
}

test_upgraded_home_leftover_seq_does_not_rewake() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/upgraded-seq")
  : > "$dir/state/task.meta"
  start_fake_coordinator "$dir"
  # Existing home after upgrade: leftover acked high-water, empty queue, no
  # surfaced-seq file. First publish of that high-water must not open a turn.
  : > "$dir/state/.wake-queue"
  printf '12\n' > "$dir/state/.wake-queue.seq"
  rc=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    {
      printf "ready_seq=12\n"
      printf "recovery_generation=none\n"
      printf "predecessor_arm_pid=none\n"
      printf "successor_watch_pid=12345\n"
      printf "successor_watch_identity=fixture\n"
      printf "coordinator_generation=coord-$$-99\n"
      printf "session_owner=$$\n"
      printf "published_at=$(date +%s)\n"
    } > "$FM_HOME/state/.claude-ready-to-notify"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >"$FM_HOME/state/n.out" 2>"$FM_HOME/state/n.err" &
    np=$!
    i=0; while [ "$i" -lt 30 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$np" 2>/dev/null; then kill "$np" 2>/dev/null; echo PARKED; else wait "$np"; echo "$?"; fi
  ' </dev/null)
  kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
  [ "$rc" = PARKED ] || fail "upgraded-home leftover seq must not exit 2, got $rc"
  case "$(cat "$dir/state/n.err" 2>/dev/null || true)" in
    *"firstmate watcher wake"*) fail "upgraded-home leftover seq printed a rewake banner" ;;
  esac
  [ "$(cat "$dir/state/.claude-notifier-surfaced-seq" 2>/dev/null || true)" = 12 ] \
    || fail "first publish with an empty queue must baseline surfaced-seq to the leftover high-water"
  pass "notifier: leftover wake-queue.seq on an upgraded empty home does not open a handling turn"
}

test_ignores_stale_session_ready_record() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/stale-ready")
  : > "$dir/state/task.meta"
  start_fake_coordinator "$dir"
  # A ready record from a DIFFERENT session owner must never be surfaced.
  write_ready "$dir" 111111 9
  rc=$(run_notifier_bounded "$dir" 3 FM_CLAUDE_NOTIFIER_COORD_WAIT=60)
  kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
  [ "$rc" = PARKED ] || fail "notifier must keep parking (not exit 2) on a foreign-session ready record, got $rc"
  [ ! -e "$dir/state/.claude-notifier-surfaced-seq" ] || fail "notifier surfaced a foreign-session ready record"
  pass "notifier: a ready record from another session generation is never surfaced"
}

test_typed_failure_when_coordinator_absent() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/coord-absent")
  : > "$dir/state/task.meta"
  # No coordinator lock and no live watcher: past the bounded wait, the notifier
  # must surface a typed coordinator-degraded failure, record the failure-episode
  # notice the guard reads, and exit 2.
  rc=$(run_notifier_bounded "$dir" 6 FM_CLAUDE_NOTIFIER_COORD_WAIT=2)
  [ "$rc" = 2 ] || fail "notifier must exit 2 with a typed failure when the coordinator never appears, got $rc"
  assert_contains "$(cat "$dir/state/n.err")" "supervision DEGRADED" "the typed failure must name degraded supervision"
  assert_contains "$(cat "$dir/state/n.err")" "no watcher coordinator claimed this home" "the typed failure must name the absent coordinator"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "coordinator-absent failure must record outcome=failed, got: $(epoch_outcome "$dir")"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "the first coordinator-absent failure must record the episode notice the guard reads"
  pass "notifier: a genuinely absent coordinator surfaces a typed failure and records the guard's episode notice"
}

test_repeated_coordinator_failure_notifies_once() {
  local dir rc1 rc2
  dir=$(make_primary_dir "$TMP_ROOT/coord-absent-dedup")
  : > "$dir/state/task.meta"
  rc1=$(run_notifier_bounded "$dir" 6 FM_CLAUDE_NOTIFIER_COORD_WAIT=2)
  local first_err; first_err=$(cat "$dir/state/n.err")
  rc2=$(run_notifier_bounded "$dir" 6 FM_CLAUDE_NOTIFIER_COORD_WAIT=2)
  local second_err; second_err=$(cat "$dir/state/n.err")
  [ "$rc1" = 2 ] || fail "the first coordinator-absent failure must exit 2, got $rc1"
  [ "$rc2" = 2 ] || fail "a consecutive coordinator-absent failure must keep forcing a Stop-owned retry (exit 2), got $rc2"
  [ -n "$first_err" ] || fail "the first failure did not surface its notice"
  [ -z "$second_err" ] || fail "a consecutive failure repeated the operator notice: $second_err"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "the second failure must record failed-suppressed, got: $(epoch_outcome "$dir")"
  pass "notifier: consecutive coordinator-absent failures notify once and keep retrying"
}

test_ready_record_resets_failure_episode() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/coord-recovery")
  : > "$dir/state/task.meta"
  # Seed a prior failure episode; a fresh ready record (the coordinator verified a
  # live successor) is positive recovery, so the notifier must clear the episode
  # markers before exiting 2, matching the guard's fm_failure_episode_reset contract.
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  printf 'session=x\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  rc=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    {
      printf "ready_seq=5\nrecovery_generation=none\npredecessor_arm_pid=none\n"
      printf "successor_watch_pid=1\nsuccessor_watch_identity=x\n"
      printf "coordinator_generation=coord-$$-1\nsession_owner=$$\npublished_at=$(date +%s)\n"
    } > "$FM_HOME/state/.claude-ready-to-notify"
    printf "%s\t5\tsignal\ttask.status\tblocked: needs a decision\n" "$(date +%s)" > "$FM_HOME/state/.wake-queue"
    printf "5\n" > "$FM_HOME/state/.wake-queue.seq"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >/dev/null 2>&1 &
    np=$!
    i=0; while [ "$i" -lt 60 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$np" 2>/dev/null; then kill "$np" 2>/dev/null; echo PARKED; else wait "$np"; echo "$?"; fi
  ' </dev/null)
  expect_code 2 "$rc" "a fresh ready record must still wake (exit 2) while clearing the failure episode"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "positive recovery must clear the failure notice"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "positive recovery must clear the attended alarm"
  assert_absent "$dir/state/.turnend-claude-blocks" "positive recovery must clear the bounded block budget"
  pass "notifier: a fresh ready record clears the failure episode (positive recovery) and still wakes"
}

test_afk_mid_park_exits_clean() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid-park")
  : > "$dir/state/task.meta"
  start_fake_coordinator "$dir"
  # Start parked, then AFK appears: the notifier must exit 0 without notifying.
  rc=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >"$FM_HOME/state/n.out" 2>"$FM_HOME/state/n.err" &
    np=$!
    sleep 1
    : > "$FM_HOME/state/.afk"
    i=0; while [ "$i" -lt 40 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$np" 2>/dev/null; then kill "$np" 2>/dev/null; echo PARKED; else wait "$np"; echo "$?"; fi
  ' </dev/null)
  kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
  expect_code 0 "$rc" "AFK appearing mid-park must make the notifier exit 0 without notifying"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "mid-park AFK must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "notifier: AFK appearing mid-park hands triage to the daemon with a clean exit"
}

test_single_flight_admits_one_owner() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  start_fake_coordinator "$dir"
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >/dev/null 2>&1 &
    p1=$!
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    sleep 1
    # Exactly one should be parked (owner); the other should have exited 0 (no lock).
    a=alive; kill -0 "$p1" 2>/dev/null || a=dead
    b=alive; kill -0 "$p2" 2>/dev/null || b=dead
    printf "%s %s\n" "$a" "$b" > "$FM_HOME/state/liveness"
    kill "$p1" "$p2" 2>/dev/null; wait 2>/dev/null
  ' </dev/null
  kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
  local liveness; liveness=$(cat "$dir/state/liveness")
  case "$liveness" in
    "alive dead"|"dead alive") pass "notifier: concurrent firings admit exactly one parked owner" ;;
    *) fail "single-flight did not admit exactly one parked owner: $liveness" ;;
  esac
}

# The exit-143 TERM path: the parent hook is killed mid-park. Its HUP/INT/TERM
# traps must record an "interrupted" epoch outcome so the turn-end guard treats
# this hook as not owning recovery.
test_parent_term_records_interrupted() {
  local dir leader i outcome
  dir=$(make_primary_dir "$TMP_ROOT/parent-term")
  : > "$dir/state/task.meta"
  start_fake_coordinator "$dir"
  printf '%s\n' '{"session_id":"sess-term"}' \
    | FM_HOME="$dir" perl -e 'setpgrp(0,0); exec @ARGV' \
        "$FAKE_CLAUDE" -c '
          printf "%s\n" "$$" > "$FM_HOME/state/.lock"
          env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh"
        ' >/dev/null 2>&1 &
  leader=$!
  # Wait until the notifier has parked (epoch=parked recorded).
  i=0
  while [ "$(epoch_outcome "$dir")" != parked ]; do
    if [ "$i" -ge 200 ] || ! kill -0 "$leader" 2>/dev/null; then
      kill "$leader" 2>/dev/null || true
      kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
      fail "notifier never parked before the interrupt (epoch: $(epoch_outcome "$dir"))"
    fi
    sleep 0.05
    i=$((i + 1))
  done
  kill -TERM -- "-$leader" 2>/dev/null || kill -TERM "$leader" 2>/dev/null || true
  i=0
  outcome=$(epoch_outcome "$dir")
  while [ "$outcome" != interrupted ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    outcome=$(epoch_outcome "$dir")
    i=$((i + 1))
  done
  kill -TERM -- "-$leader" 2>/dev/null || true
  kill "$COORD_HOLDER" 2>/dev/null || true; wait "$COORD_HOLDER" 2>/dev/null || true
  [ "$outcome" = interrupted ] || fail "parent TERM must record outcome=interrupted, got: $outcome"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "parent TERM must release the owner lock via the EXIT trap"
  pass "notifier: parent TERM records interrupted and releases the owner lock"
}

test_active_in_marked_secondmate_home() {
  local dir rc
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  # A fresh ready record for this session must exit 2 in a marked secondmate home too.
  rc=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    {
      printf "ready_seq=3\nrecovery_generation=none\npredecessor_arm_pid=none\n"
      printf "successor_watch_pid=1\nsuccessor_watch_identity=x\n"
      printf "coordinator_generation=coord-$$-1\nsession_owner=$$\npublished_at=$(date +%s)\n"
    } > "$FM_HOME/state/.claude-ready-to-notify"
    printf "%s\t3\tsignal\ttask.status\tblocked: needs a decision\n" "$(date +%s)" > "$FM_HOME/state/.wake-queue"
    printf "3\n" > "$FM_HOME/state/.wake-queue.seq"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" >/dev/null 2>&1 &
    np=$!
    i=0; while [ "$i" -lt 60 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$np" 2>/dev/null; then kill "$np" 2>/dev/null; echo PARKED; else wait "$np"; echo "$?"; fi
  ' </dev/null)
  expect_code 2 "$rc" "a marked secondmate home must get the same active notifier as the main primary"
  pass "notifier: active in a marked secondmate home"
}

test_rejects_handover_between_identity_and_owner_read() {
  local dir other session_a rc i
  dir=$(make_primary_dir "$TMP_ROOT/handover-startup")
  : > "$dir/state/task.meta"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  rm -f "$dir/state/.lock"
  mkfifo "$dir/state/.lock"
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/session-a"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" \
      >"$FM_HOME/state/n.out" 2>"$FM_HOME/state/n.err"
    echo "$?" > "$FM_HOME/state/n.rc"
  ' </dev/null &
  i=0
  while [ ! -f "$dir/state/session-a" ]; do
    if [ "$i" -ge 100 ] || ! kill -0 $! 2>/dev/null; then
      kill "$other" $! 2>/dev/null || true
      fail "session A never started before the identity FIFO write"
    fi
    sleep 0.05
    i=$((i + 1))
  done
  session_a=$(cat "$dir/state/session-a")
  # Identity gate reads the FIFO first and must still see this session.
  printf '%s\n' "$session_a" > "$dir/state/.lock"
  # After that read, the lock belongs to the other live session so the post-claim
  # SESSION_OWNER copy cannot adopt the new pid and later exit 2 in A.
  rm -f "$dir/state/.lock"
  printf '%s\n' "$other" > "$dir/state/.lock"
  write_ready "$dir" "$other" 7
  i=0
  while [ ! -f "$dir/state/n.rc" ]; do
    if [ "$i" -ge 100 ]; then
      kill "$other" 2>/dev/null || true
      fail "notifier never exited after a post-identity session handover"
    fi
    sleep 0.05
    i=$((i + 1))
  done
  rc=$(cat "$dir/state/n.rc")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$rc" "a handover between identity and SESSION_OWNER must stand down (exit 0), not wake session A"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "handover stand-down must release the owner lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "handover stand-down must not park or record an epoch"
  [ ! -e "$dir/state/.claude-notifier-surfaced-seq" ] || fail "handover stand-down must not surface the new session's ready record"
  case "$(cat "$dir/state/n.err" 2>/dev/null || true)" in
    *"firstmate watcher wake"*) fail "handover stand-down must not print a rewake banner in session A" ;;
  esac
  pass "notifier: rejects a session handover between the identity gate and SESSION_OWNER read"
}

test_rejects_empty_owner_after_claim() {
  local dir session_a rc i
  dir=$(make_primary_dir "$TMP_ROOT/empty-owner-startup")
  : > "$dir/state/task.meta"
  rm -f "$dir/state/.lock"
  mkfifo "$dir/state/.lock"
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/session-a"
    env FM_CLAUDE_NOTIFIER_COORD_WAIT=60 "$FM_HOME/bin/fm-claude-watch-notifier.sh" \
      >"$FM_HOME/state/n.out" 2>"$FM_HOME/state/n.err"
    echo "$?" > "$FM_HOME/state/n.rc"
  ' </dev/null &
  i=0
  while [ ! -f "$dir/state/session-a" ]; do
    if [ "$i" -ge 100 ] || ! kill -0 $! 2>/dev/null; then
      kill $! 2>/dev/null || true
      fail "session A never started before the empty-owner FIFO write"
    fi
    sleep 0.05
    i=$((i + 1))
  done
  session_a=$(cat "$dir/state/session-a")
  printf '%s\n' "$session_a" > "$dir/state/.lock"
  rm -f "$dir/state/.lock"
  : > "$dir/state/.lock"
  write_ready "$dir" "$session_a" 7
  i=0
  while [ ! -f "$dir/state/n.rc" ]; do
    if [ "$i" -ge 100 ]; then
      fail "notifier never exited after a missing/non-numeric SESSION_OWNER"
    fi
    sleep 0.05
    i=$((i + 1))
  done
  rc=$(cat "$dir/state/n.rc")
  expect_code 0 "$rc" "an empty SESSION_OWNER after the owner-lock claim must stand down (exit 0)"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "empty-owner stand-down must release the owner lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "empty-owner stand-down must not park or record an epoch"
  pass "notifier: rejects an empty SESSION_OWNER after claiming the owner lock"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

test_inert_in_child_worktree
test_inert_without_session_lock
test_inert_when_lock_held_by_other_harness
test_reclaims_stale_session_lock
test_inert_when_afk
test_inert_when_fleet_idle
test_foreign_host_stands_down
test_exits_two_on_fresh_ready_record
test_upgraded_home_leftover_seq_does_not_rewake
test_ignores_stale_session_ready_record
test_typed_failure_when_coordinator_absent
test_repeated_coordinator_failure_notifies_once
test_ready_record_resets_failure_episode
test_afk_mid_park_exits_clean
test_single_flight_admits_one_owner
test_parent_term_records_interrupted
test_active_in_marked_secondmate_home
test_rejects_handover_between_identity_and_owner_read
test_rejects_empty_owner_after_claim
test_fm_lock_status_still_works_with_shared_lib
