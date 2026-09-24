---
tags: [subagent-guard, messaging, cross-home, claude]
date: 2026-09-24
issue: fm-cross-home-session-messaging
walked: 469d1a542ec4a8903839925fee72b5717ffee19a
---

# Firstmate homes message each other's live session

Spec: [`docs/specs/fm-cross-home-session-messaging.md`](../specs/fm-cross-home-session-messaging.md).

## What I walked

I walked commit `469d1a54` on macOS 27.0 with Claude Code 2.1.281, GNU bash 5.3.15, and jq 1.7.1.
Every live run used two scratch firstmate primary homes, each a fresh `git init` holding `AGENTS.md`, `state/`, a copy of `bin/fm-subagent-pretool-check.sh` and `bin/fm-primary-scope-lib.sh`, and a `.claude/settings.json` holding only the tracked match-all PreToolUse entry.
Both sessions started with a clean environment, so neither inherited this session's messaging identity or `FM_HOME`.
No message went to the captain's `firstmate` or `firstmate2` sessions.

### Walk 1: by hand, then the control

1. I started home B's Claude Code session interactively in a private tmux server with `--dangerously-skip-permissions`.
   The trust dialog opened with "No, exit" highlighted; I moved to "Yes, I trust this folder" and confirmed.
   Claude Code wrote `~/.claude/sessions/33407.json` with `"name":"homeb-31"`, `"pid":33407`, and home B's path as `cwd`.
2. From home A, `claude -p ... --output-format stream-json` made four calls.
   `ListAgents` succeeded and listed `homeb-31 [3f01a3] · interactive · idle` among 13 peers.
   `SendMessage` to `homeb-31` returned `"success":true` with `queued there`.
   `SendMessage` to `main` came back `PreToolUse:SendMessage hook error` with `[subagent-dispatch] SendMessage from a firstmate primary may only carry a plain-text message to the live session of another firstmate primary home on this machine`.
   `Agent` came back `PreToolUse:Agent hook error` with `[subagent-dispatch] the firstmate primary dispatches through the fleet`.
3. Home B's pane showed `› Message from @homea-b3: fm-messaging-live-1790245407: this is a test line from a scratch home and needs no reply.`, and B's session answered in its own pane that it needed no reply.
4. The live tool input for that `SendMessage` held `to` and `message` plus `type`, `recipient`, and `content`, which the harness adds; the guard reads only `to` and `message`.
5. Control: I put the pre-change guard from `16fd2a61` into home A and had it send one line to `homeb-31`.
   The call came back `PreToolUse:SendMessage hook error` with the old `the firstmate primary dispatches through the fleet` text, and home B's pane never showed that control token.

### Walk 2: the live guard

`FM_SUBAGENT_MESSAGING_LIVE_E2E=1 bash tests/fm-subagent-messaging-live-e2e.test.sh` at `469d1a54` exited 0 and printed:

```text
ok - Claude Code recorded home B's live session as homeb-a2
ok - home A's ListAgents is allowed and lists homeb-a2
ok - home A's SendMessage to homeb-a2 is allowed
ok - the message arrived in home B's session
ok - SendMessage to main is refused
ok - Agent is still refused
```

It passed the same way at `44a4a177` and `6767512f`.

### Walk 3: the real session registry, with nothing sent

I piped `SendMessage` payloads to scratch home A's guard with the live `~/.claude/sessions`, which only classifies and sends nothing.

| Target | Recorded cwd | Guard exit |
| --- | --- | --- |
| `firstmate2-6f` | `/Users/evanagee/Sites/firstmate2` | 0 |
| `firstmate-85` | `/Users/evanagee/Sites/firstmate` | 0 |
| `zombie-game-aa` | `/Users/evanagee/Sites/Zombie Game` | 2 |
| `aos-light-2-60` | a treehouse task worktree | 2 |
| `firstmate-2d` | this task's linked worktree | 2 |
| `manager-a7` | `/Users/evanagee/Sites/manager`, pid gone | 2 |
| `main` | no record | 2 |

So once this lands, each of the captain's two homes resolves the other as a peer, and a crewmate, another project, and a stale record do not.

## Acceptance criteria

Each criterion's check passes at `469d1a54`.
For each mutation I extracted `git archive HEAD` into a throwaway directory, changed one string there with a helper that refuses when the string is absent, and ran only the named check.
An unmutated copy ran green, and the helper refused an absent string with `control: expected exactly one match, found 0`.

- AC1: `test_messaging_tools_list_sessions` in `tests/fm-subagent-pretool-check.test.sh` passes.
  Changing `MESSAGING_ONLY_TOOLS` to `'sendmessage'` failed it with `session listing (ListAgents) must allow, got exit 2`.
- AC2: `test_send_message_reaches_a_live_peer_home` passes for a plain-text message and for a pure `notify_when_idle` subscription.
  Replacing the peer-target allow with `:` failed it with `plain-text message to a live peer home must allow, got exit 2`.
- AC3: `test_send_message_refuses_every_other_target` passes for `main`, `researcher`, `a1b2c3d4-e5f6`, `peer-home-7a [0232ca]`, `crew-7b`, `plain-7c`, `gone-7d`, `twin-7e`, an empty name, a missing `to`, and the `--tool SendMessage` form.
  Dropping the `fm_primary_scope_matches` check on the peer's cwd failed it with `SendMessage to 'crew-7b' must deny with exit 2, got 0`, and the mutated guard also let `plain-7c` through with exit 0 where the real guard exits 2.
- AC4: `test_send_message_refuses_structured_messages` passes for a `shutdown_request` and a `plan_approval_response`.
  Dropping the string check on `message` failed it with `shutdown request to a peer home must deny with exit 2, got 0`.
- AC5: `grep -c 'never replaces a brief, a status line, or the backlog' docs/subagent-guard.md` prints `1`.
  Deleting that sentence in a copy made it print `0`.
- AC6: `FM_SUBAGENT_MESSAGING_LIVE_E2E=1 tests/fm-subagent-messaging-live-e2e.test.sh` exits 0 with the six `ok` lines above.
  Running it from a copy holding the pre-change guard exited 1 at `not ok - ListAgents was refused or did not list homeb-d6`, and walk 1's control shows the same guard refusing the `SendMessage` itself.

## Other checks

- `bin/fm-lint.sh` passed under the pinned ShellCheck 0.11.0, and `shellcheck -x` passed on both test files.
- `tests/fm-test-run.test.sh`, `tests/fm-omp-primary.test.sh`, `tests/fm-turnend-guard.test.sh`, `tests/fm-agents-coverage.test.sh`, `tests/fm-agents-size.test.sh`, and `tests/fm-agents-must-stay.test.sh` each exited 0.
- `bin/fm-doc-audience-check.sh` printed `ok surfaces=154 local_links=307`.
- `npx unslop` reported `No supported files found` for these shell and Markdown files, so I applied the `unslop` writing rules to the new prose by hand.
