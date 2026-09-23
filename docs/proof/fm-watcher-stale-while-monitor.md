---
tags: [supervision, watcher, stale, paused, regression]
date: 2026-09-23
issue: fm-watcher-stale-while-monitor
walked: fc2970b6ad81acd00fe1afd66baf63371a8e6f45
---

# A parked live worker stays on the pause cadence

Spec: `docs/specs/fm-watcher-stale-while-monitor.md`.

## What I walked

I first walked commit `c0f43f9b` against real Claude Code 2.1.280 (Haiku 4.5) on a private tmux 3.7c server (`tmux -L fmwalk-park`, reached through a `tmux` shim on `PATH`), with an isolated firstmate home holding one `harness=claude`, `mode=local-only` task record named `walkpark`.
The worker's scratch directory carried the same `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks `bin/fm-spawn.sh` writes, pointed at that home, with its busy gen armed by `bin/fm-busy-event.sh arm`.
The captain's tmux server and firstmate home were not touched.
For the old behavior I ran `bin/fm-watch.sh` from `git archive 4d80f458` over a copy of the same home, against the same live pane.
Each watcher ran with `FM_POLL=2 FM_SIGNAL_GRACE=1` and stopped after 40 seconds if it had not woken, and each wake was acknowledged with `bin/fm-wake-drain.sh --ack-through`, as firstmate does.

1. Claude answered `ok`, and its own `Stop` hook wrote `state=idle source=claude-hook event=stop` (seq 3).
   I appended `paused [key=walk]: walk run in progress, monitor armed` to the status log, as the incident worker did.
2. Both watchers first woke once with `signal: .../walkpark.status`, the pause line itself, and I acknowledged it.
3. The old watcher's next run woke with `stale: fmwalk:fm-walkpark` and queued `stale | stale: fmwalk:fm-walkpark`.
   That is the recorded bug on a real Claude pane.
4. The fixed watcher's next run did not wake for 40 seconds, queued nothing, and logged `absorbed stale (paused, awaiting external - declared pause, age 522s): fmwalk:fm-walkpark` on every poll.
   This is AC1 on the first idle pane.
5. I sent a second prompt, Claude answered `two`, its `Stop` hook wrote seq 5, and I appended a fresh `paused [key=walk]: second walk run in progress, monitor armed` line, which is the next wait cycle on the incident lane.
6. After both watchers woke once for that new status line, the old watcher again woke with `stale: fmwalk:fm-walkpark`.
   The fixed watcher ran 40 seconds with no wake and logged `absorbed stale (paused, awaiting external - declared pause, age 49s)` through `age 63s`.
   This is AC1 on a new idle pane after a fresh pause.
7. I set the status file's time 3,700 seconds back, past the default 3,600-second pause window.
   After the signal for that change, the fixed watcher woke with `stale: fmwalk:fm-walkpark (paused 3713s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)`.
   Its next run stayed quiet for 30 seconds and logged `absorbed stale (paused, ... age 3730s)` onward, so the recheck fires once per window.
   This is AC2.
   The spec's walk names `FM_PAUSE_RESURFACE_SECS=1`; I kept the default window and aged the file instead, which reaches the same branch with the real setting.
8. `/exit` closed Claude, whose `SessionEnd` hook wrote `event=session-end`, and `kill-server` stopped the private tmux server.
9. Main moved three times while this branch waited, so I rebased onto `89f61f38`, `c1e2980d`, and then `1a0b8e19`, whose code changes are in `bin/fm-captain-queue.sh`, `bin/fm-decision-hold.sh`, and `bin/fm-pr-autoarm.sh`; none of them touches the pause classifier.
   After each rebase I repeated steps 1, 2, 4, 5, 6, 7, and 8 for the fixed watcher in a fresh home, on `23a43b82`, `3f652599`, and last on `fc2970b6`, the commit this proof names.
   On `fc2970b6` both wait cycles ran 40 seconds with no wake and logged `absorbed stale (paused, awaiting external - declared pause, ...)`, the aged pause woke once with `stale: fmwalk:fm-walkpark (paused 3708s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)`, and the next run stayed quiet for 30 seconds.

## Acceptance criteria

| AC | Evidence |
|---|---|
| AC1 | Walk steps 3, 4, and 6: the old watcher queued a bare `stale: fmwalk:fm-walkpark` on each idle pane, and the fixed one queued nothing and logged the paused absorb. `test_parked_live_pause_absorbs_each_new_idle_pane` failed on `4d80f458` with `a parked live worker woke firstmate with 3 bare stale wakes across three idle panes` and passes on `c0f43f9b`, `23a43b82`, `3f652599`, and `fc2970b6`. |
| AC2 | Walk step 7: one `awaiting external - declared pause, rechecked on a long cadence` wake past the window, then quiet. `test_parked_live_pause_rechecks_on_the_long_cadence` failed on `4d80f458` with `a parked live worker surfaced a bare stale wake instead of its recheck` and passes on `c0f43f9b`, `23a43b82`, `3f652599`, and `fc2970b6`. |

## Control runs

Each mutation ran on a throwaway copy of the worktree, never in the worktree; the unchanged copy passed first.

| What was broken | What failed |
|---|---|
| The parked check always answers no | Both new tests: `3 bare stale wakes across three idle panes` and `surfaced a bare stale wake instead of its recheck` |
| A parked worker classified `working` instead of `paused` | `test_parked_live_pause_rechecks_on_the_long_cadence`: `queued 0 rechecks, want 1` |
| Grok's rendered-text idle counted as a turn end | `test_exited_declared_pause_is_bounded_but_live_gate_surfaces`: `live external-decision gate did not surface immediately` |
| Any busy-state verdict counted as a turn end | `test_declared_pause_with_live_agent_stays_none`: `declared pause + live agent must classify none, got 'paused'` |

## Local checks

`tests/fm-watch-wedge-two-signal.test.sh` passed in full: 60 ok, 0 failed, exit 0.
`bin/fm-lint.sh` passed with ShellCheck 0.11.0 before and after each rebase.
`npx unslop` reported `No supported files found.` for the changed shell and Markdown files, so it checked nothing.
`tests/fm-watch-triage.test.sh` could not finish on this Mac: the load average was 57 to 71 from other lanes, and each full run stopped at a different timing case (`the later note did not surface as a signal`, then `provably-working signal did not advance its .seen-* suppressor`).
Both cases passed when run alone.
I then ran the eleven pause-related triage cases by name.
Eight passed on the first try.
Under the same load, `test_exited_declared_pause_is_bounded_but_live_gate_surfaces` and `test_secondmate_unpause_clears_pause_tracking` failed the same way on `4d80f458` and on this branch, and `test_secondmate_paused_resurfaces_in_normal_mode` passed on both on its retry.
Rerun alone once the load eased to about 53, all three passed on this branch, so every pause-related triage case has a pass on `c0f43f9b`.
GitHub Actions ran the full suite on `bddc0cc6` in run 35910267874 and on `53f02541` in run 35912508534, the heads after the first and second rebases; both passed, with `tests/fm-watch-triage.test.sh`, `tests/fm-watch-wedge-two-signal.test.sh`, and `tests/fm-watch-arm.test.sh` each at exit 0.
The first run on this branch, 35908293648, was cancelled when `tests/fm-watch-arm.test.sh` stalled for 12 minutes in `test_rearm_resurfaces_durable_queue_and_remote_open_decision`, a watcher downtime recovery case with no worker panes, which passed locally and in the rerun.
