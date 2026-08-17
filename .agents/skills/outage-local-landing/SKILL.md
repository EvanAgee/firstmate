---
name: outage-local-landing
description: >-
  Agent-only procedure for landing and reconciling green work while GitHub is unreachable.
  Load on a "github-health: down" or "github-health: up" wake, and before landing any outage task locally.
  Owns the outage auto-land decision, the adversarial-review gate, and the sync-on-return steps.
user-invocable: false
metadata:
  internal: true
---

# Landing work during a GitHub outage

This skill is the single procedure owner for keeping delivery moving while GitHub is unreachable.
The detection layer (bin/fm-github-health.sh) owns the `state/.github-down` flag and reports each down/up transition once through the watcher; this skill owns what firstmate does with those reports.

## When to load

- On a "check: github-health: down" wake: GitHub just became unreachable.
- On a "check: github-health: up" wake: GitHub just came back.
- Before landing any task locally while `state/.github-down` is present.

## While GitHub is down

Report the outage to the captain once, in outcomes: GitHub is unreachable, work continues locally, and it will sync when GitHub returns.
Do not report it again on later polls; the transition wake already fired once.

Everything local keeps running: build, test, lint, commit, and local scouts all work without GitHub.
Only pushing, opening or merging a PR, and starting a task whose spec lives in an unread GitHub issue are blocked.
A worker that finishes and cannot push should park with `paused:` (work committed, will land when GitHub returns), never `failed:`.

## Landing a green task locally during the outage

A local fast-forward onto a project's default branch IS a merge, so it lands only what the captain's existing authority already covers.
The delivery mode and yolo posture decide the path, exactly as they do for a normal PR merge.

For a **yolo=on** project, green work AUTO-LANDS by itself during the outage, with no captain hold, only when it passes BOTH gates:

1. The full local no-mistakes gate: the worker runs `no-mistakes axi run --skip push,pr,ci`, which runs every local check (intent, rebase, review, test, typecheck, document, lint) and stops before touching GitHub.
   This is the same pipeline as normal-time, with the three GitHub steps switched off, so the outage checks are identical to the normal local gate.
2. An adversarial review by a SECOND, independent agent.
   Spawn a fresh crewmate or scout through the normal `bin/fm-spawn.sh` path, prompted to ATTACK the change and find defects, reading the diff on the lane branch.
   Keep it a small, well-scoped verifier: no policy layer, no generalized framework.
   Supervise it to a verdict, then relay its report as evidence.

Only when the local gate is green AND that adversarial review clears does firstmate land the change with `bin/fm-merge-local.sh <id> [<lane-branch>] --deferred-checks <list> --adversarial-review-passed <ref>`.
The `--adversarial-review-passed` proof is required: the script refuses a yolo=on outage auto-land without it, so an auto-land can never happen on only one review.
Pass `<ref>` as a durable pointer to the reviewer's report so the ledger records the evidence.

For a **yolo=off** project, the captain still owns the merge.
The worker parks and firstmate asks the captain for the local-land approval, exactly as it would for a PR merge.
Only after the captain's word does firstmate call `bin/fm-merge-local.sh <id>` (no review flag; the captain is the authority).

Regardless of yolo: the merge is fast-forward-only and refuses a diverged branch (have the crewmate rebase), never force-merges, and never touches unlanded work.
The browser end-to-end tests and the accessibility scan cannot run during the outage because GitHub dispatches them even to self-hosted runners; they are deferred and run retroactively on return.
State that thinner-verification caveat to the captain; the adversarial review is the extra safety net for it, not a replacement for those checks.

Each outage landing records one line in the reconciliation ledger `state/outage-landings/<project>.log` (written by `bin/fm-merge-local.sh`): what landed, the before and after default-branch SHAs, the deferred workflows, and the review evidence.
The ledger is a record of what already safely happened; it gates and drives nothing.

## When GitHub comes back

On the "github-health: up" wake, run `bin/fm-outage-sync.sh` to reconcile every ledger entry.
Per landing it fetches origin, fast-forward-pushes local main when it is clean-ahead, dispatches the deferred schedule-only workflows, and clears the entry.
If local and origin main diverged during the outage, it ESCALATES rather than force-pushing: surface that to the captain as landings that need rebasing before they can go up.
It is idempotent, so a re-run after a successful sync is a safe no-op.
When a landing's commit is already on origin (a re-run, or a second landing whose push carried it up), its deferred checks are not auto-dispatched to avoid double-firing; the script says so once, and firstmate dispatches them by hand only if they truly never ran.
A retroactive check that now fails on main is a real red-on-main situation to fix forward, surfaced loudly, because the code landed before that check could run.

## Owners

- `bin/fm-github-health.sh --help` owns the probe, the flag, and the transition contract.
- `bin/fm-merge-local.sh --help` owns the local-landing guards, the outage gate, the review gate, and the ledger format.
- `bin/fm-outage-sync.sh --help` owns the sync-on-return steps, the divergence refusal, and idempotency.
- `data/outage-local-merge-design/` and its `captain-decision.md` record the design and the auto-land decision.
