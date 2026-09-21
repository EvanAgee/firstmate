---
name: supervision-reference
description: Load when handling an actionable wake or entering away or quiet mode.
user-invocable: false
metadata:
  internal: true
---

# 8. Supervision protocol

Treat any `OPEN DECISIONS` section from the drain as actionable reconciliation input even when no wake record was queued.
Treat any `UNREAD STATUS` section as newly surfaced status that must be read this turn; those lines are not re-printed after this presentation.
Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof the captain ruled; load `captain-hold-lifecycle` and reconcile it in whichever direction the evidence supports.

Handle actionable wakes as follows:

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event source results, and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

Load `bearings` on a contributions check wake or when filing work linked to an upstream issue; its contribution-follow-up section owns triage and exact signal acknowledgement.

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.

Guard warnings do not replace the contract.
Queued wakes must be presented before other action and acknowledged only after handling, stale liveness must be repaired through the emitted protocol, and the worktree-tangle warning must be resolved without touching unlanded work.
The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.
Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle.

### Away-mode and quiet-mode stub

- Every current daemon injection uses the `away-supervisor` kind from `bin/fm-operational-input.sh` after `FM_OPERATIONAL_PREFIX` (U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), while the `/afk` skill owns legacy bare-marker compatibility.
  The daemon is never launched on Pi, where the ordinary supervision session continues under the record with main parked: the branch takes every safe actionable wake it can, and only a declined wake (including a broken branch or unsafe scan) or a watcher failure wakes main.
- A message beginning `/afk` refreshes away mode; a message beginning `/quiet` refreshes quiet mode.
- Any other unmarked message means the captain returned in away mode (load `/afk`, run the return owner, and do not process that message as ordinary work until its durable catch-up gate clears), or, in quiet mode, is simply answered as ordinary work with the flag and daemon left untouched until an explicit `/quiet off`.
