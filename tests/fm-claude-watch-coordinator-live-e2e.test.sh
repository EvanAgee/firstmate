#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the two cooperating Stop hooks
# (bin/fm-claude-watch-coordinator.sh + bin/fm-claude-watch-notifier.sh +
# bin/fm-turnend-guard.sh --claude).
#
# This is the only test that can falsify the design's core assumption: that two
# parallel Claude Stop hooks - a persistent `async` coordinator and a parked
# `asyncRewake` notifier - behave as Anthropic's hook reference states, survive
# and cooperate across a real idle wake, an active handling turn longer than the
# beacon grace, and session teardown. A fork+setpgrp smoke test is NOT a
# substitute. It proves, against the real installed Claude Code and the real
# tracked hook registration:
#   - a fresh session with in-flight work, no watcher, and a stale session lock
#     runs bin/fm-session-start.sh first and session start reclaims the dead owner;
#   - the coordinator keeps a live watcher owning state/.watch.lock with a fresh
#     beacon across a handling turn longer than FM_GUARD_GRACE (the whole point of
#     the coordinator - the former next-Stop design left the beacon stale here);
#   - the parked notifier wakes the idle session on each ready-to-notify event
#     with zero model-issued arm commands;
#   - the cooperative guard never blocks the turn blind while the coordinator's
#     launch is healthy.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude watcher coordinator regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-coordinator-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)
# A short grace so a modest handling turn is genuinely longer than grace without a
# multi-minute live test. The coordinator must keep a live watcher across it.
GRACE=8

cleanup() {
  # Best-effort teardown: reap any coordinator/watcher the session left behind by
  # its own process group when Claude tore the session down.
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the other continuity live E2Es).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart nudge, Stop
# guard, async coordinator, and asyncRewake notifier registration. The only local
# hook records model-issued Bash calls without changing lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
printf 'working: live fixture in flight\n' > "$HOME_DIR/state/task.status"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# The coordinator drives the REAL fm-watch-arm.sh and REAL fm-watch.sh here; no
# arm fixture is installed, because the whole point is to prove the real arm layer
# keeps a live watcher across the turn. The drain fixture ends the in-flight need
# after the model has handled two wakes so a misbehaving session cannot loop.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'signal: fixture drained\n'
SH
chmod +x "$PROJECT/bin/fm-wake-drain.sh"

# A helper the model runs on a Stop-hook-feedback wake turn (after a
# coordinator-verified successor is live) to sample supervision liveness DURING
# a handling turn longer than grace: it sleeps past grace, then records whether a
# live watcher still owns the lock with a fresh beacon. This is the coordinator's
# guarantee that the former next-Stop design could not meet.
cat > "$PROJECT/bin/live-sample.sh" <<SH
#!/usr/bin/env bash
sleep $((GRACE + 4))
pid=\$(cat "\$FM_HOME/state/.watch.lock/pid" 2>/dev/null || true)
alive=no; kill -0 "\$pid" 2>/dev/null && alive=yes
now=\$(date +%s)
# OS-detect the mtime flag: GNU stat treats -f as --file-system and succeeds with
# a non-numeric value, so a -f || -c fallback never reaches the Linux branch.
if [ "\$(uname)" = Darwin ]; then
  m=\$(stat -f %m "\$FM_HOME/state/.last-watcher-beat" 2>/dev/null || echo 0)
else
  m=\$(stat -c %Y "\$FM_HOME/state/.last-watcher-beat" 2>/dev/null || echo 0)
fi
case "\$m" in ''|*[!0-9]*) m=0 ;; esac
age=\$((now - m))
printf 'watcher_alive=%s beacon_age=%s\n' "\$alive" "\$age" > "\$FM_HOME/state/live-sample"
SH
chmod +x "$PROJECT/bin/live-sample.sh"

PROMPT='Run exactly `bin/fm-session-start.sh` with Bash as your first tool call. After reading its complete digest, reply with exactly CYCLE0 and stop. Do not run bin/live-sample.sh on that first turn. Whenever a Stop hook feedback message wakes you: if you have not yet run bin/live-sample.sh this session, run exactly `bin/live-sample.sh` with Bash once (it takes several seconds), then run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. If you have already run bin/live-sample.sh, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh, bin/fm-claude-watch-coordinator.sh, or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_GUARD_GRACE="$GRACE" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed coordinator session failed: $(tail -20 "$TRANSCRIPT")"

# 1. Session start reclaimed the stale dead-owner lock and ran first.
[ "$(sed -n '1p' "$HOME_DIR/state/tool-calls.log" 2>/dev/null)" = 'bin/fm-session-start.sh' ] \
  || fail "fresh Claude session did not run session start first: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"

# 2. The coordinator kept a live watcher with a fresh beacon across a turn longer
#    than grace - the core repair. The sample ran on a Stop-hook-feedback wake
#    turn after a coordinator-verified successor was already live.
[ -f "$HOME_DIR/state/live-sample" ] || fail "the post-wake liveness sample never ran"
SAMPLE=$(cat "$HOME_DIR/state/live-sample")
case "$SAMPLE" in
  *watcher_alive=yes*) : ;;
  *) fail "no live watcher owned the lock during a handling turn longer than grace: $SAMPLE" ;;
esac
SAMPLE_AGE=$(printf '%s' "$SAMPLE" | sed -n 's/.*beacon_age=\([0-9][0-9]*\).*/\1/p')
[ -n "$SAMPLE_AGE" ] && [ "$SAMPLE_AGE" -lt "$GRACE" ] \
  || fail "the beacon went stale (${SAMPLE_AGE}s >= ${GRACE}s grace) during the handling turn: $SAMPLE"

# 3. The parked notifier woke the idle session on ready events, and the model
#    handled them by draining, with zero model-issued arm commands.
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "${DRAIN_RUNS:-0}" -ge 2 ] || fail "expected at least two model wake drains, got ${DRAIN_RUNS:-0}"
REWAKES=$(grep -c 'Stop hook feedback' "$TRANSCRIPT" 2>/dev/null || true)
[ "$REWAKES" -ge 1 ] || fail "expected at least one exit-2 rewake delivery, got $REWAKES"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q 'fm-claude-watch-coordinator.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model launched the coordinator by hand despite Stop-owned continuity"
  ! grep -qE ' &($|[^&])' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi

# 4. The cooperative guard never blocked the turn blind while supervision was healthy.
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard blocked a turn blind while the coordinator launch was healthy"

# 5. The notifier's epoch ledger recorded a rewake outcome and released its lock.
[ "$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "notifier epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "notifier owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a second
# isolated home while a coordinator hook fires from the same primary project. The
# competing coordinator must not replace the session lock or take the coordinator
# lock in the other home.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 30; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-watch-coordinator.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" &
CTRL=$!
# The competing coordinator must exit 0 quickly against a live foreign owner.
i=0
while [ "$i" -lt 60 ] && kill -0 "$CTRL" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$CTRL" 2>/dev/null; then kill "$CTRL" 2>/dev/null; LIVE_OWNER_RC=parked; else wait "$CTRL"; LIVE_OWNER_RC=$?; fi
[ "$LIVE_OWNER_RC" = 0 ] || fail "competing coordinator did not stand down against a live foreign owner (rc=$LIVE_OWNER_RC)"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing coordinator replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-coordinator.lock" ] || fail "competing coordinator took the coordinator lock in a foreign-owned home"
kill "$LIVE_OWNER_PID" 2>/dev/null || true
wait "$LIVE_OWNER_PID" 2>/dev/null || true

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, kept a live watcher across a handling turn longer than grace, woke on notifier ready events with no model arm, and preserved the competing-live-owner boundary\n' "$CLAUDE_VERSION"
