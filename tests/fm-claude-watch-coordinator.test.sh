#!/usr/bin/env bash
# Real-component tests for the Claude watcher coordinator + parked notifier +
# ready-to-notify handshake (bin/fm-claude-watch-coordinator.sh,
# bin/fm-claude-watch-notifier.sh, docs/watcher-continuity.md).
#
# The whole point of the coordinator is that a live watcher is ALWAYS present
# across a long handling turn, with a verified successor armed before any wake is
# surfaced. A fake arm can only emulate the artifacts under review, so these tests
# drive the REAL bin/fm-watch-arm.sh, the REAL bin/fm-watch.sh, the REAL durable
# queue and recovery marker, a temp primary home, and REAL status-file events.
# Only the harness (a bash symlink named "claude" holding the session lock) and
# the watcher's crew-state reader are faked; the arm/watcher/queue layer is real.
# shellcheck disable=SC2016 # single quotes are deliberate where $FM_HOME must expand inside a fake-harness child, and grep needles are literal
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

COORDINATOR="$ROOT/bin/fm-claude-watch-coordinator.sh"
NOTIFIER="$ROOT/bin/fm-claude-watch-notifier.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-watch-coordinator)
fm_git_identity fmtest fmtest@example.invalid

# Fast watcher signal scan so a status change surfaces a real wake quickly; a long
# check/heartbeat interval so only the injected signal drives the cycle.
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999

# Build a real primary checkout with a fake "claude" harness holding the session
# lock, a real bin/, and the crew-state reader the watcher needs. Echoes the home.
make_home() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  ln -s /bin/bash "$fakebin/claude"
  cat > "$fakebin/fm-crew-state.sh" <<'CS'
#!/usr/bin/env bash
printf 'state: unknown · source: none · fake\n'
exit 0
CS
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

# Launch the fake harness that holds the session lock, echo its pid. Its child
# sleeps so the coordinator's ancestry/identity check resolves to a live owner.
HOLDER_PID=
start_lock_holder() {  # <dir>
  local dir=$1
  "$dir/fakebin/claude" -c 'sleep 300' &
  HOLDER_PID=$!
  printf '%s\n' "$HOLDER_PID" > "$dir/state/.lock"
}

# Common env for driving a coordinator/notifier against a real home.
home_env() {  # <dir>
  local dir=$1
  printf 'FM_ROOT_OVERRIDE=%s FM_HOME=%s FM_STATE_OVERRIDE=%s FM_CONFIG_OVERRIDE=%s\n' \
    "$dir" "$dir" "$dir/state" "$dir/config"
}

# Prime the seen marker for a status file so it is NOT a pending signal: the
# watcher then blocks quietly and beats steadily instead of surfacing that line.
prime_seen() {  # <dir> <status-file>
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1/state" "$2"
}

ready_field() {  # <dir> <field>
  sed -n "s/^$2=//p" "$1/state/.claude-ready-to-notify" 2>/dev/null | head -1
}

beacon_age() {  # <dir>
  local m now
  m=$(stat -f %m "$1/state/.last-watcher-beat" 2>/dev/null || stat -c %Y "$1/state/.last-watcher-beat" 2>/dev/null || echo 0)
  now=$(date +%s)
  echo $(( now - m ))
}

watch_pid() {  # <dir>
  cat "$1/state/.watch.lock/pid" 2>/dev/null || true
}

fm_lock_role_of() {  # <dir>
  cat "$1/state/.claude-coordinator.lock/role" 2>/dev/null || true
}

wait_file() {  # <path> <limit-tenths>
  local path=$1 limit=${2:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_bg() {  # <pid>...
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
}

# --- 1. a verified successor owns the lock BEFORE the ready record is published -
# The single assertion that would have caught v1's ordering bug and proves the
# whole fix: when the ready record exists, a live watcher already owns the lock
# with a fresh beacon. The coordinator arms and verifies the successor first, then
# publishes ready.
test_successor_verified_before_ready_publish() {
  local dir coord rs sp wp
  dir=$(make_home successor-first)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"
  prime_seen "$dir" "$dir/state/task.status"

  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/coord.out" 2>&1 &
  coord=$!

  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published a ready record"; }

  # At the instant the ready record exists, the named successor must be the live
  # watcher owning the real lock with a fresh beacon.
  sp=$(ready_field "$dir" successor_watch_pid)
  wp=$(watch_pid "$dir")
  [ -n "$sp" ] && [ "$sp" = "$wp" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "ready record's successor pid ($sp) is not the live watcher lock owner ($wp)"; }
  kill -0 "$sp" 2>/dev/null \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "ready record published for a dead successor pid $sp"; }
  [ "$(beacon_age "$dir")" -lt "${FM_GUARD_GRACE:-300}" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "ready record published with a stale beacon"; }

  rs=$(ready_field "$dir" ready_seq)
  case "$rs" in
    ''|*[!0-9]*) stop_bg "$coord" "$HOLDER_PID"; fail "ready record has no numeric ready_seq" ;;
  esac
  [ "$(ready_field "$dir" session_owner)" = "$(cat "$dir/state/.lock")" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "ready record session_owner does not match the current session lock"; }
  case "$(ready_field "$dir" coordinator_generation)" in
    coord-*) : ;;
    *) stop_bg "$coord" "$HOLDER_PID"; fail "ready record has no coordinator_generation token" ;;
  esac

  stop_bg "$coord" "$HOLDER_PID"
  pass "coordinator: a verified live successor owns the lock before the ready record is published"
}

# --- 2. one stable live watcher keeps the beacon fresh across a long quiet turn -
# The regression that motivates the whole task: a handling turn longer than grace
# must not leave supervision absent. With a quiet fleet the coordinator keeps ONE
# watcher alive and the beacon continuously fresh, mid-turn, with no new Stop.
test_live_watcher_across_long_turn() {
  local dir coord first last t age wp
  dir=$(make_home long-turn)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"
  prime_seen "$dir" "$dir/state/task.status"

  # grace=6s with a 10s "handling turn" is genuinely longer than grace, while the
  # watcher's 1s beat cadence keeps the beacon well under 6s even under CI load - a
  # tighter grace would flake on beat jitter, not on a real supervision gap.
  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_GUARD_GRACE=6 FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/coord.out" 2>&1 &
  coord=$!

  wait_file "$dir/state/.watch.lock/pid" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never established a watcher"; }
  # Let the coordinator settle onto its stable attached watcher.
  sleep 2
  first=$(watch_pid "$dir")

  # Sample across a 10s turn (grace=6s) with no new Stop: a live watcher must own
  # the lock with a beacon under grace the whole time.
  for t in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    wp=$(watch_pid "$dir")
    kill -0 "$wp" 2>/dev/null \
      || { stop_bg "$coord" "$HOLDER_PID"; fail "no live watcher owns the lock at t=${t}s of the long turn"; }
    age=$(beacon_age "$dir")
    [ "$age" -lt 6 ] \
      || { stop_bg "$coord" "$HOLDER_PID"; fail "beacon went stale (${age}s >= 6s grace) mid-turn at t=${t}s"; }
  done
  last=$(watch_pid "$dir")
  [ "$first" = "$last" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "a quiet fleet churned watchers ($first -> $last) instead of keeping one stable"; }

  stop_bg "$coord" "$HOLDER_PID"
  pass "coordinator: one stable live watcher keeps the beacon fresh across a turn longer than grace"
}

# --- 3. an actionable close re-arms a verified successor and re-publishes ready --
# The successor-first loop: an actionable wake that leaves the fleet still in need
# must drive the coordinator to arm a fresh verified successor and re-publish the
# ready record with a bumped high-water mark.
test_actionable_close_rearms_and_republishes() {
  local dir coord first_seq new_seq i
  dir=$(make_home actionable-rearm)
  start_lock_holder "$dir"
  # Two tasks so need persists after one goes actionable.
  printf 'window=x\n' > "$dir/state/one.meta"
  printf 'working: go\n' > "$dir/state/one.status"
  printf 'window=y\n' > "$dir/state/two.meta"
  printf 'working: still busy\n' > "$dir/state/two.status"
  prime_seen "$dir" "$dir/state/one.status"
  prime_seen "$dir" "$dir/state/two.status"

  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/coord.out" 2>&1 &
  coord=$!

  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published an initial ready record"; }
  first_seq=$(ready_field "$dir" ready_seq)

  # A real actionable status change that keeps the task in flight.
  printf 'blocked: needs a decision\n' > "$dir/state/one.status"

  i=0
  new_seq=$first_seq
  while [ "$i" -lt 120 ]; do
    new_seq=$(ready_field "$dir" ready_seq)
    if [ -n "$new_seq" ] && [ "$new_seq" -gt "$first_seq" ] 2>/dev/null; then
      break
    fi
    sleep 0.25
    i=$((i + 1))
  done
  [ -n "$new_seq" ] && [ "$new_seq" -gt "$first_seq" ] 2>/dev/null \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator did not re-publish a higher ready_seq after an actionable close (was $first_seq, now $new_seq)"; }
  # The re-published successor must again be the live watcher.
  [ "$(ready_field "$dir" successor_watch_pid)" = "$(watch_pid "$dir")" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "re-published ready record does not name the current live watcher"; }

  stop_bg "$coord" "$HOLDER_PID"
  pass "coordinator: an actionable close arms a verified successor and re-publishes the ready high-water mark"
}

# --- 4. the notifier parks, then exits 2 exactly once keyed to ready_seq --------
# The Blocker-1 repair: a parked notifier that starts before any wake still wakes
# the idle session exactly once when the ready record advances - keyed to
# ready_seq, never to raw queue-row cardinality.
test_notifier_parks_then_exits_two_on_ready() {
  local dir coord notif nout nerr nrc first_seq new_seq i j surfaced
  dir=$(make_home notifier-park)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/one.meta"
  printf 'working: go\n' > "$dir/state/one.status"
  printf 'window=y\n' > "$dir/state/two.meta"
  printf 'working: still busy\n' > "$dir/state/two.status"
  prime_seen "$dir" "$dir/state/one.status"
  prime_seen "$dir" "$dir/state/two.status"

  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/coord.out" 2>&1 &
  coord=$!
  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published a ready record"; }
  first_seq=$(ready_field "$dir" ready_seq)

  # Start the notifier as a child of the lock-holding harness BEFORE the wake.
  # It must PARK (not exit) because there is no fresh ready record yet: initial
  # ready_seq equals the notifier's surfaced high-water mark of 0 only when 0, but
  # any already-published seq greater than 0 would be surfaced immediately; to test
  # the park, advance the surfaced marker to the current seq first.
  printf '%s\n' "$first_seq" > "$dir/state/.claude-notifier-surfaced-seq"

  nout="$dir/notif.out"; nerr="$dir/notif.err"
  # shellcheck disable=SC2046
  printf '%s\n' '{"session_id":"s"}' | env $(home_env "$dir") PATH="$dir/fakebin:$PATH" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_CLAUDE_NOTIFIER_COORD_WAIT=60 \
    "$dir/fakebin/claude" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-watch-notifier.sh"' >"$nout" 2>"$nerr" &
  notif=$!

  # Confirm it is genuinely parked: still alive after a moment with no ready advance.
  sleep 2
  kill -0 "$notif" 2>/dev/null \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "notifier exited before any fresh ready record - it did not park"; }

  # Drive a real actionable wake so the coordinator re-publishes a higher seq.
  printf 'blocked: needs a decision\n' > "$dir/state/one.status"

  # The notifier should now see the advanced ready record and exit 2.
  j=0
  while [ "$j" -lt 120 ] && kill -0 "$notif" 2>/dev/null; do
    sleep 0.25
    j=$((j + 1))
  done
  if kill -0 "$notif" 2>/dev/null; then
    stop_bg "$notif" "$coord" "$HOLDER_PID"
    fail "notifier stayed parked and never woke on the advanced ready record"
  fi
  wait "$notif"; nrc=$?

  expect_code 2 "$nrc" "the notifier must exit 2 on a fresh ready record"
  assert_contains "$(cat "$nerr")" "firstmate watcher wake" "the notifier must carry the rewake banner"
  assert_contains "$(cat "$nerr")" "do NOT run bin/fm-watch-arm.sh" "the notifier must forbid a duplicate manual arm"
  new_seq=$(ready_field "$dir" ready_seq)
  surfaced=$(cat "$dir/state/.claude-notifier-surfaced-seq" 2>/dev/null)
  [ "$surfaced" = "$new_seq" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "notifier surfaced marker ($surfaced) did not advance to the ready_seq ($new_seq)"; }

  # A second notifier firing on the SAME ready record must NOT re-wake (exit 0),
  # proving exactly-once-per-ready-event keyed to the high-water mark.
  local n2 rc2
  # shellcheck disable=SC2046
  printf '%s\n' '{"session_id":"s"}' | env $(home_env "$dir") PATH="$dir/fakebin:$PATH" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_CLAUDE_NOTIFIER_COORD_WAIT=3 \
    "$dir/fakebin/claude" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-watch-notifier.sh"' >"$dir/n2.out" 2>"$dir/n2.err" &
  n2=$!
  # It will see a live coordinator, keep parking, and we stop it: proving it did
  # NOT exit 2 on the already-surfaced record.
  sleep 3
  if kill -0 "$n2" 2>/dev/null; then
    kill "$n2" 2>/dev/null; wait "$n2" 2>/dev/null || true
    rc2=parked
  else
    wait "$n2"; rc2=$?
  fi
  [ "$rc2" != 2 ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "a second firing re-woke on the already-surfaced ready record"; }

  stop_bg "$coord" "$HOLDER_PID"
  pass "notifier: parks, then exits 2 exactly once keyed to ready_seq, and does not re-wake the same event"
}

# --- 5. a duplicated-row wake still yields one handling event -------------------
# The real double-scan appends duplicate queue rows for one event; the ready
# handshake uses the monotonic high-water mark, so row cardinality never inflates
# the number of handling turns.
test_duplicate_rows_one_handling_event() {
  local dir coord first_seq rows i new_seq
  dir=$(make_home dup-rows)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/one.meta"
  printf 'working: go\n' > "$dir/state/one.status"
  printf 'window=y\n' > "$dir/state/two.meta"
  printf 'working: still busy\n' > "$dir/state/two.status"
  prime_seen "$dir" "$dir/state/one.status"
  prime_seen "$dir" "$dir/state/two.status"

  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/coord.out" 2>&1 &
  coord=$!
  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published a ready record"; }
  first_seq=$(ready_field "$dir" ready_seq)

  printf 'blocked: needs a decision\n' > "$dir/state/one.status"
  i=0
  new_seq=$first_seq
  while [ "$i" -lt 120 ]; do
    new_seq=$(ready_field "$dir" ready_seq)
    [ -n "$new_seq" ] && [ "$new_seq" -gt "$first_seq" ] 2>/dev/null && break
    sleep 0.25
    i=$((i + 1))
  done
  rows=$(grep -c '.' "$dir/state/.wake-queue" 2>/dev/null || echo 0)
  # The queue may legitimately carry more than one row for the single event (the
  # double-scan), but the ready high-water mark advanced by a bounded amount and
  # the notifier keys on that single monotonic value, not the row count.
  [ -n "$new_seq" ] && [ "$new_seq" -gt "$first_seq" ] 2>/dev/null \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "ready_seq did not advance for the duplicated-row event"; }

  # One notifier firing surfaces the event once and advances past it, so a second
  # firing on the same high-water mark cannot re-wake regardless of row count.
  local notif nrc
  # shellcheck disable=SC2046
  printf '%s\n' '{"session_id":"s"}' | env $(home_env "$dir") PATH="$dir/fakebin:$PATH" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_CLAUDE_NOTIFIER_COORD_WAIT=60 \
    "$dir/fakebin/claude" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-watch-notifier.sh"' >"$dir/dn.out" 2>"$dir/dn.err" &
  notif=$!
  i=0
  while [ "$i" -lt 60 ] && kill -0 "$notif" 2>/dev/null; do sleep 0.25; i=$((i + 1)); done
  if kill -0 "$notif" 2>/dev/null; then kill "$notif" 2>/dev/null; wait "$notif" 2>/dev/null || true; nrc=parked; else wait "$notif"; nrc=$?; fi
  expect_code 2 "$nrc" "the notifier must surface the duplicated-row event exactly once (exit 2)"
  [ "$(cat "$dir/state/.claude-notifier-surfaced-seq")" = "$new_seq" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "notifier did not advance past the whole ready_seq despite $rows queue rows"; }

  stop_bg "$coord" "$HOLDER_PID"
  pass "handshake: a duplicated-row event advances one monotonic high-water mark and wakes exactly once"
}

# --- 6. two coordinator firings -> one coordinator owner ------------------------
test_single_coordinator_owner() {
  local dir c1 c2 owner_pids
  dir=$(make_home single-coord)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"
  prime_seen "$dir" "$dir/state/task.status"

  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/c1.out" 2>&1 &
  c1=$!
  wait_file "$dir/state/.claude-coordinator.lock/pid" 300 \
    || { stop_bg "$c1" "$HOLDER_PID"; fail "first coordinator never took the coordinator lock"; }
  # A second firing must find the live owner and exit 0 immediately.
  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/c2.out" 2>&1 &
  c2=$!
  local i=0 rc2=
  while [ "$i" -lt 60 ]; do
    if ! kill -0 "$c2" 2>/dev/null; then wait "$c2"; rc2=$?; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$rc2" = 0 ] \
    || { stop_bg "$c1" "$c2" "$HOLDER_PID"; fail "a second coordinator firing did not exit 0 against the live owner (rc=$rc2)"; }
  [ "$(fm_lock_role_of "$dir")" = coordinator ] \
    || { stop_bg "$c1" "$HOLDER_PID"; fail "coordinator lock role is not 'coordinator'"; }

  stop_bg "$c1" "$HOLDER_PID"
  pass "coordinator: concurrent firings admit exactly one coordinator owner"
}

# --- 7. a coordinator lock alone does NOT satisfy the turn-end guard ------------
# Coordinator state is diagnostic evidence, not notification ownership. A live
# coordinator with no live watcher and no live notifier must NOT let a Stop pass.
test_coordinator_lock_does_not_satisfy_guard() {
  local dir gout grc holder
  dir=$(make_home guard-coord)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"

  # Fabricate a LIVE coordinator lock (role coordinator) with a long-lived holder,
  # but NO watcher and NO notifier. The guard must still block.
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-coordinator.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-coordinator.lock/pid"
  printf 'coordinator\n' > "$dir/state/.claude-coordinator.lock/role"

  gout=$(printf '%s\n' '{"session_id":"g","stop_hook_active":false}' \
    | env FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
        PATH="$dir/fakebin:$PATH" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=300 \
        "$dir/fakebin/claude" -c '"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude' 2>&1)
  grc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$grc" "a live coordinator lock alone must NOT satisfy the turn-end guard"
  assert_contains "$gout" "SUPERVISION IS OFF" "the guard must block with its off-supervision banner"

  stop_bg "$HOLDER_PID"
  pass "guard: a coordinator lock alone never satisfies the turn-end guard"
}

# --- 8. session handover: coordinator stands down when a new session owns .lock -
test_coordinator_stands_down_on_session_handover() {
  local dir coord i
  dir=$(make_home handover)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"
  prime_seen "$dir" "$dir/state/task.status"

  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CLAUDE_COORD_READY_TIMEOUT=15 bash "$COORDINATOR" </dev/null >"$dir/coord.out" 2>&1 &
  coord=$!
  # Wait until the coordinator is FULLY established (ready record published), which
  # proves it has captured its own session owner. Changing .lock before that would
  # race the coordinator's own SESSION_OWNER read and make it adopt the new pid.
  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never established (no ready record)"; }
  local captured_owner
  captured_owner=$(cat "$dir/state/.lock")

  # A new session generation takes over the session lock with a different owner pid.
  [ "$captured_owner" = 424242 ] && printf '424243\n' > "$dir/state/.lock" || printf '424242\n' > "$dir/state/.lock"

  # Generous bound: under full-suite load the coordinator may be mid-readiness or
  # in its quiet-wait poll when the lock changes; it stands down at the next gate
  # check, which is well under this window.
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$coord" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$coord" 2>/dev/null; then
    stop_bg "$coord" "$HOLDER_PID"
    fail "coordinator did not stand down after a session handover"
  fi
  wait "$coord" 2>/dev/null || true
  pass "coordinator: stands down cleanly when a new session generation owns the session lock"
}

test_successor_verified_before_ready_publish
test_live_watcher_across_long_turn
test_actionable_close_rearms_and_republishes
test_notifier_parks_then_exits_two_on_ready
test_duplicate_rows_one_handling_event
test_single_coordinator_owner
test_coordinator_lock_does_not_satisfy_guard
test_coordinator_stands_down_on_session_handover
