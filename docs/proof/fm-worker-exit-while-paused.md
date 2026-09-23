---
tags: [supervision, control-plane, send, regression]
date: 2026-09-23
issue: fm-worker-exit-while-paused
walked: 05f15af11781fb5e2f2f32fe59df8206ab2ce448
---

# Deliberate exits and steers to a stopped worker

## What I walked

I walked commit `05f15af1` against a real Codex worker (codex-cli 0.156.0, GPT-5.6-Sol at low effort, launched through `teamcodex run`) on a private tmux server (`tmux -L fmwalk`), with an isolated `FM_HOME` holding two codex scout records.
The captain's tmux server and firstmate home were not touched.

1. Codex answered a one-word prompt and went idle, with `node` as the pane's foreground command.
2. `FM_HOME=<walk-home> bin/fm-control.sh walk-exit exit` printed `stopped walk-exit harness=codex backend=tmux ...` and exited 0.
   The pane then showed Codex's own quit banner (`To continue this session, run: codex resume ...`) and its command became `zsh`.
3. The walk home held `state/walk-exit.control-exit` with `v1`, `task=walk-exit`, `ts=2026-09-23T14:45:41Z`, and `harness=codex`.
4. `bin/fm-crew-state.sh walk-exit`, whose status log ended in a paused line, printed `state: paused · source: status-log · waiting on the walk · exited by firstmate at 2026-09-23T14:45:41Z`.
   `bin/fm-crew-state.sh walk-gone`, a codex record whose window only ever held a shell, printed `state: unknown · source: pane · agent gone`.
5. `bin/fm-send.sh walk-exit "firstmate probe; touch <marker>"` exited 1 with `error: no live agent at fmwalk:fm-walk-exit for task walk-exit (state=dead); refusing to type text a shell could run as commands. Relaunch it with: bin/fm-control.sh walk-exit relaunch --note-file <path>`.
   The pane held no line containing the steer text, and the marker file did not exist.
6. `FM_API=0 FM_HOME=<walk-home> bin/fm-session-start.sh` printed `endpoint: alive (backend=tmux window=fmwalk:fm-walk-exit)` followed by `agent: exited by firstmate at 2026-09-23T14:45:41Z`, and `endpoint: alive (backend=tmux window=fmwalk:fm-walk-gone)` followed by `agent: gone`.

Before this change, the same exit left no record, the digest printed only `endpoint: alive`, and a steer to the stopped pane was typed at the zsh prompt and run, as the scout report in the captain's private home records for the C0 lane on 2026-09-23.

## Validation

Each new assertion failed first on the pre-change code: `text to a pane whose foreground is zsh was accepted`, `exit left no durable record of the deliberate stop`, the digest, watcher, and daemon rechecks missing `exited by firstmate at`, teardown leaving the record, and relaunch keeping it.
Two control runs on a throwaway copy confirmed the tests can fail for their stated reason: letting an unclassifiable pane through made `tests/fm-send-strict.test.sh` fail with `text to a pane whose foreground is bun was accepted`, and letting a `working` log line through for a gone agent made `tests/fm-control.test.sh` fail with `a gone agent must not read as working from its last status line`.

The local runs covered every test file that names `bin/fm-send.sh`, sources `tests/wake-helpers.sh`, or exercises a changed reader, plus the tests of every script that calls `bin/fm-send.sh` (`fm-bootstrap.sh`, `fm-config-push.sh`, `fm-config-inherit-lib.sh`, `fm-pending-reply-lib.sh`, `fm-remote-secondmate-control.sh`, and `fm-watch.sh`).
A first local sweep silently skipped 15 of those files because one test read the runner's stdin; GitHub Actions run 35863441011 then failed on three fixtures that typed into panes with no modeled agent (`tests/fm-send-resolve-key.test.sh`, `tests/fm-send-secondmate-marker.test.sh`, `tests/fm-secondmate-harness.test.sh`), and those fixtures now model a live agent.
Five files fail on this Mac identically on unchanged main (`dfd36382`, or `4b616ee3` for the first): `tests/fm-watcher-lock.test.sh`, `tests/fm-spawn-dispatch-profile.test.sh` (a leftover `/tmp/fm-profile-*` fixture collision), `tests/fm-calm-pi-extension.test.sh`, the herdr-child-preflight case in `tests/fm-teardown.test.sh`, and `tests/fm-backend-herdr-presentation-e2e.test.sh`.
`tests/fm-watch-triage.test.sh` and `tests/fm-watch-arm.test.sh` failed only while three test lanes ran at once; `fm-watch-arm` passed alone, the failing watch-triage case passed five times in five alone, and run 35863441011 passed both files on Linux.
After rebuilding the branch on `63ba6402`, the fm-send, control, daemon, digest, watcher, teardown, and relaunch tests reran green, `bin/fm-lint.sh` passed with ShellCheck 0.11.0, and the walk above was repeated on the rebuilt code.
After rebasing onto `e3fc9eab`, which caps a Claude steer at 800 bytes, `fm-send` checks for a live agent first and then applies the cap; `tests/fm-send-strict.test.sh` covers both, with the cap test's sends now going to panes that run the matching agent.
The fm-send, backend, control, daemon, watcher, digest, teardown, and relaunch tests reran green on the rebased code, and the walk above was repeated on it.
