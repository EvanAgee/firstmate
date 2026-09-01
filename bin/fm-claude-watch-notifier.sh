#!/usr/bin/env bash
# Claude Stop-owned watcher wake notifier (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout, alongside the turn-end
# guard and the persistent coordinator (bin/fm-claude-watch-coordinator.sh).
# Claude Code fires it in the background on EVERY Stop of a Claude primary
# session, with no deduplication across firings. It is the exit-2 wake path: the
# hook that STAYS ALIVE between turns and wakes the idle session when a
# supervision event needs a handling turn. The coordinator keeps the watcher
# cycle alive with successor-first ordering and publishes a ready-to-notify
# record after it verifies each successor; this notifier consumes that record and
# exits 2. Splitting the two is deliberate: a single async hook cannot both keep a
# watcher child alive AND exit 2, because exiting reaps the child
# (docs/watcher-continuity.md).
#
# This was the former auto-arm (bin/fm-claude-stop-autoarm.sh). Its scope,
# identity, AFK, need, stale-session-lock recovery, and single-flight gates are
# unchanged, and it keeps the same owner lock (state/.claude-autoarm.lock) so the
# turn-end guard's lock path is undisturbed; only the role string it sets is
# "notifier". What changed is its body: instead of foregrounding the arm and
# translating one close, it PARKS until it can exit 2 on a coordinator-published
# ready record, or surfaces a typed coordinator failure so a handling turn learns
# supervision is degraded.
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     A dead numeric owner is reclaimed through bin/fm-lock.sh, then re-verified.
#     A live owner, missing lock, malformed lock, or unresolved ancestry stays
#     inert, so a competing session never notifies.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (rechecked while parked so a
#     mid-park AFK transition is honored).
#   - Need: notifies only while work is in flight (state/*.meta), a process-event
#     source is registered, or X mode has a relay poll to run
#     (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one parked owner; every
#     other concurrent firing exits 0.
#   - Park-and-notify: the owner PARKS in a bounded wait loop (up to its hook
#     timeout) polling for EITHER a fresh ready-to-notify record whose ready_seq
#     is past this notifier's last-surfaced high-water mark, whose session_owner
#     and coordinator_generation still match this session, AND whose ready_seq
#     covers at least one durable unacked row in state/.wake-queue - on which it
#     prints one rewake banner and exits 2 exactly once per ready event; OR a
#     typed coordinator failure (no coordinator, lost session ownership, no
#     successor readiness within the coordinator's bound), which it surfaces as
#     typed exit-2 feedback so the handling turn learns supervision is degraded. It
#     never exits 0 into a still-needed-but-unsurfaced state, and never opens a
#     handling turn for a high-water mark with nothing actually queued.
#
# On a genuinely absent coordinator it also drives the same failure-episode
# progression the former auto-arm did (failed epoch plus a one-time notice, then
# failed-suppressed), and clears it on positive recovery, so the guard's monotonic
# block budget and one-time attended fail-open still fire instead of the session
# blocking forever (docs/turnend-guard.md).
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns. HUP/INT/TERM traps record an
# "interrupted" outcome when this hook process tree is killed mid-park; the guard
# reads "interrupted" as "this hook does not own recovery" and falls through to a
# proper Stop-owned continuation. SIGKILL stays unreportable.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr. On any
# uncertainty it exits 0 and leaves continuity to the coordinator, the synchronous
# guard, and the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"
READY="$STATE/.claude-ready-to-notify"
COORD_LOCK="$STATE/.claude-coordinator.lock"
SURFACED="$STATE/.claude-notifier-surfaced-seq"
WAKE_SEQ="$STATE/.wake-queue.seq"
# The failure-episode markers the turn-end guard's monotonic progression and
# one-time attended fail-open read (docs/turnend-guard.md). The notifier drives
# them exactly as the former auto-arm did, so a genuinely absent coordinator is
# surfaced once and then reaches the guard's attended fail-open instead of blocking
# the session forever.
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
# How long a parked notifier waits for the coordinator to prove it exists and is
# making progress before surfacing a typed coordinator-absent failure. The
# coordinator publishes a ready record within its own bounded readiness window
# after each actionable close, so a notifier that sees a live coordinator keeps
# parking; only a coordinator that never appears trips this bound.
COORD_WAIT=${FM_CLAUDE_NOTIFIER_COORD_WAIT:-45}
# 0 is a valid "do not wait for the coordinator" value used by tests and by any
# caller that wants an immediate coordinator-absent verdict; only a non-numeric or
# empty value falls back to the default.
case "$COORD_WAIT" in ''|*[!0-9]*) COORD_WAIT=45 ;; esac
# Poll cadence while parked.
PARK_POLL=${FM_CLAUDE_NOTIFIER_PARK_POLL:-0.5}

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

# Consume the Stop payload once so a slow writer can never wedge on a full pipe,
# and inspect its host before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so a
# Cursor-delivered payload would run this notifier SYNCHRONOUSLY inside Cursor's
# stop step and hold that turn open for the declared multi-hour timeout - the
# exact wedge grok 1.0.0 produced. Cursor's own park adapter owns its turn
# boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may notify ---------------
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
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

# --- single-flight owner claim -----------------------------------------------
# Exactly one parked owner per home; every other concurrent firing exits 0 so one
# ready event yields at most one exit-2 rewake.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
if ! fm_lock_set_role "$OWNER_LOCK" notifier; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi

SESSION_OWNER=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$SESSION_OWNER" in
  ''|*[!0-9]*) fm_lock_release "$OWNER_LOCK"; exit 0 ;;
esac
fm_session_lock_owned_by_self "$STATE" || { fm_lock_release "$OWNER_LOCK"; exit 0; }

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# When Claude kills this hook process tree mid-park (session teardown, hook
# timeout, or an operator interrupt), record an "interrupted" epoch outcome so the
# ledger does not leave a dangling "parked" epoch. The turn-end guard reads
# "interrupted" as "the notifier does not own recovery", forcing a proper
# Stop-owned continuation. SIGKILL stays unreportable. The EXIT trap still
# releases the owner lock; a signal handler re-raises the default so EXIT runs and
# the exit status carries the signal.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_parent_signal() {
  local signal=$1
  trap - HUP INT TERM
  write_epoch interrupted
  trap - EXIT
  fm_lock_release "$OWNER_LOCK" 2>/dev/null || true
  kill -s "$signal" "$$" 2>/dev/null || true
  exit $((128 + $(kill -l "$signal" 2>/dev/null || echo 15)))
}
trap 'fm_lock_release "$OWNER_LOCK"' EXIT
trap 'handle_parent_signal HUP' HUP
trap 'handle_parent_signal INT' INT
trap 'handle_parent_signal TERM' TERM

write_epoch parked

# X mode cadence: source the generated config so a parked notifier honors an X
# instance's cadence expectations for any timing it derives.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

ready_field() {  # <field>
  sed -n "s/^$1=\\(.*\\)/\\1/p" "$READY" 2>/dev/null | head -1
}

queue_highwater() {
  local v
  v=$(cat "$WAKE_SEQ" 2>/dev/null || echo 0)
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

surfaced_seq() {
  local v
  v=$(cat "$SURFACED" 2>/dev/null || echo 0)
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# True when the durable queue still holds an unacked row whose sequence is at or
# below <ready_seq>. A leftover .wake-queue.seq high-water mark with no such row
# is not a supervision event. The coordinator asks the same question when it
# decides whether an unconsumed ready record means wakes are piling up, so the
# test lives once in bin/fm-wake-lib.sh.
has_unacked_wake_at_or_below() {  # <ready_seq>
  fm_wake_has_unacked_at_or_below "$1"
}

advance_surfaced() {  # <seq>
  local seq=$1 tmp
  tmp="$SURFACED.tmp.$$"
  printf '%s\n' "$seq" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SURFACED" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# A live coordinator for THIS session owns the coordinator lock with role
# "coordinator". Its presence keeps the notifier parking; its absence past the
# bounded wait is the coordinator-absent failure.
coordinator_alive() {
  local pid role
  pid=$(cat "$COORD_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$COORD_LOCK" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  [ "$role" = coordinator ] || return 1
  # A live coordinator lock is trusted here; the per-ready session and generation
  # match in ready_pending is what gates an actual notification.
  return 0
}

# A fresh ready record for THIS session that we have not surfaced yet, covering
# at least one durable unacked wake. Sets READY_SEQ on success.
READY_SEQ=
ready_pending() {
  local rs ro rg current_owner hw
  READY_SEQ=
  [ -f "$READY" ] || return 1
  rs=$(ready_field ready_seq)
  case "$rs" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # The record must belong to this exact session generation, so a stale record
  # left by a previous session's coordinator is never surfaced.
  ro=$(ready_field session_owner)
  current_owner=$(cat "$STATE/.lock" 2>/dev/null || true)
  [ -n "$ro" ] && [ "$ro" = "$current_owner" ] || return 1
  rg=$(ready_field coordinator_generation)
  case "$rg" in
    coord-*) : ;;
    *) return 1 ;;
  esac
  if [ ! -f "$SURFACED" ]; then
    hw=$(queue_highwater)
    if ! has_unacked_wake_at_or_below "$hw"; then
      advance_surfaced "$hw"
    fi
  fi
  [ "$rs" -gt "$(surfaced_seq)" ] || return 1
  has_unacked_wake_at_or_below "$rs" || return 1
  READY_SEQ=$rs
  return 0
}

emit_rewake_banner() {
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. The watcher coordinator owns continuity: a verified successor is already supervising the fleet - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
}

emit_coordinator_failure() {  # <detail>
  local detail=$1
  {
    printf 'firstmate watcher supervision DEGRADED - %s.\n' "$detail"
    printf 'The persistent watcher coordinator did not confirm a live successor for this home. Investigate the automatic Stop coordinator and watcher startup; do not launch a manual background arm from this notice before checking why the coordinator is not supervising.\n'
  } >&2
}

# --- park until a ready event, a coordinator failure, or a benign exit --------
# The loop runs until the hook timeout. It exits 2 exactly once per ready event,
# exits 2 with a typed failure if the coordinator never proves itself, and exits 0
# cleanly when need clears or AFK takes over.
coord_deadline=$(( $(date +%s) + COORD_WAIT ))
coord_ever_seen=0
while :; do
  # AFK or need may change while parked.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    exit 0
  fi
  if ! need_supervision; then
    write_epoch clean
    exit 0
  fi
  # A new session generation taking over ends this notifier's authority.
  current_owner=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ -n "$SESSION_OWNER" ] && [ "$current_owner" != "$SESSION_OWNER" ]; then
    write_epoch session-handover
    exit 0
  fi

  # A live watcher may make this home healthy independently (e.g. a manual arm);
  # nothing to notify, so keep parking for a ready record. A healthy watcher is
  # positive recovery: clear any failure episode so a later genuine failure starts
  # a fresh bounded progression, matching the guard's fm_failure_episode_reset
  # contract. Deliberately do NOT push coord_deadline forward here: only a live
  # coordinator resets the coordinator-absent clock. A healthy watcher with no
  # coordinator must still reach the bound below and exit 0 rather than park until
  # the hook timeout.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    fm_failure_episode_reset "$STATE" || true
  fi

  if ready_pending; then
    advance_surfaced "$READY_SEQ"
    # A ready record means the coordinator verified a live successor: this is
    # positive recovery, so clear any failure episode before surfacing the wake.
    fm_failure_episode_reset "$STATE" || true
    write_epoch rewake
    emit_rewake_banner
    exit 2
  fi

  if coordinator_alive; then
    coord_ever_seen=1
    coord_deadline=$(( $(date +%s) + COORD_WAIT ))
  elif [ "$(date +%s)" -ge "$coord_deadline" ]; then
    # The coordinator did not appear within the bound. If a watcher is already
    # healthy, supervision is genuinely present without the coordinator (positive
    # recovery, or a manual arm): exit 0 silently, since there is nothing to notify
    # and no coordinator to wait for. This matches the former auto-arm's
    # healthy-watcher exit and lets the loop terminate instead of parking forever.
    if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
      write_epoch clean
      exit 0
    else
      # Drive the same failure-episode contract the turn-end guard's monotonic
      # progression and one-time attended fail-open read (docs/turnend-guard.md):
      # once the guard has consumed the episode's attended fail-open (FAILURE_ALARM
      # present), stop creating exit-2 continuations that could defeat it - exit 0
      # silently. Before that, the first unexhausted failure records the notice once
      # and every consecutive one keeps forcing a Stop-owned retry (exit 2) without
      # repeating the operator notice.
      if [ -e "$FAILURE_ALARM" ]; then
        write_epoch failed-suppressed
        exit 0
      fi
      if [ ! -e "$FAILURE_NOTICE" ]; then
        write_epoch failed
        if [ "$coord_ever_seen" -eq 1 ]; then
          emit_coordinator_failure "the coordinator stopped confirming a live successor"
        else
          emit_coordinator_failure "no watcher coordinator claimed this home"
        fi
        : > "$FAILURE_NOTICE" 2>/dev/null || true
        exit 2
      fi
      write_epoch failed-suppressed
      exit 2
    fi
  fi

  sleep "$PARK_POLL"
done
