# Decision hold lifecycle verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence for the decision hold lifecycle.
`docs/decision-hold-lifecycle.md` owns the mechanism, and `.agents/skills/decision-hold-lifecycle/SKILL.md` owns the policy.

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Unrouted close-path verification date: 2026-08-13.
Answer-time closure verification date: 2026-08-16.
Captain-deferral verification date: 2026-08-30.
Captain-deferral verification uses tasks-axi 0.2.5.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

Three further regressions cover the close paths that route no work.
A declined decision closes with a recorded answer, satisfies `verify`, leaves Bearings' Captain's Call, and is refused while the hold still blocks routed work.
A hold closed by a direct `tasks-axi done` reproduces the shape that fails `verify` and blocks teardown, and `repair` with a captain decision file clears both.
An unanswered decision still blocks completion and teardown, and neither `decline` nor `repair` can close a hold that is still actively held or supply an answer with a missing or empty decision file.
`repair` also refuses a closed captain-kind task that was never held for the captain.

Three answer-time closure regressions run against the published poll response shape with synthetic `sample` identities.
A bound source whose origin exposes six holds captures one review carrying five structured choices plus one freeform message, and the runner feeds it through a fixture adapter that is not the review adapter, so the regression proves that any bound channel with an `answers` command gets closure.
Four holds whose answers route no work close, the one still blocking routed work is skipped and stays available to `resolve`, and the one whose key appears only inside the freeform prose never closes.
The capture is left unacknowledged throughout, so the wake firstmate needs in order to act on the answers is never retired.
A replayed delivery closes nothing new and is not rejected as a different decision, a source with no binding closes nothing at all, and the `answer` subcommand itself refuses an empty or missing decision file, an absent hold, and a drifted retry.
A separate regression drives the real `fm-send` over a stubbed transport to prove the chat channel reaches the same intake for a decision already transferred to its hold, which the status ledger alone can no longer close.

The captain-deferral regression proves parked and dated retagging, reason and identity preservation, durable provenance, inactive-hold refusal, and successful completion verification.
It also proves that exact `hold` replays preserve parked and future states, exact expired dated retries remain idempotent, and concurrent parking and answering serialize to one durable outcome.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - a declined decision closes with a recorded answer and no routed work
ok - park records deferrals, preserves reasons, supports dates, and keeps the completion gate green
ok - concurrent park and answer keep one serialized decision
ok - a decision closed outside the script is repairable and then clears teardown
ok - an unanswered decision still blocks completion and resists both unrouted close paths
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a bound channel's captured answers close their captain holds at answer time
ok - a channel source with no decision binding closes nothing
ok - the answer path keeps every guard the unrouted close path already had
ok - the chat channel feeds the same keyed-answer intake a captured review does

$ bash tests/fm-api-reads.test.sh
ok - empty home captain queue is an empty list
ok - an ordinary worker needs-decision does not appear on the captain queue
ok - captain queue serves an open named card and hides a resolved one
ok - cards with empty, generic-letter, unmarked, or jargon options are rejected
ok - the recommended option is marked and comes first
ok - a captain hold and card are shown; a worker needs-decision is not
ok - empty home blocked list is an empty list
ok - blocked list returns the fixture blocked task and not a worker decision
ok - empty home rigs is an empty list
ok - rigs returns pools, rungs, and each rung's enabled state
ok - rigs carries the dispatch note, rig pins, and the crew and secondmate pin lines
ok - rigs extras default to empty values when the config files are absent
ok - a symlinked crew-dispatch.json is refused, not read
ok - captain holds retains deferred rows without making them actionable
ok - captain holds is empty, not an error, when tasks-axi is absent
# fm-api-reads.test.sh: all assertions passed

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - an authoritative captain hold surfaces end-to-end
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-send-resolve-key.test.sh
ok - fm-send --resolve-key: the answer send itself closes the open decision
ok - fm-send --resolve-key: a key that is not open refuses loudly before anything is sent
(13 assertions total; the status-log ledger's behavior is unchanged)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
ok - the run abort and the leaked-process reap both complete before the destructive worktree return

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=121 local_links=291

$ git diff --check
(no output)
```
