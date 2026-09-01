#!/usr/bin/env bash
# Claude persistent watcher coordinator (async Stop hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "async": true and an explicit multi-hour timeout, alongside the turn-end guard
# and the parked notifier (bin/fm-claude-watch-notifier.sh). Claude Code fires it
# in the background on every Stop of a Claude primary session, each async firing
# its own process inside Claude's own hook process group. It gives Claude the
# same successor-first supervision ordering Pi and OpenCode already have
# (docs/watcher-continuity.md): a live watcher cycle is always present, and a
# verified successor is armed and confirmed IMMEDIATELY after each actionable
# close - before the handling turn, not at its next Stop.
#
# Why a coordinator exists at all: Claude's former between-turns watcher was one-shot. It
# ran between turns, delivered one actionable wake, and exited clean; the auto-arm
# armed the successor only at the NEXT Stop. During any handling turn longer than
# the beacon grace (default 300s) there was then no live watcher, so the beacon
# went stale and the fleet was genuinely unsupervised even though nothing had
# crashed. This hook closes that gap by keeping one arm/watcher cycle alive
# continuously and arming a verified successor the instant a cycle closes
# actionable, so a live watcher owns state/.watch.lock with a fresh beacon
# throughout the handling turn.
#
# The coordinator NEVER exits 2 to wake Claude and NEVER carries notification
# authority. Waking the idle session is the parked notifier's job. The
# coordinator only keeps supervision alive and publishes a ready-to-notify record
# after it has verified the successor; the notifier consumes that record and
# exits 2. This split is deliberate: a single async hook cannot both keep a
# watcher child alive AND exit 2, because exiting reaps the child.
#
# How a successor is armed and verified: the coordinator runs bin/fm-watch-arm.sh
# as a tracked background child (its own child, reaped with this hook by Claude's
# process-group teardown - never a fire-and-forget shell & inside another call).
# The arm blocks until its cycle closes, but as soon as it has confirmed a live
# watcher owns the lock with a fresh beacon it prints
# "watcher: started pid=<N> (beacon fresh)" (or "attached pid=<N>") to its output
# while still blocking. The coordinator reads that line as the successor-readiness
# signal - the same signal the OpenCode adapter uses. It publishes the ready
# record only after the readiness line proves the successor is live, then waits on
# the arm. When the arm closes actionable, that closed cycle's wake is already in
# the durable queue; the coordinator arms the next successor before the notifier
# surfaces anything, so the fleet is never blind. A confirmed successor resets the
# readiness-timeout streak; after FM_CLAUDE_COORD_SUCCESSOR_TIMEOUT_STREAK
# consecutive timeouts with no healthy watcher (default 3), this hook releases its
# lock, removes its generation file, and exits so the notifier's coordinator-absent
# failure can run.
#
# Scope, identity, AFK, need, and stale-session-lock recovery gates are identical
# to the notifier and the turn-end guard, so an idle, away, child, or foreign-host
# checkout stays byte-for-byte inert. Singleton: state/.claude-coordinator.lock,
# role "coordinator", holding a per-session COORDINATOR GENERATION token. A second
# async firing that finds a live role-matched owner exits 0, so there is one
# coordinator per session generation.
#
# A coordinator lock NEVER satisfies the turn-end guard. The guard's proof stays
# bound to a live exit-2 notifier and a PID-strict healthy watcher. A live
# coordinator that is stuck before watcher readiness, or a stale/wedged
# coordinator lock, must NOT let a Stop pass; coordinator state is diagnostic
# evidence, not notification ownership (docs/watcher-continuity.md,
# docs/turnend-guard.md).
#
# HUP/INT/TERM traps kill the arm child, append an "interrupted" lifecycle record,
# and clean this hook's own temp files before cleanup. SIGKILL stays unreportable;
# the notifier's hook timeout is the backstop for it. This hook never writes
# stdout: exit 0 is always silent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
COORD_LOCK="$STATE/.claude-coordinator.lock"
# The parked notifier holds this lock the whole time it is parked
# (bin/fm-claude-watch-notifier.sh acquires it and tags it role "notifier"), and
# records what it is doing in the epoch ledger beside it. Together they say
# whether a notifier exists to consume the ready record. READ ONLY: the
# coordinator never acquires, writes to, or releases either - they belong to the
# notifier. The lock is named differently from the notifier's own OWNER_LOCK so a
# stray reference cannot crash the notifier under set -u.
NOTIFIER_LOCK="$STATE/.claude-autoarm.lock"
NOTIFIER_EPOCH="$STATE/.claude-autoarm-epoch"
NOTIFIER_ABSENT="$STATE/.claude-notifier-absent"
READY="$STATE/.claude-ready-to-notify"
GEN_FILE="$STATE/.claude-coordinator-generation"
WAKE_SEQ="$STATE/.wake-queue.seq"
RECOVERY_MARKER="$STATE/.watcher-down"
WATCH="$SCRIPT_DIR/fm-watch.sh"
# How long to wait for a freshly armed successor to print its readiness line
# before treating the cycle as a readiness failure. The arm layer runs its own
# bounded confirmation; this is the coordinator's outer bound so a hung arm cannot
# pin the loop, and it must exceed the arm's own confirmation budget with margin.
READY_TIMEOUT=${FM_CLAUDE_COORD_READY_TIMEOUT:-30}
case "$READY_TIMEOUT" in ''|*[!0-9]*|0) READY_TIMEOUT=30 ;; esac
# Consecutive successor-timeouts with no healthy watcher before this coordinator
# stands down so a live-but-failing owner cannot park the notifier forever.
SUCCESSOR_TIMEOUT_LIMIT=${FM_CLAUDE_COORD_SUCCESSOR_TIMEOUT_STREAK:-3}
case "$SUCCESSOR_TIMEOUT_LIMIT" in ''|*[!0-9]*|0) SUCCESSOR_TIMEOUT_LIMIT=3 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

# Consume the Stop payload once so a slow writer never wedges on a full pipe, and
# inspect its host before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too and has no async hook surface. A
# Cursor-delivered payload would run this coordinator SYNCHRONOUSLY inside
# Cursor's stop step and hold that turn open for the declared multi-hour timeout -
# the exact wedge the auto-arm guards against. Cursor's own park adapter owns its
# turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may coordinate -----------
# A prior session may have died leaving its numeric harness pid in .lock. Use the
# shared liveness predicate to recognize only that stale-owner case, and defer the
# mutating claim until after the AFK and need gates so an idle or away home stays
# inert. Missing or malformed locks are uncertainty, not stale-owner evidence.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage ------------------------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work, a registered event source, or an X-mode relay poll -
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- singleton coordinator claim ---------------------------------------------
# Exactly one coordinator per session generation. Every other concurrent firing
# exits 0, so there is never a second driver of the arm layer.
fm_lock_try_acquire "$COORD_LOCK" || exit 0
if ! fm_lock_set_role "$COORD_LOCK" coordinator; then
  fm_lock_release "$COORD_LOCK"
  exit 0
fi

# This session generation's owner pid: the session-lock owner the coordinator
# started under, so the notifier can reject a ready record left by a stale
# coordinator from a previous session generation. Re-assert self-ownership after
# capturing it, so a handover that changed state/.lock between the identity gate
# above and this read (a new session taking over during startup) is caught here
# rather than adopted as this coordinator's own owner.
SESSION_OWNER=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$SESSION_OWNER" in
  ''|*[!0-9]*) fm_lock_release "$COORD_LOCK"; exit 0 ;;
esac
fm_session_lock_owned_by_self "$STATE" || { fm_lock_release "$COORD_LOCK"; exit 0; }
COORD_GENERATION="coord-${SESSION_OWNER}-${BASHPID:-$$}"
printf '%s\n' "$COORD_GENERATION" > "$GEN_FILE" 2>/dev/null || true

# The arm child pid and its output file this coordinator currently owns, so the
# signal traps can reap the child and clean the abandoned file.
ARM_CHILD=
OUT=

cycle_ledger_note() {  # <cause>
  # A best-effort coordinator lifecycle breadcrumb; the arm layer owns the
  # authoritative per-cycle ledger. This only records coordinator-level events the
  # arm rows cannot carry.
  local cause=$1 log="$STATE/.watch-cycle-exits.log"
  printf 'coordinator_event\tcause=%s\tgeneration=%s\tsession=%s\tat=%s\n' \
    "$cause" "$COORD_GENERATION" "$SESSION_OWNER" "$(date +%s)" >> "$log" 2>/dev/null || true
}

reap_arm() {
  if [ -n "$ARM_CHILD" ] && fm_pid_alive "$ARM_CHILD"; then
    kill -TERM "$ARM_CHILD" 2>/dev/null || true
    wait "$ARM_CHILD" 2>/dev/null || true
  fi
  ARM_CHILD=
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_parent_signal() {
  local signal=$1
  trap - HUP INT TERM
  cycle_ledger_note interrupted
  reap_arm
  trap - EXIT
  rm -f "$GEN_FILE" 2>/dev/null || true
  fm_lock_release "$COORD_LOCK" 2>/dev/null || true
  kill -s "$signal" "$$" 2>/dev/null || true
  exit $((128 + $(kill -l "$signal" 2>/dev/null || echo 15)))
}
cleanup_exit() {
  reap_arm
  rm -f "$GEN_FILE" 2>/dev/null || true
  fm_lock_release "$COORD_LOCK" 2>/dev/null || true
}
trap cleanup_exit EXIT
trap 'handle_parent_signal HUP' HUP
trap 'handle_parent_signal INT' INT
trap 'handle_parent_signal TERM' TERM

# X mode cadence: source the generated config so an X instance's arm polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

wake_seq_value() {
  local seq
  seq=$(cat "$WAKE_SEQ" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$seq" ;;
  esac
}

recovery_generation_value() {
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" 2>/dev/null || { printf 'none'; return; }
  case "$FM_RECOVERY_MARKER_TOKEN" in
    ''|acked:*) printf 'none' ;;
    *) printf '%s' "${FM_RECOVERY_MARKER_TOKEN##*:}" ;;
  esac
}

# Read the readiness line the arm prints while it is still blocking. It signals a
# live watcher owns the lock with a fresh beacon. Returns 0 with SUCCESSOR_PID and
# SUCCESSOR_IDENTITY set once the line appears, 1 on timeout or a failed arm.
SUCCESSOR_PID=
SUCCESSOR_IDENTITY=
wait_for_successor_ready() {
  local out=$1 deadline line
  SUCCESSOR_PID=
  SUCCESSOR_IDENTITY=
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  while :; do
    # started/attached lines carry the live successor pid; FAILED means give up.
    line=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null | head -1 || true)
    if [ -n "$line" ]; then
      SUCCESSOR_PID=$(printf '%s' "$line" | sed -n 's/^watcher: [a-z]* pid=\([0-9][0-9]*\).*/\1/p')
      # Confirm the successor is genuinely healthy right now, so a stale printed
      # line can never stand in for a live watcher.
      if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" \
        && [ "$FM_WATCHER_HEALTHY_PID" = "$SUCCESSOR_PID" ]; then
        SUCCESSOR_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
        return 0
      fi
    fi
    grep -q '^watcher: FAILED' "$out" 2>/dev/null && return 1
    # A session handover or AFK during the readiness wait ends this cycle: return
    # readiness failure so the loop's gate catches the handover and stands down
    # promptly, rather than blocking here for the whole readiness timeout.
    { [ -e "$STATE/.afk" ] || ! session_still_owns; } && return 1
    # The arm may have exited before we saw a line at all.
    fm_pid_alive "$ARM_CHILD" || {
      # One last look after close in case the line and exit crossed.
      line=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null | head -1 || true)
      [ -n "$line" ] && fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && {
        SUCCESSOR_PID=$FM_WATCHER_HEALTHY_PID
        SUCCESSOR_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
        return 0
      }
      return 1
    }
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# Publish the ready-to-notify ledger atomically, AFTER a successor is verified.
# The notifier consumes it by ready_seq high-water mark, never by counting queue
# rows. Binds every identity the successor-first ordering requires.
publish_ready() {  # <ready_seq> <predecessor_arm_pid>
  local ready_seq=$1 predecessor_arm_pid=$2 tmp recovery_gen
  recovery_gen=$(recovery_generation_value)
  tmp="$READY.tmp.$$"
  {
    printf 'ready_seq=%s\n' "$ready_seq"
    printf 'recovery_generation=%s\n' "$recovery_gen"
    printf 'predecessor_arm_pid=%s\n' "$predecessor_arm_pid"
    printf 'successor_watch_pid=%s\n' "$SUCCESSOR_PID"
    printf 'successor_watch_identity=%s\n' "$SUCCESSOR_IDENTITY"
    printf 'coordinator_generation=%s\n' "$COORD_GENERATION"
    printf 'session_owner=%s\n' "$SESSION_OWNER"
    printf 'published_at=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$READY" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# Record when the notifier has silently died, so a coordinator publishing into
# the void leaves a durable trace instead of going half-dead in silence. Called
# after every successful publish_ready. READ ONLY against the notifier lock and
# the epoch ledger: this never acquires, writes, or releases either.
#
# The signal is the notifier's own recorded belief plus its liveness, not lock
# presence. The notifier is a Stop hook: it exits 2 to deliver each wake and its
# EXIT trap drops the lock, and no replacement parks until the next Stop. So an
# empty lock during a handling turn is normal and healthy, and treating it as an
# outage would write the false marker this check exists to avoid.
#
# Fail-open bias: only a notifier that recorded "parked" and then died without
# releasing its lock is provably gone. Anything uncertain writes nothing.
record_notifier_presence() {  # <ready_seq>
  local ready_seq=$1 tmp now first_seen holder_pid holder_role epoch_outcome epoch_owner
  holder_pid=$(cat "$NOTIFIER_LOCK/pid" 2>/dev/null || true)
  holder_role=$(cat "$NOTIFIER_LOCK/role" 2>/dev/null || true)
  # A live holder only counts as a parked notifier when the lock says so. The
  # turn-end guard takes this same lock with role "terminal-check", and that
  # holder must not be mistaken for a notifier.
  if [ -n "$holder_pid" ] && fm_pid_alive "$holder_pid"; then
    case "$holder_role" in
      notifier|autoarm)
        rm -f "$NOTIFIER_ABSENT" 2>/dev/null || true
        return
        ;;
    esac
  fi
  # No parked notifier holds the lock. Ask the epoch ledger what the last
  # notifier believed it was doing, and whether that process still exists.
  epoch_outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\).*$/\1/p' "$NOTIFIER_EPOCH" 2>/dev/null | head -1)
  epoch_owner=$(sed -n 's/^.*owner_pid=\([0-9][0-9]*\).*$/\1/p' "$NOTIFIER_EPOCH" 2>/dev/null | head -1)
  # Only "parked" plus a dead owner proves a silent death. A missing or malformed
  # ledger, a stand-down outcome, a rewake, a failure the turn-end guard already
  # owns, or a parked owner still alive are all left unmarked.
  if [ "$epoch_outcome" != parked ] || fm_pid_alive "$epoch_owner"; then
    rm -f "$NOTIFIER_ABSENT" 2>/dev/null || true
    return
  fi
  now=$(date +%s)
  # Preserve first_seen across rewrites so a one-cycle blip is distinguishable from
  # a real outage. A missing or malformed existing marker starts a fresh outage.
  first_seen=$(sed -n 's/^first_seen=//p' "$NOTIFIER_ABSENT" 2>/dev/null | head -1)
  case "$first_seen" in ''|*[!0-9]*) first_seen=$now ;; esac
  tmp="$NOTIFIER_ABSENT.tmp.$$"
  if {
    printf 'first_seen=%s\n' "$first_seen"
    printf 'last_seen=%s\n' "$now"
    printf 'ready_seq=%s\n' "$ready_seq"
    printf 'coordinator_generation=%s\n' "$COORD_GENERATION"
    printf 'session_owner=%s\n' "$SESSION_OWNER"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$NOTIFIER_ABSENT" 2>/dev/null; then
    # Only breadcrumb an absence the marker actually records, so an operator
    # following the ledger never hunts for a marker that was never written.
    cycle_ledger_note notifier-absent
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# Stand down when this session no longer owns state/.lock: a new session
# generation has taken over and owns its own coordinator.
session_still_owns() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null || true)
  [ "$owner" = "$SESSION_OWNER" ]
}

# Spawn one arm cycle as a tracked background child. It attaches to a live
# successor or starts a fresh watcher, prints its readiness line while blocking,
# and closes when the cycle ends. FM_WATCH_ARM_SOURCE=autoarm marks its ledger
# rows; FM_WATCH_PREDECESSOR_ARM_PID links the predecessor's successor field.
spawn_arm() {  # <predecessor_arm_pid>
  local predecessor=$1
  OUT=$(mktemp "$STATE/.claude-coordinator-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    FM_WATCH_ARM_SOURCE=autoarm FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
      "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 &
  else
    FM_WATCH_ARM_SOURCE=autoarm FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
      "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_CHILD=$!
}

# --- the coordinator loop -----------------------------------------------------
# Keep exactly one arm/watcher cycle alive. Each turn: spawn the arm as a tracked
# child, wait for its readiness line to confirm a live successor, publish the
# ready record keyed to the queue high-water mark, then wait on the arm. When it
# closes actionable, the closed cycle's wake is already durable and a fresh
# successor was armed before the notifier surfaces it. Re-check need, AFK, and
# session ownership every turn.
PREDECESSOR_ARM_PID=none
SUCCESSOR_TIMEOUT_STREAK=0
while :; do
  [ -e "$STATE/.afk" ] && { cycle_ledger_note afk; exit 0; }
  need_supervision || { cycle_ledger_note idle; exit 0; }
  session_still_owns || { cycle_ledger_note session-handover; exit 0; }

  spawn_arm "$PREDECESSOR_ARM_PID"

  # Successor-first: the queue high-water mark bounds what this cycle may deliver.
  # Captured before waiting so a wake appended during the cycle keeps a higher seq
  # and is not prematurely marked notifiable.
  READY_SEQ=$(wake_seq_value)
  if wait_for_successor_ready "$OUT"; then
    SUCCESSOR_TIMEOUT_STREAK=0
    publish_ready "$READY_SEQ" "$PREDECESSOR_ARM_PID"
    record_notifier_presence "$READY_SEQ"
    cycle_ledger_note successor-ready
  else
    # Readiness failed or the arm died before confirming a live watcher. Leave no
    # false ready record. After a bounded streak of consecutive timeouts with no
    # healthy watcher, stand down so the notifier's coordinator-absent path runs.
    cycle_ledger_note successor-timeout
    reap_arm
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      SUCCESSOR_TIMEOUT_STREAK=0
    else
      SUCCESSOR_TIMEOUT_STREAK=$((SUCCESSOR_TIMEOUT_STREAK + 1))
      if [ "$SUCCESSOR_TIMEOUT_STREAK" -ge "$SUCCESSOR_TIMEOUT_LIMIT" ]; then
        cycle_ledger_note successor-timeout-exhausted
        exit 0
      fi
    fi
    # Brief backoff so a persistently failing arm cannot spin the loop hot.
    sleep 1
    continue
  fi

  # Wait for this cycle to close, but stay responsive to a session handover, AFK,
  # or a fleet that went idle while the arm blocks quietly - a quiet fleet can
  # block the arm indefinitely, so a plain wait would never notice a new session
  # taking over. Poll the arm and the gates together: when the arm closes, loop on
  # to arm the successor; when a gate flips, reap the arm and stand down.
  handed_off=0
  while fm_pid_alive "$ARM_CHILD"; do
    if [ -e "$STATE/.afk" ]; then cycle_ledger_note afk; handed_off=1; break; fi
    if ! session_still_owns; then cycle_ledger_note session-handover; handed_off=1; break; fi
    if ! need_supervision; then cycle_ledger_note idle; handed_off=1; break; fi
    sleep 0.5
  done
  if [ "$handed_off" -eq 1 ]; then
    reap_arm
    exit 0
  fi
  # The arm closed on its own: reap its status and record the predecessor so the
  # next cycle's ledger row links back.
  wait "$ARM_CHILD" 2>/dev/null || true
  PREDECESSOR_ARM_PID=$ARM_CHILD
  ARM_CHILD=
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done
