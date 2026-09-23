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

`AGENTS.md` section 8 keeps the live-cycle, drain, acknowledgement, and watcher-safety rules inline; this skill holds the per-wake handling it summarizes.
`docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own supervision mechanisms and harness-specific recipes.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
Drain the durable wake queue first, as section 8 requires, then handle actionable wakes as follows:

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, Relay events, process-to-event source results, and captain-queue replies.
   On a `captain-reply` result, run `bin/fm-captain-queue.sh reconcile` before acting on the `handled:` answers it prints.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, run `bin/fm-captain-queue.sh reconcile` and act on any `handled:` answers it prints, and never report an unchanged fleet as progress.

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.
