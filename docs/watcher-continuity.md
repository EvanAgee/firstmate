# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its loop bounds and supersession baton.
Claude's `.claude/settings.json` Stop hooks own routine tokenless continuity through two cooperating hooks that fire on the same Stop event: a persistent `async` COORDINATOR (`bin/fm-claude-watch-coordinator.sh`) and a parked `asyncRewake` NOTIFIER (`bin/fm-claude-watch-notifier.sh`, the former auto-arm).
Splitting them is required: a single async hook cannot both keep a watcher child alive and exit 2 to wake the idle session, because exiting reaps the child.
The coordinator keeps supervision alive; the notifier is the exit-2 wake path.
Both apply the same scope, identity, AFK, supervision-need, single-flight, and stale-session-lock-recovery gates the auto-arm applied, so an idle, away, child, or foreign-host checkout stays inert, and a numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` only after the AFK and need gates pass.
The coordinator admits one home-scoped owner per session generation (`state/.claude-coordinator.lock`, role `coordinator`) and keeps exactly one arm/watcher cycle alive by driving the real `bin/fm-watch-arm.sh` as a tracked background child; it never detaches to init, so Claude's session teardown, timeout, `/new`, `/resume`, `/fork`, and interrupt reap it with the session.
The notifier admits one parked owner (`state/.claude-autoarm.lock`, role `notifier`) and blocks until it can exit 2.
The Claude turn-end guard trusts a live `notifier`-role owner exactly as it trusted the `autoarm` role, and it owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations); a `coordinator`-role lock alone never satisfies the guard, because a coordinator cannot exit 2.
While supervision is still needed and away mode remains inactive, an actionable close makes the coordinator publish a ready-to-notify record and the notifier wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's coordinator now establishes and verifies the successor before the notifier surfaces the wake, the same Option B ordering Pi and OpenCode use, rather than the former next-Stop gap.
After an actionable child close the coordinator reads the queue high-water mark, arms and verifies a fresh successor (a live watcher owning `state/.watch.lock` with a fresh beacon), and only then writes an atomic `state/.claude-ready-to-notify` record binding that high-water mark, the recovery generation, the predecessor arm pid, the verified successor pid and identity, the coordinator generation, and the session owner.
A confirmed successor resets the coordinator's readiness-timeout streak. After `FM_CLAUDE_COORD_SUCCESSOR_TIMEOUT_STREAK` consecutive timeouts with no healthy watcher (default 3), the coordinator stands down: it stops retrying, releases `state/.claude-coordinator.lock`, removes its generation file, and exits so it is no longer alive.
The notifier consumes that record by its monotonic `ready_seq` high-water mark, never by counting queue rows, so the watcher's deliberate double-scan (which appends duplicate rows for one event) never inflates the number of handling turns; it exits 2 exactly once per ready event whose session owner and coordinator generation still match this session, and surfaces a typed coordinator-degraded failure rather than exiting 0 into a still-needed-but-unsurfaced state. Once the coordinator has stood down, the parked notifier's coordinator-absent bound fires and drives that same typed failure plus the guard's failed-epoch progression.
Because the coordinator keeps one live watcher across the whole handling turn, a turn longer than the beacon grace no longer leaves supervision genuinely absent, which was the false "watcher down" the former next-Stop design produced.
For every supported arm path, a successor that observes an accepted down stretch emits `check: rearm-resurface` through the ordinary durable handling path before settling into its live wait.
That recovery presentation includes all unacknowledged queue rows, the cursor-folded OPEN DECISIONS set, and still-unread informational status lines, so a still-open decision or a buried `note:` answer reappears even when recovery has no queue row of its own.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence, while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition, followed by four additive fields: arm source (`autoarm` or `manual`), auto-arm epoch sequence, session-lock owner pid, and compact termination cause.
Those four fields follow successor so readers of the original twelve fields stay valid.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy, and the additive lifecycle-ledger fields (autoarm source and epoch, manual defaults, and the original twelve fields remaining parseable in order).
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-watch-notifier.test.sh` covers the notifier's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, foreign-host stand-down, and a parent-process-group TERM that records an interrupted epoch.
`tests/fm-claude-watch-coordinator.test.sh` drives the REAL arm, watcher, queue, and recovery marker in a temp home to prove the successor-first ordering the whole task exists to fix: a verified live watcher owns the lock before the ready record is published, one stable watcher keeps the beacon fresh across a turn longer than grace, an actionable close re-arms a verified successor and re-publishes a higher `ready_seq`, the parked notifier exits 2 exactly once keyed to that high-water mark and never re-wakes the same event, a duplicated-row event still yields one handling turn, concurrent coordinator firings admit one owner, a coordinator lock alone never satisfies the turn-end guard, the coordinator stands down on a session handover, and a persistent successor-confirm failure stands the coordinator down after a bounded timeout streak so the turn-end guard blocks an idle Stop.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-watch-coordinator-live-e2e.test.sh` exercises the two parallel Stop hooks in a real Claude session across an idle wake, a handling turn longer than grace, a second event during that turn, a normal Stop, and session teardown.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
