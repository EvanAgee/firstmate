---
tags: [supervision, watcher, stale, paused]
date: 2026-09-23
---

# A parked worker is not stale

The captain approved this fix on 2026-09-23 in the firstmate fixes batch.

## Problem Statement

A worker that declares a `paused:` wait and ends its turn is doing what its brief tells it to do.
The brief promises that firstmate then leaves the idle pane alone and rechecks it on a long cadence.
The watcher breaks that promise whenever the worker's agent is still running.
On 2026-09-23 the Claude worker on lane `macpro-bench-branch` woke firstmate three times with a bare `stale: firstmate:fm-macpro-bench-branch`.
Each time it sat idle at its prompt, its footer read `1 monitor`, its own status log ended in a fresh `paused: [key=bench-runs]` line, and its busy-state record read `state=idle source=claude-hook event=stop`.
The watcher's pause classifier lets any live agent override a declared pause, so every new idle pane after a fresh pause surfaces as a bare stale wake instead of joining the pause cadence.
Each false wake costs firstmate a full handling turn, once per wait cycle of a worker that is behaving correctly.

## Seams

- The watcher process, `bin/fm-watch.sh`, run over a seeded state directory with the fake tmux from `tests/wake-helpers.sh`.
  This is the highest seam: it is the process that decides whether firstmate wakes, and the stale dispatch that caused the bug can only be reached by running it.
  Tested through `tests/fm-watch-wedge-two-signal.test.sh`, which already drives the real watcher this way and reads the wake queue it writes.
- The busy-state record, written by the real `bin/fm-busy-event.sh`, is how a fixture says the agent's own turn ended.
  The fix reads that record through the existing classifier in `bin/fm-busy-lib.sh`, so no new vendor surface is read and no new harness-dependent check is added.

## Acceptance Criteria

A worker is "parked" when its latest status line is a declared `paused:` wait, its agent is alive, and its harness's own lifecycle source reports that its turn has ended (an `idle` busy-state verdict from a semantic source, never the Grok rendered-text fallback).

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | While a worker is parked, when the watcher sees a new idle pane for it, the watcher shall absorb that pane onto the pause cadence and shall queue no bare `stale: <window>` wake. | `test_parked_live_pause_absorbs_each_new_idle_pane`; fixture: a `harness=claude` tmux task whose pane runs `claude`, an armed busy gen with an `idle` `claude-hook` `stop` record, a fresh `paused: [key=bench-runs]` line, and three watcher runs that each see different pane text, with the wake queue drained between runs. It asserts zero bare stale wakes and a `.paused-<key>` marker. The base commit queues a bare stale wake. Making the parked check always answer no turns it red the same way. | On a private tmux server running real Claude Code with the same hooks `fm-spawn` writes, the real watcher's wake queue holds no bare stale wake after the worker's pane changes, and its triage log reads `absorbed stale (paused, awaiting external - declared pause ...)`. | tests/fm-watch-wedge-two-signal.test.sh |
| AC2 | While a worker is parked, when its `paused:` line is older than `FM_PAUSE_RESURFACE_SECS`, the watcher shall re-surface it once with the recheck reason `stale: <window> (paused <n>s, awaiting external - declared pause, rechecked on a long cadence not a wedge; ...)`. | `test_parked_live_pause_rechecks_on_the_long_cadence`; fixture: the AC1 task with its status file backdated 500 seconds and `FM_PAUSE_RESURFACE_SECS=1`. It asserts one wake that carries `awaiting external` and no bare stale wake. The base commit queues the bare wake instead. Classifying the parked worker as `working` rather than `paused` turns it red with no recheck wake. | On the same walk, backdating the status file past a one-second window makes the real watcher print the `awaiting external ... rechecked on a long cadence` reason. | tests/fm-watch-wedge-two-signal.test.sh |

## End-to-end verification

Run a private tmux server (`tmux -L <socket>`) through a `tmux` shim on `PATH`, with an isolated `FM_HOME` holding one `harness=claude` task record whose window runs real Claude Code in a scratch directory.
Write that directory's `.claude/settings.local.json` with the `Stop` and `UserPromptSubmit` hooks `bin/fm-spawn.sh` writes, pointed at the walk home, and arm the busy gen with `bin/fm-busy-event.sh arm`.
Send Claude a one-line prompt, wait for the `stop` record, append a `paused: [key=walk]` line, and run `bin/fm-watch.sh` until it has classified the idle pane.
Send a second prompt so the pane changes, wait for the next `stop` record, and run the watcher again.
Expected: the wake queue holds no bare `stale: <window>` line and the triage log shows the paused absorb for both panes.
Then backdate the status file, run once more with `FM_PAUSE_RESURFACE_SECS=1`, and expect the `awaiting external ... rechecked on a long cadence` reason.
Repeating the first two runs on the base commit, from a throwaway copy, queues the bare stale wake, which is the recorded bug.
The proof at `docs/proof/fm-watcher-stale-while-monitor.md` records what this walk showed.

## Non-goals

- Reading the Claude footer's `1 monitor` text to treat a worker with no `paused:` line as parked.
  That text is a vendor-rendered surface that would need its own live harness guard, and every recorded wake already had a `paused:` line.
- Changing `captain-held` handling, which keeps the old rule that a live agent surfaces once.
- Changing a live paused agent whose turn end cannot be verified, such as a Grok pane read from rendered text or a Claude pane with no busy-state record.
  It still surfaces once, which `test_exited_declared_pause_is_bounded_but_live_gate_surfaces` and `test_declared_pause_with_live_agent_stays_none` keep guarding.
- Changing away mode, where the supervisor daemon already rechecks any declared pause on the long cadence.
- Changing the length of the pause cadence.

## Open questions

None.
