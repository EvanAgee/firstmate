# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism and structured surfaces.

## Mechanism

`bin/fm-decision-hold.sh` owns the durable lifecycle for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and activates it for the captain.
An exact retry preserves an existing parked or future deferral instead of reactivating the question.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
A hold that was answered and marked Done is eventually trimmed out of the backlog by Done-history retention, so `verify` treats a reviewed key whose hold is gone as satisfied only on positive evidence, on two counts.
First, the key must already be listed in the origin's recorded `decision_keys`, which `complete` writes only after it has found that key's hold durable.
`tasks-axi` reports the same not-found for a hold retention trimmed and a hold that never existed, so that record is what tells the two apart, and a key being inventoried for the first time can never use the tolerance.
Second, the key's last status transition must be a resolved line closing that exact key and carrying the `answered:` marker.
That marker is what `bin/fm-send.sh` writes when a captain's answer is delivered.
A bare `resolved [key=...]` line without it is a mate closing its own keyed phase, which `bin/fm-brief.sh` tells mates to do when a phase fizzles or a blocker clears on its own, so it is not proof anyone answered.
The `captain-held` transfer line is not answer proof either, because `complete` writes one for every reviewed key that is still open.
A key is stable and reusable, so an answer followed by a later `needs-decision` or `blocked` line re-opens it and it counts as unanswered again.
A reviewed key without that final answered resolve, whether still open, re-opened, self-closed, or never seen in the status log, must still have a present, durable hold, so an absent hold with no answer evidence keeps failing the gate.
The hold must be proven gone, and that takes a `tasks-axi` `NOT_FOUND` read out of a backlog that is still intact.
`tasks-axi` answers `NOT_FOUND` for a backlog that is missing, empty, or no longer structured exactly as it does for a hold retention trimmed, so a wiped backlog cannot stand in for archival.
Retention only removes entries and leaves the file's section headings behind, so a readable backlog still carrying its `## Done` heading is a real backlog that simply no longer lists this hold.
A backlog that is missing, empty, structurally destroyed, or unreadable fails the gate loudly instead of passing as archival.
A hold answered through the direct `answer`, `resolve`, or `decline` path writes no status line, so once it is archived it is attested through the existing `repair` path.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve`, `answer`, and `decline` subcommands close active holds, while `repair` attests a hold already closed outside the script.
All four require a non-empty captain decision file and record the same resolution block in the hold body with the decision digest, routed identities, and a `Resolution mode:` naming the path.
An exact retry is idempotent, while a changed decision or, for `resolve`, a changed routed-task set is rejected.

The `resolve` subcommand is the routed path and additionally requires at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It clears each dependency edge through tasks-axi and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, and a failed intermediate step leaves the hold open.

The `answer` and `decline` subcommands share one unrouted close implementation and differ only in the `Resolution mode:` they record and the outcome word they print, so neither can drift into a weaker close than the other.
Both record `(none)` as the routed identities and refuse while any task in the same backlog is still blocked by the hold, because releasing routed work without recording it is `resolve`'s job.
Every candidate found in the listing prefilter is confirmed against its own structured record before the refusal is reported.
`answer` exists so the act carrying a captain answer can also be the act that closes its hold; `decline` continues to mean the stronger claim that the answer routes no follow-up work at all.

The `park` subcommand requires the same non-empty captain decision file and appends a numbered deferral cycle with its digest, deferral date, hold kind, optional revisit date, original hold reason, and a lossless base64 payload in the hold body.
The payload is decoded and checked against its digest when the cycle is read, so captain text cannot impersonate record metadata.
It records the cycle before changing the hold kind and records completion afterward, so an exact retry can finish an interrupted transition without creating another cycle.
It then re-holds the same queued identity as `parked`, or as `future` with the supplied revisit date, while preserving the original hold reason after a deferral-date prefix.
Reactivation is a separate tasks-axi captain hold transition, and the next `park` appends another cycle on the same identity without replacing earlier provenance.
It never marks the item Done.

The `repair` subcommand records the resolution block on a hold that was already closed outside the script, such as by a direct `tasks-axi done`, so an origin whose decision was genuinely answered stops failing `verify`.
It refuses a hold that is still actively held, never reopens a closed hold, and never clears a dependency edge, so an unanswered decision keeps blocking teardown until the captain's word closes it.
It also requires the identity to carry the captain-hold provenance that tasks-axi preserves through a close, so an ordinary captain-kind task that was never held cannot be repaired into a resolved decision.

## Answer-time closure

The live status-log decision ledger has always had answer-time closure through `bin/fm-send.sh --resolve-key`: answering a keyed decision closes it in the same act.
The durable hold ledger did not, so an answer could be captured, believed, and even implemented while its hold stayed open, and the captain could then be asked to re-answer a decision already on disk.

"A keyed answer closes its matching hold" is now one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<decision-key>`, answer, and label lines on stdin, maps each key to `<origin-id>-decision-<key>`, and closes it through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch and no knowledge of chat, review decks, or any transport.
A channel's only job is to turn whatever it received into those keyed lines and pipe them in; it never maps keys to holds, builds decision records, chooses between the close paths, or closes a hold itself.
The decision text is a pure function of source, key, answer, and label, which is what makes a replayed delivery an idempotent no-op rather than a rejected different decision.
A key whose hold is absent, already closed, or still blocking routed work is reported as skipped and left for `resolve`, and the command exits nonzero when any key was skipped.

`bind`, `unbind`, and `binding` record which origin a captured-answer source belongs to, for a channel whose answers arrive detached from the origin.
The binding is a private record under `state/decision-bindings/`, and a source with no binding feeds nothing, so the path is opt-in per source.
`bind` deliberately does not require the source to exist yet, so a channel can be bound before it is armed and never produce an answer that has nowhere to go.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.

`bin/fm-send.sh --resolve-key` is the chat channel.
Its existing status-log close is unchanged for a key the status log still owns.
For a key the status log no longer owns it checks whether that key names an active captain hold on the target task, and feeds the answer as one keyed line if so, which is what lets chat answer a decision already transferred to its hold.
A key open in neither ledger is still refused before anything is sent.
Because `complete` closes the live status copy at the moment it transfers a decision to its hold, the two ledgers are the two sides of one transfer and never both own a key at once, so the common path still performs no backlog read.

`bin/fm-procevent.sh` is the captured-result channel, and its wiring is generic.
After capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, so recording the captain's answer cannot retire the notification firstmate needs in order to act on it.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reports the structured choices a review captured and stops there, reading only rows tagged `choice` so freeform captain prose can never forge a decision key.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi hold reasons and hold kinds alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked hold whose task kind and hold kind are both `captain` as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked or deferred captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked or deferred captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.
`GET /captain-holds` is the localhost API's captain-hold query.
`bin/fm-api-server.mjs` owns that JSON contract.

## Verification

Current regression evidence lives in [`verification/decision-hold-lifecycle.md`](verification/decision-hold-lifecycle.md).
