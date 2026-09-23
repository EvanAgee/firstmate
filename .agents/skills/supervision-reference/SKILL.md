---
name: supervision-reference
description: >-
  Agent-only per-wake handling that AGENTS.md section 8 summarizes.
  Use before handling an actionable signal, stale, check, or heartbeat wake, and when a wake reports a merged PR.
user-invocable: false
metadata:
  internal: true
---

# supervision-reference

`AGENTS.md` section 8 keeps the live-cycle, drain, acknowledgement, and watcher-safety rules inline; this skill holds the per-wake handling moved out of it word for word.
"Always-loaded" below describes `AGENTS.md` section 8 itself, and section numbers refer to `AGENTS.md`.

Fleet supervision is an always-loaded operational contract; `docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own mechanisms and harness-specific recipes.
Guard warnings do not replace the contract.
The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
If away mode is present, load `/afk` and let its daemon own supervision rather than arming another cycle.

Handle actionable wakes as follows:

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, Relay events, process-to-event source results, and captain-queue replies.
   On a `captain-reply` result, run `bin/fm-captain-queue.sh reconcile` before acting on the `handled:` answers it prints.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, run `bin/fm-captain-queue.sh reconcile` and act on any `handled:` answers it prints, and never report an unchanged fleet as progress.

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
