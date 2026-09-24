#!/usr/bin/env bash
# Opt-in live guard for cross-home session messaging through the primary-home
# delegation guard (docs/subagent-guard.md "Cross-home session messaging").
#
# The guard lets SendMessage through only when its target names a live Claude
# Code session whose recorded cwd is a firstmate primary home. Two facts behind
# that come from the vendor, so a fixture can only restate them:
#
#   (a) Claude Code records each live local session as
#       <config dir>/sessions/<pid>.json with the name ListAgents prints, its
#       pid, and its cwd, and
#   (b) a SendMessage the guard allows is actually delivered into that session.
#
# tests/fm-subagent-pretool-check.test.sh pins the classifier portably with
# fixture records. This guard covers what CI cannot see: it builds two scratch
# primary homes carrying the tracked match-all guard entry, starts home B's
# Claude session interactively in a private tmux server, and has home A list
# sessions, message B, message `main`, and try `Agent`.
#
#   FM_SUBAGENT_MESSAGING_LIVE_E2E=1 tests/fm-subagent-messaging-live-e2e.test.sh
#
# It costs real model turns. Run it after every Claude Code upgrade.
set -u

if [ "${FM_SUBAGENT_MESSAGING_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SUBAGENT_MESSAGING_LIVE_E2E=1 to run the live cross-home messaging regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s (claude %s)\n' "$1" "${CLAUDE_VERSION:-absent}" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

CLAUDE_BIN=$(command -v claude) || fail "claude is not installed, so this guard checked nothing"
command -v tmux >/dev/null 2>&1 || fail "tmux not found; home B runs as a real interactive session"
command -v jq >/dev/null 2>&1 || fail "jq not found; the guard and this test both read JSON"
CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1)
SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"

# Outside the repo on purpose: each home is its own git repo, and nesting one in
# the checkout would show up as an embedded repository.
LAB=$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-subagent-messaging-live.$$
SOCKET="fm-msg-live-$$"
TOKEN="fm-messaging-live-$$-$(date +%s)"

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

# A clean environment, so neither home inherits the calling session's
# CLAUDE_CODE_* messaging identity or a firstmate FM_HOME.
clean_env() {
  env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" \
    ${CLAUDE_CONFIG_DIR:+CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"} CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false "$@"
}

build_home() {
  local home="$LAB/$1"
  mkdir -p "$home/bin" "$home/state" "$home/.claude"
  cp "$ROOT/bin/fm-subagent-pretool-check.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$home/bin/"
  printf '# scratch firstmate home for the cross-home messaging live guard\n' > "$home/AGENTS.md"
  jq '{hooks: {PreToolUse: [.hooks.PreToolUse[] | select(.matcher == ".*")]}}' \
    "$ROOT/.claude/settings.json" > "$home/.claude/settings.json"
  jq -e '.hooks.PreToolUse | length == 1' "$home/.claude/settings.json" >/dev/null \
    || fail "the tracked settings no longer carry exactly one match-all PreToolUse entry"
  git -C "$home" init -q
}

capture_b() { tmux -L "$SOCKET" capture-pane -p -t homeB -S -300 2>/dev/null || true; }

build_home homeA
build_home homeB

clean_env tmux -L "$SOCKET" new-session -d -s homeB -x 200 -y 50 -c "$LAB/homeB" \
  "$CLAUDE_BIN --dangerously-skip-permissions" || fail "could not start home B's session"

# First launch in a new folder asks for trust with "No, exit" highlighted, and a
# first-ever bypass launch asks for consent; answer each, then wait for the
# composer's bypass footer.
ready=0
for _ in $(seq 1 60); do
  screen=$(capture_b)
  case "$screen" in
    *'Yes, I trust this folder'*) tmux -L "$SOCKET" send-keys -t homeB Down Enter ;;
    *'Yes, I accept'*) tmux -L "$SOCKET" send-keys -t homeB Down Enter ;;
    *'bypass permissions on'*) ready=1; break ;;
  esac
  sleep 2
done
[ "$ready" -eq 1 ] || fail "home B's session never reached its composer: $(capture_b | tail -15)"

B_NAME=""
for _ in $(seq 1 15); do
  for rec in "$SESSIONS"/*.json; do
    B_NAME=$(jq -r --arg cwd "$LAB/homeB" 'select(.cwd == $cwd) | .name' "$rec" 2>/dev/null)
    [ -z "$B_NAME" ] || break 2
  done
  sleep 2
done
[ -n "$B_NAME" ] || fail "no record in $SESSIONS names home B's cwd; the session registry format changed"
pass "Claude Code recorded home B's live session as $B_NAME"

PROMPT="This is a test of tool permissions. Load deferred tools with ToolSearch first if needed. Then make exactly these four tool calls in order, each one even if an earlier one failed:
1. ListAgents.
2. SendMessage with to=\"$B_NAME\" and message=\"$TOKEN: this is a test line from a scratch home and needs no reply.\"
3. SendMessage with to=\"main\" and message=\"$TOKEN second\".
4. Agent with description \"probe\" and prompt \"Reply with the word ok.\"
Then report each result in one line."
STREAM="$LAB/a-stream.jsonl"
(cd "$LAB/homeA" && clean_env "$CLAUDE_BIN" -p "$PROMPT" --dangerously-skip-permissions \
  --output-format stream-json --verbose > "$STREAM" 2> "$LAB/a-stderr.txt") \
  || fail "home A's session exited non-zero: $(tail -5 "$LAB/a-stderr.txt")"

# Pair each tool call with its result: "<tool> <to> <error> <result text>".
result_of() {  # <tool> [to]
  jq -rs --arg tool "$1" --arg to "${2:-}" '
    ([.[] | select(.type == "assistant") | .message.content[] | select(.type == "tool_use")
      | select(.name == $tool and ($to == "" or .input.to == $to)) | .id]) as $ids
    | [.[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
      | select(.tool_use_id as $id | $ids | index($id))
      | "error=\(.is_error // false) \(.content | tostring)"] | first // "missing"' "$STREAM"
}

listing=$(result_of ListAgents)
case "$listing" in
  error=false*"$B_NAME"*) pass "home A's ListAgents is allowed and lists $B_NAME" ;;
  *) fail "ListAgents was refused or did not list $B_NAME: ${listing:0:400}" ;;
esac

sent=$(result_of SendMessage "$B_NAME")
case "$sent" in
  error=false*success*) pass "home A's SendMessage to $B_NAME is allowed" ;;
  *) fail "SendMessage to $B_NAME was refused or missing: ${sent:0:400}" ;;
esac

arrived=0
for _ in $(seq 1 30); do
  if capture_b | grep -Fq "$TOKEN"; then arrived=1; break; fi
  sleep 2
done
[ "$arrived" -eq 1 ] || fail "the message never appeared in home B's session: $(capture_b | tail -15)"
pass "the message arrived in home B's session"

to_main=$(result_of SendMessage main)
case "$to_main" in
  error=true*'[subagent-dispatch]'*'live session of another firstmate primary home'*) pass "SendMessage to main is refused" ;;
  *) fail "SendMessage to main was not refused by the guard: ${to_main:0:400}" ;;
esac

agent=$(result_of Agent)
case "$agent" in
  error=true*'[subagent-dispatch]'*) pass "Agent is still refused" ;;
  *) fail "Agent was not refused by the guard: ${agent:0:400}" ;;
esac
