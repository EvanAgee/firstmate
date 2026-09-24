---
tags: [subagent-guard, messaging, cross-home, claude]
date: 2026-09-24
---

# Firstmate homes message each other's live session

The captain picked Claude Code's own session messaging for cross-home coordination on 2026-09-24 ("Session messaging"; homes message each other's live session directly, a small wrapper at most).

## Problem Statement

The captain runs two firstmate homes on one Mac, `/Users/evanagee/Sites/firstmate` and `/Users/evanagee/Sites/firstmate2`, each with its own live Claude Code primary session.
When one home needs to hand work to the other, answer the other, or warn it that it is touching a path, there is no direct channel, so the captain relays by hand.

Claude Code already ships that channel: `ListAgents` lists the live sessions on this machine and `SendMessage` delivers a message into one of them.
The primary-session delegation guard refuses both in a primary home.
`SendMessage` matches the `sendmessage` delegation stem and `ListAgents` matches the `agent` stem.
The only way past the guard today is launching with `FM_ALLOW_SUBAGENT=1`, which also unlocks `Agent`, `Workflow`, and every other delegation tool, and the captain wants fleet work to keep going through `bin/fm-spawn.sh`.

`SendMessage` is not a pure messaging tool.
Its own tool description says a send to a finished subagent's name "resumes it from its transcript", that it accepts a raw subagent `agentId` and the address `main`, and that a bare name can reach a session "on this machine, on another machine, or in the cloud".
So allowing it by name alone would let a primary start runnable work the fleet never records, which is the exact failure the guard exists to stop.

## Solution

The guard allows `ListAgents` in a primary home, because it only lists sessions.

The guard allows `SendMessage` in a primary home only when the call is plain messaging between firstmate homes on this machine: the message is plain text, and the target name resolves to exactly one live Claude Code session on this machine whose working directory is a genuine firstmate primary home.
Every other `SendMessage` stays refused, with a reason that says what is allowed and names the fleet paths for everything else.
That covers a subagent name or id, `main`, a cloud or other-machine session, a crewmate's session in its task worktree, any session outside a firstmate home, and a structured shutdown or plan-approval message.
`Agent`, `Task`, `Workflow`, cron, schedule, remote, worktree, and every other delegation shape stay refused as before.

The guard can tell a peer home apart because Claude Code records every live local session in `<config dir>/sessions/<pid>.json` with its `name`, `pid`, and `cwd`, where the config dir is `CLAUDE_CONFIG_DIR` or `~/.claude`.
A subagent, a cloud session, and a Remote Control session on another machine have no such record, so they can never resolve.

The guard contract doc gains the usage rule: a home messages a peer home only for cross-home coordination (a handoff, an answer, "I'm touching path X"), and a message never replaces a brief, a status line, or the backlog.

## Seams

- `bin/fm-subagent-pretool-check.sh` as a command - existing - `tests/fm-subagent-pretool-check.test.sh` already feeds it Claude-shaped PreToolUse JSON in a fixture primary home; the hook's exit code and streams are everything Claude Code reads, so nothing sits higher that a portable test can reach.
- A live Claude Code session pair - **new** - an opt-in live guard in the `live-harness-optin` family drives two real scratch primary homes, because the session registry and message delivery are vendor behavior a fixture can only restate.
- `docs/subagent-guard.md` as a document - existing - it owns the guard contract, and the usage rule is read there.

## User Stories

### US1 - Coordinate with a peer home (P1)

As a firstmate primary, I want to list the live sessions on this Mac and message another firstmate home's primary session, so that cross-home handoffs, answers, and path warnings no longer go through the captain.
**Independent Test:** from a scratch primary home, list sessions, message a live scratch peer home, and see the message arrive in the peer's pane.
**Criteria:** AC1, AC2, AC6

### US2 - Messaging opens no delegation path (P1)

As the captain, I want `SendMessage` from a primary to reach only a peer home's live session, so that no subagent, cloud session, or crewmate can be started or steered outside the fleet through it.
**Independent Test:** send from a fixture primary home to a subagent-style name, `main`, a task-worktree session, a non-firstmate session, and a structured shutdown message, and see each refused.
**Criteria:** AC3, AC4, AC6

### US3 - The rule for when to message (P2)

As a firstmate primary, I want one written rule for when a peer message is right, so that messaging never replaces a brief, a status line, or the backlog.
**Independent Test:** read the rule in the guard contract doc.
**Criteria:** AC5

## Decisions

- The captain chose Claude Code session messaging for cross-home coordination, and fleet work keeps going through `bin/fm-spawn.sh` (captain, 2026-09-24).
- `FM_ALLOW_SUBAGENT=1` is not the answer, because it also unlocks `Agent` (the brief, from the captain's answer).
- The allowance is a new exact-name list, `MESSAGING_ONLY_TOOLS`, beside the observe-only and plan-only lists, so it can never widen by substring (the brief).
- A peer is a live local session whose recorded working directory passes the same `fm_primary_scope_matches` predicate the guard uses for its own home, with the peer's own `state/` as the state dir.
  A marked secondmate home therefore counts as a peer, and a crewmate's linked task worktree does not.
- Liveness is `kill -0` on the recorded pid, so a stale record left by a crashed session cannot vouch for a name.
- The target must match exactly one live record by name.
  A name carrying a ` [ref]` suffix is refused, because the ref is derived by Claude Code in a way the hook cannot map to a local record, and a ref can pick a same-named cloud or remote session.
- The message must be a JSON string or absent (a pure `notify_when_idle` subscription), so the legacy `shutdown_request` and `plan_approval_response` objects stay refused.
- `SendMessage` through the `--tool` transport carries no target, so it stays refused.
- The usage rule lives in `docs/subagent-guard.md`, the guard's contract owner, not in `AGENTS.md`, which has 121 bytes left under its 32,768-byte cap.
- Tests extend `tests/fm-subagent-pretool-check.test.sh` with a fixture sessions dir supplied through `CLAUDE_CONFIG_DIR`, whose live record uses the test's own pid.
  The live guard is a new opt-in test that copies only the guard and its scope library into two scratch homes, as the 2026-07-22 validation did.

## Acceptance Criteria

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | While the hook runs in a genuine firstmate primary home, when it receives the tool name `ListAgents`, the guard shall exit 0 with empty stdout and stderr. | `tests/fm-subagent-pretool-check.test.sh` case `test_messaging_tools_list_sessions` runs the guard in the fixture primary home with `--tool ListAgents` and with Claude-shaped stdin `{"tool_name":"ListAgents","tool_input":{}}`; assert exit 0 and both streams empty. **Remove `listagents` from `MESSAGING_ONLY_TOOLS` and prove AC1 goes red, because `agent` then matches.** | `printf '{"tool_name":"ListAgents"}' \| bin/fm-subagent-pretool-check.sh --claude; echo $?` in a primary home prints `0`. | `tests/fm-subagent-pretool-check.test.sh` |
| AC2 | While the hook runs in a genuine firstmate primary home, when a `SendMessage` payload's `to` names exactly one session record under `$CLAUDE_CONFIG_DIR/sessions` whose pid is alive and whose `cwd` is a genuine firstmate primary home, and its `message` is a string, the guard shall exit 0 with empty stdout and stderr. | `tests/fm-subagent-pretool-check.test.sh` case `test_send_message_reaches_a_live_peer_home` writes `sessions/1.json` with `{"name":"peer-home-7a","pid":<test pid>,"cwd":"<fixture peer home>"}`, where the peer home has `AGENTS.md`, `bin/`, `state/`, and its own `git init`; it sends `{"tool_name":"SendMessage","tool_input":{"to":"peer-home-7a","message":"handoff: I am touching bin/x.sh"}}` and also a pure subscription `{"to":"peer-home-7a","notify_when_idle":true}`; assert exit 0 and both streams empty for each. **Delete the peer-target allow and prove AC2 goes red.** | The same payload piped to the hook in a primary home, with a live peer record, prints nothing and `echo $?` prints `0`. | `tests/fm-subagent-pretool-check.test.sh` |
| AC3 | If a `SendMessage` target does not resolve to exactly one live local session whose `cwd` is a genuine firstmate primary home, then the guard shall exit 2 with empty stdout under `--claude`, and a `systemMessage` that contains `blocked tool: SendMessage` and `live session of another firstmate primary home`. | `tests/fm-subagent-pretool-check.test.sh` case `test_send_message_refuses_every_other_target` sends to `main`, the unknown name `researcher`, the agent id `a1b2c3d4-e5f6`, the ref-qualified `peer-home-7a [0232ca]`, `crew-7b` whose record's `cwd` is a linked worktree of the fixture home, `plain-7c` whose `cwd` is a git repo with no `AGENTS.md`, `gone-7d` whose pid is not alive, and `twin-7e`, which two live records share; the `--tool SendMessage` form is sent too; assert exit 2, empty stdout, and both strings in the message for each. **Skip the `fm_primary_scope_matches` check on the peer `cwd` and prove AC3 goes red on `crew-7b` and `plain-7c`.** | Piping `{"tool_name":"SendMessage","tool_input":{"to":"main","message":"x"}}` to the hook in a primary home prints the deny object on stderr naming `live session of another firstmate primary home`. | `tests/fm-subagent-pretool-check.test.sh` |
| AC4 | If a `SendMessage` payload's `message` is not a string, then the guard shall refuse it the way AC3 does, even when the target is a live peer home. | `tests/fm-subagent-pretool-check.test.sh` case `test_send_message_refuses_structured_messages` sends `{"to":"peer-home-7a","message":{"type":"shutdown_request","reason":"x"}}` and a `plan_approval_response` object to the live peer record from AC2; assert exit 2 and the AC3 message. **Drop the string check on `message` and prove AC4 goes red.** | The shutdown payload piped to the hook with a live peer record prints the deny object and `echo $?` prints `2`. | `tests/fm-subagent-pretool-check.test.sh` |
| AC5 | The guard contract doc shall state that a firstmate home messages a peer home only for cross-home coordination, and that a message never replaces a brief, a status line, or the backlog. | `grep -c 'never replaces a brief, a status line, or the backlog' docs/subagent-guard.md` prints `1`. **Delete the rule sentence and prove AC5 goes red, because the count becomes `0`.** | `docs/subagent-guard.md` section "Cross-home session messaging" carries the rule. | `grep -c 'never replaces a brief, a status line, or the backlog' docs/subagent-guard.md` |
| AC6 | While two scratch firstmate primary homes each run a live Claude Code session with the tracked match-all guard entry, when the first session calls `ListAgents`, then `SendMessage` to the second session's name, then `SendMessage` to `main`, then `Agent`, the first session shall see the second session listed, the message shall arrive in the second session, and the `main` send and the `Agent` call shall be refused with `[subagent-dispatch]`. | `tests/fm-subagent-messaging-live-e2e.test.sh`, run with `FM_SUBAGENT_MESSAGING_LIVE_E2E=1`, builds homes A and B under `$TMPDIR`, starts B interactively in a private tmux server, runs A with `claude -p --output-format stream-json`, and asserts each tool result plus B's pane showing the message token. **Run it against the base-commit guard and prove AC6 goes red, because the `SendMessage` to B is refused.** | B's tmux pane shows the `fm-messaging-live` token from A, and A's stream shows `[subagent-dispatch]` on the `main` send and on `Agent`. | `FM_SUBAGENT_MESSAGING_LIVE_E2E=1 tests/fm-subagent-messaging-live-e2e.test.sh` |

## End-to-end verification

Run the live guard on a Mac with Claude Code installed and signed in, from a checkout of this branch.

```sh
FM_SUBAGENT_MESSAGING_LIVE_E2E=1 tests/fm-subagent-messaging-live-e2e.test.sh
```

Expected: `ok` lines for the listing, the delivered message, the refused `main` send, and the refused `Agent` call, then exit 0.
Failure looks like a `not ok` line naming which of the four went wrong, with the Claude Code version, or a refusal that checked nothing because Claude Code is absent.

## Non-goals

- No wrapper script around `SendMessage`; the captain said "a small wrapper at most", and the guard change alone makes the built-in tools usable.
- No messaging to crewmates: a crewmate is steered with `bin/fm-send.sh`, which keeps its routing, keys, and decision records.
- No other harness gets a messaging tool; only Claude Code ships one, and the other adapters keep their current classification.
- No change to the recommended local Claude deny list's other entries or to `FM_ALLOW_SUBAGENT`.
- No mapping of the ` [ref]` suffix; a same-named collision is rare because Claude Code derives local names from the directory plus a random suffix, and a refused send costs one retry by bare name.
- No closing of the Skill-forked subagent gap: a skill that runs as a forked subagent is started through `Skill`, which this guard never classified.

## Open questions

None.

## Further Notes

`SendMessage` can reach a session "on another machine" over Remote Control, and a cloud session.
Both have no local session record, so the guard refuses them; cross-machine homes are out of scope for this change.

Claude Code's tool description says a bare name that also names an in-process subagent reaches the subagent.
A primary cannot create one through `Agent`, `Task`, or `Workflow`, which stay refused, so a bare peer-home name reaches the peer.
The one residual is a skill that runs as a forked subagent under a name equal to a peer home's session name, which the Non-goals leave open.
