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

# Launch a fake Claude session that owns state/.lock and keeps harness identity.
# `bash -c 'sleep 300'` last-command-execs into sleep on Linux, so the lock pid
# would stop looking like a harness; a live loop keeps the claude argv[0].
# Children started via session_eval inherit that identity. CI has no ambient
# Claude/Pi ancestor, so a sibling coordinator stands down at the identity gate
# and never publishes a ready record.
HOLDER_PID=
start_lock_holder() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state/session-jobs"
  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    "$dir/fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      while :; do
        for f in "$FM_HOME/state/session-jobs"/run-*.sh; do
          [ -f "$f" ] || continue
          id=${f##*/run-}
          id=${id%.sh}
          started="$FM_HOME/state/session-jobs/$id.started"
          mv "$f" "$started" || continue
          bash "$started" >"$FM_HOME/state/session-jobs/$id.out" 2>"$FM_HOME/state/session-jobs/$id.err" &
          printf "%s\n" "$!" > "$FM_HOME/state/session-jobs/$id.pid"
        done
        sleep 0.05
      done
    ' </dev/null &
  HOLDER_PID=$!
  wait_file "$dir/state/.lock" 50 \
    || { stop_bg "$HOLDER_PID"; fail "session never wrote the lock"; }
}

# Run a bash snippet as a child of the lock-holding claude. Echoes the child pid.
session_eval() {  # <dir> <job-id> <snippet>
  local dir=$1 id=$2 snippet=$3
  printf '%s\n' "$snippet" > "$dir/state/session-jobs/run-${id}.sh.tmp"
  mv "$dir/state/session-jobs/run-${id}.sh.tmp" "$dir/state/session-jobs/run-${id}.sh"
  wait_file "$dir/state/session-jobs/${id}.pid" 50 || return 1
  cat "$dir/state/session-jobs/${id}.pid"
}

# Start the real coordinator as a session child. Extra args are env assignments.
# Writes $dir/<job-id>.out and echoes the coordinator pid.
start_coordinator() {  # <dir> <job-id> [env=val ...]
  local dir=$1 id=$2
  shift 2
  session_eval "$dir" "$id" "
    exec env $* FM_CLAUDE_COORD_READY_TIMEOUT=\${FM_CLAUDE_COORD_READY_TIMEOUT:-15} \\
      bash \"$COORDINATOR\" </dev/null >\"$dir/${id}.out\" 2>&1
  "
}

# Start the real notifier as a session child so identity matches the lock holder.
start_notifier() {  # <dir> <job-id> [env=val ...]
  local dir=$1 id=$2
  shift 2
  session_eval "$dir" "$id" "
    printf '%s\\n' '{\"session_id\":\"s\"}' | env $* \\
      bash \"$NOTIFIER\" >\"$dir/${id}.out\" 2>\"$dir/${id}.err\"
    printf '%s\\n' \"\$?\" > \"$dir/${id}.rc\"
  "
}

# Read a session-child exit code. The child is not a descendant of this test
# shell, so wait(1) cannot collect it.
session_child_rc() {  # <dir> <job-id>
  wait_file "$1/$2.rc" 50 || return 1
  cat "$1/$2.rc"
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

  coord=$(start_coordinator "$dir" coord) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the coordinator"; }

  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published a ready record"$'\n'"$(cat "$dir/coord.out" 2>/dev/null)"; }

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
  coord=$(start_coordinator "$dir" coord FM_GUARD_GRACE=6) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the long-turn coordinator"; }

  wait_file "$dir/state/.watch.lock/pid" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never established a watcher"$'\n'"$(cat "$dir/coord.out" 2>/dev/null)"; }
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

  coord=$(start_coordinator "$dir" coord) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the re-arm coordinator"; }

  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published an initial ready record"$'\n'"$(cat "$dir/coord.out" 2>/dev/null)"; }
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

  coord=$(start_coordinator "$dir" coord) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the park coordinator"; }
  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published a ready record"$'\n'"$(cat "$dir/coord.out" 2>/dev/null)"; }
  first_seq=$(ready_field "$dir" ready_seq)

  # Start the notifier as a child of the lock-holding harness BEFORE the wake.
  # It must PARK (not exit) because there is no fresh ready record yet: initial
  # ready_seq equals the notifier's surfaced high-water mark of 0 only when 0, but
  # any already-published seq greater than 0 would be surfaced immediately; to test
  # the park, advance the surfaced marker to the current seq first.
  printf '%s\n' "$first_seq" > "$dir/state/.claude-notifier-surfaced-seq"

  nout="$dir/notif.out"; nerr="$dir/notif.err"
  notif=$(start_notifier "$dir" notif FM_CLAUDE_NOTIFIER_COORD_WAIT=60) \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "session never started the parked notifier"; }

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
  nrc=$(session_child_rc "$dir" notif) \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "parked notifier never recorded an exit code"; }

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
  n2=$(start_notifier "$dir" n2 FM_CLAUDE_NOTIFIER_COORD_WAIT=3) \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "session never started the second notifier"; }
  # It will see a live coordinator, keep parking, and we stop it: proving it did
  # NOT exit 2 on the already-surfaced record.
  sleep 3
  if kill -0 "$n2" 2>/dev/null; then
    kill "$n2" 2>/dev/null || true
    rc2=parked
  else
    rc2=$(session_child_rc "$dir" n2 || echo died)
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

  coord=$(start_coordinator "$dir" coord) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the duplicate-row coordinator"; }
  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never published a ready record"$'\n'"$(cat "$dir/coord.out" 2>/dev/null)"; }
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
  notif=$(start_notifier "$dir" dn FM_CLAUDE_NOTIFIER_COORD_WAIT=60) \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "session never started the duplicate-row notifier"; }
  i=0
  while [ "$i" -lt 60 ] && kill -0 "$notif" 2>/dev/null; do sleep 0.25; i=$((i + 1)); done
  if kill -0 "$notif" 2>/dev/null; then kill "$notif" 2>/dev/null || true; nrc=parked; else nrc=$(session_child_rc "$dir" dn || echo died); fi
  expect_code 2 "$nrc" "the notifier must surface the duplicated-row event exactly once (exit 2)"
  [ "$(cat "$dir/state/.claude-notifier-surfaced-seq")" = "$new_seq" ] \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "notifier did not advance past the whole ready_seq despite $rows queue rows"; }

  stop_bg "$coord" "$HOLDER_PID"
  pass "handshake: a duplicated-row event advances one monotonic high-water mark and wakes exactly once"
}

# --- 6. two coordinator firings -> one coordinator owner ------------------------
test_single_coordinator_owner() {
  local dir c1 c2
  dir=$(make_home single-coord)
  start_lock_holder "$dir"
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"
  prime_seen "$dir" "$dir/state/task.status"

  c1=$(start_coordinator "$dir" c1) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the first coordinator"; }
  wait_file "$dir/state/.claude-coordinator.lock/pid" 300 \
    || { stop_bg "$c1" "$HOLDER_PID"; fail "first coordinator never took the coordinator lock"; }
  # A second firing must find the live owner and exit 0 immediately.
  c2=$(start_coordinator "$dir" c2) \
    || { stop_bg "$c1" "$HOLDER_PID"; fail "session never started the second coordinator"; }
  local i=0
  while [ "$i" -lt 60 ] && kill -0 "$c2" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$c2" 2>/dev/null; then
    stop_bg "$c1" "$c2" "$HOLDER_PID"
    fail "a second coordinator firing stayed alive instead of yielding to the live owner"
  fi
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

  session_eval "$dir" guard '
    printf "%s\n" "{\"session_id\":\"g\",\"stop_hook_active\":false}" \
      | env FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=300 \
        "$FM_HOME/bin/fm-turnend-guard.sh" --claude >"$FM_HOME/state/guard.out" 2>&1
    printf "%s\n" "$?" > "$FM_HOME/state/guard.rc"
  ' >/dev/null || { stop_bg "$holder" "$HOLDER_PID"; fail "session never started the turn-end guard"; }
  wait_file "$dir/state/guard.rc" 50 \
    || { stop_bg "$holder" "$HOLDER_PID"; fail "turn-end guard never recorded an exit code"$'\n'"$(cat "$dir/state/session-jobs/guard.err" "$dir/state/session-jobs/guard.started" 2>/dev/null)"; }
  gout=$(cat "$dir/state/guard.out" 2>/dev/null || true)
  grc=$(cat "$dir/state/guard.rc" 2>/dev/null || true)
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

  coord=$(start_coordinator "$dir" coord) \
    || { stop_bg "$HOLDER_PID"; fail "session never started the handover coordinator"; }
  # Wait until the coordinator is FULLY established (ready record published), which
  # proves it has captured its own session owner. Changing .lock before that would
  # race the coordinator's own SESSION_OWNER read and make it adopt the new pid.
  wait_file "$dir/state/.claude-ready-to-notify" 400 \
    || { stop_bg "$coord" "$HOLDER_PID"; fail "coordinator never established (no ready record)"$'\n'"$(cat "$dir/coord.out" 2>/dev/null)"; }
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

# --- 9. a persistent successor-confirm failure stands the coordinator down -----
# A live coordinator that never confirms a successor used to park the notifier
# forever and let the turn-end guard allow a blind Stop. After a bounded streak
# of consecutive successor-timeouts with no healthy watcher, the coordinator must
# release its lock and exit so the existing coordinator-absent notifier/guard
# progression can run.
test_coordinator_stands_down_after_successor_timeout_streak() {
  local dir session lock_holder coord notif n2 i gout grc
  dir=$(make_home successor-timeout-standdown)
  printf 'window=x\n' > "$dir/state/task.meta"
  printf 'working: go\n' > "$dir/state/task.status"
  prime_seen "$dir" "$dir/state/task.status"

  # One session-owning claude holds .lock and launches both hooks as children, so
  # identity matches a real Stop. A live non-watcher holds the watch lock so the
  # REAL arm/watch never confirm a successor.
  # shellcheck disable=SC2046
  env $(home_env "$dir") PATH="$dir/fakebin:$PATH" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_COORDINATOR="$COORDINATOR" FM_NOTIFIER="$NOTIFIER" \
    "$dir/fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      sleep 180 &
      printf "%s\n" "$!" > "$FM_HOME/state/watch-holder.pid"
      mkdir -p "$FM_HOME/state/.watch.lock"
      printf "%s\n" "$!" > "$FM_HOME/state/.watch.lock/pid"
      env FM_ARM_CONFIRM_TIMEOUT=1 FM_CLAUDE_COORD_READY_TIMEOUT=1 \
        FM_CLAUDE_COORD_SUCCESSOR_TIMEOUT_STREAK=3 \
        bash "$FM_COORDINATOR" </dev/null >"$FM_HOME/coord.out" 2>&1 &
      printf "%s\n" "$!" > "$FM_HOME/state/coord.pid"
      printf "%s\n" "{\"session_id\":\"standdown\"}" | env FM_CLAUDE_NOTIFIER_COORD_WAIT=4 \
        FM_CLAUDE_NOTIFIER_PARK_POLL=0.2 \
        bash "$FM_NOTIFIER" >"$FM_HOME/notif.out" 2>"$FM_HOME/notif.err" &
      printf "%s\n" "$!" > "$FM_HOME/state/notif.pid"
      wait "$!"
      printf "%s\n" "$?" > "$FM_HOME/state/notif.rc"
      sleep 180
    ' </dev/null &
  session=$!

  wait_file "$dir/state/.claude-coordinator.lock/pid" 200 \
    || { stop_bg "$session"; fail "coordinator never claimed its lock before the failing-arm streak"; }
  lock_holder=$(cat "$dir/state/watch-holder.pid" 2>/dev/null || true)
  coord=$(cat "$dir/state/coord.pid" 2>/dev/null || true)
  notif=$(cat "$dir/state/notif.pid" 2>/dev/null || true)
  [ -n "$coord" ] && [ -n "$notif" ] && [ -n "$lock_holder" ] \
    || { stop_bg "$session"; fail "session did not record coordinator, notifier, and watch-lock holder pids"; }

  i=0
  while [ "$i" -lt 250 ] && kill -0 "$coord" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$coord" 2>/dev/null; then
    stop_bg "$session"
    fail "coordinator did not stand down after a bounded successor-timeout streak"
  fi
  wait "$coord" 2>/dev/null || true
  [ ! -e "$dir/state/.claude-coordinator.lock" ] \
    || { stop_bg "$session"; fail "coordinator stood down but left .claude-coordinator.lock behind"; }
  [ ! -e "$dir/state/.claude-coordinator-generation" ] \
    || { stop_bg "$session"; fail "coordinator stood down but left its generation file behind"; }
  [ ! -e "$dir/state/.claude-ready-to-notify" ] \
    || { stop_bg "$session"; fail "a failing-arm coordinator published a ready record"; }
  [ "$(watch_pid "$dir")" = "$lock_holder" ] \
    || { stop_bg "$session"; fail "a failing-arm cycle took the watch lock"; }

  i=0
  while [ "$i" -lt 120 ] && kill -0 "$notif" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$notif" 2>/dev/null; then
    stop_bg "$session"
    fail "parked notifier never surfaced a coordinator-absent failure after stand-down"
  fi
  wait_file "$dir/state/notif.rc" 50 \
    || { stop_bg "$session"; fail "session never recorded the parked notifier exit code"; }
  expect_code 2 "$(cat "$dir/state/notif.rc")" "the parked notifier must exit 2 with a typed coordinator-absent failure"
  assert_contains "$(cat "$dir/notif.err")" "supervision DEGRADED" "stand-down must surface the typed degraded-supervision failure"
  [ "$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$dir/state/.claude-autoarm-epoch" 2>/dev/null || true)" = failed ] \
    || { stop_bg "$session"; fail "coordinator-absent notifier failure must record outcome=failed"; }
  [ -e "$dir/state/.claude-autoarm-failure-notified" ] \
    || { stop_bg "$session"; fail "coordinator-absent notifier failure must write the guard's episode notice"; }

  # A consecutive coordinator-absent firing records failed-suppressed. The first
  # failed epoch owns its automatic handoff; the later one is what must make an
  # idle Stop consume the guard's block instead of going idle unsupervised.
  # shellcheck disable=SC2046
  printf '%s\n' '{"session_id":"standdown"}' | env $(home_env "$dir") PATH="$dir/fakebin:$PATH" \
    FM_NOTIFIER="$NOTIFIER" FM_CLAUDE_NOTIFIER_COORD_WAIT=1 FM_CLAUDE_NOTIFIER_PARK_POLL=0.2 \
    "$dir/fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      bash "$FM_NOTIFIER"
    ' >"$dir/n2.out" 2>"$dir/n2.err" &
  n2=$!
  i=0
  while [ "$i" -lt 80 ] && kill -0 "$n2" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$n2" 2>/dev/null; then
    stop_bg "$n2" "$session"
    fail "second notifier firing stayed parked after coordinator stand-down"
  fi
  wait "$n2" 2>/dev/null || true

  gout=$(printf '%s\n' '{"session_id":"standdown","stop_hook_active":false}' \
    | env FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
        PATH="$dir/fakebin:$PATH" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=300 \
        "$dir/fakebin/claude" -c '"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude' 2>&1)
  grc=$?
  expect_code 2 "$grc" "after coordinator stand-down the turn-end guard must block an idle Stop"
  assert_contains "$gout" "SUPERVISION IS OFF" "the blocked idle Stop must carry the off-supervision banner"

  stop_bg "$session"
  pass "coordinator: stands down after a bounded successor-timeout streak so the guard blocks an idle Stop"
}

test_successor_verified_before_ready_publish
test_live_watcher_across_long_turn
test_actionable_close_rearms_and_republishes
test_notifier_parks_then_exits_two_on_ready
test_duplicate_rows_one_handling_event
test_single_coordinator_owner
test_coordinator_lock_does_not_satisfy_guard
test_coordinator_stands_down_on_session_handover
test_coordinator_stands_down_after_successor_timeout_streak
