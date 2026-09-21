# Upstream rebase, Phase C: put the fork back on the root

Captain 2026-09-21: "Start C. option 1", then "Root".
Option 1 means: take upstream main as the new base and re-apply this fork's own features on top as ports, one worker per feature, each on its own branch, integrated on a branch that never touches the live home until a shakedown passes.
This spec is the dispatch contract for that work.
Phases A1 and A2 are recorded in `docs/specs/upstream-port-pool-sweep.md`; A1 landed, A2 folds in here.

## The three repos

| Repo | Role | Measured 2026-09-21 |
| --- | --- | --- |
| `kunchenguid/firstmate` (remote `kun`) | the root; 5 to 8 commits a day, PR #5114 landed 2026-09-21 | 298 commits we lack, 105 of ours it lacks, 138 conflicting files, merge base `e518906a` 2026-08-16 |
| `dnth/firstmate` (remote `dnth`) | a fork of the root cut at #1709 on 2026-08-04, never pulled since | 365 behind the root, 188 own commits, 81 of them OMP |
| `EvanAgee/firstmate` (`origin`) | this fork: dnth's OMP merge (#64, 2026-08-28) plus the root through 2026-08-16 plus about 105 own commits | live fleet home at `/Users/evanagee/Sites/firstmate` |

The base is `kun/main`.
dnth's extras (acceptance receipts, treehouse pool sweep, durable task inbox #151, the deeper OMP work) are optional ports on the same footing as our own features; none is required for the swap.

## Shape of the work

- Integration branch `c/main` in this repo, cut from `kun/main` and pushed to `origin`. It is the future `main`.
- Every port is a ship task on a branch off `c/main`, landed into `c/main` by firstmate with `bin/fm-merge-local.sh` (local-only mode, no PR), after firstmate reads the diff and the port's test proof.
- Nothing lands on `main` and nothing touches the live home until the shakedown ticket passes.
- The trial home at `/Users/evanagee/Sites/firstmate-trial` runs `c/main` for the shakedown. It has no live fleet work; its state from the September trial is scratch.
- Workers take pooled worktrees of this repo (`~/.treehouse/firstmate-*`), never the live checkout, never the trial home.
- Every port carries `firstmate-coding-guidelines` (shared tracked material) and the upstream repo's own test conventions: colocated `tests/*.test.sh`, shellcheck-clean `bin/`, one sentence per line in docs.
- A port re-implements the feature's behavior on the root's current code; it does not cherry-pick our commits. Our commits and files are the reference, the root's structure is the target. Where the root already grew an equivalent, the port adopts the root's version and records what changed in the ticket.

## Inventory: what the fork carries that the root does not

Derived from `git log --cherry-pick --right-only kun/main...origin/main` (105 commits) and `git diff --name-only --diff-filter=A kun/main origin/main`.
Each row is one ticket unless noted.

| Ticket | Feature | Reference files in this fork | Root has it? |
| --- | --- | --- | --- |
| C0 | Foundation: `c/main` from the root, the root's suite green on this Mac, tool floors met, trial home switched | none | n/a |
| C1 | Claude Stop-hook supervision: watcher coordinator, notifier, anchor, beat alarm, wedge two-signal, turn-end guard deltas, `docs/supervision-protocols/claude.md`, `docs/watcher-continuity.md` | `bin/fm-claude-watch-coordinator.sh`, `bin/fm-claude-watch-notifier.sh`, `bin/fm-anchor-lib.sh`, `bin/fm-watcher-beat-alarm.sh`, `bin/fm-watcher-beat-alarm-install.sh`, `bin/fm-wedge-alarm-lib.sh`, `bin/fm-supervision-env-lib.sh`, `tests/fm-watch-*.test.sh`, `tests/fm-wake-drain-anchor.test.sh` | the root has its own Claude arm loop; this is the re-architecture and needs the trial-home shakedown |
| C2 | Deterministic dispatch: class pools with enable/pause/quarantine, round-robin, provider-availability admission, route refresh and its launchd install, `config/crew-dispatch.json` shape, `docs/provider-availability-routing.md` | `bin/fm-dispatch-resolve.sh` (diff), `bin/fm-dispatch-validate.sh`, `bin/fm-dispatch-runtime-lib.sh`, `bin/fm-route.sh`, `bin/fm-route-refresh-install.sh`, `docs/examples/crew-dispatch.json`, `.agents/skills/quota-array-dispatch/SKILL.md` | root has `fm-dispatch-resolve.sh` with a judgment-driven contract; ours is deterministic by captain rule 2026-08-30 and wins |
| C3 | Local fleet API and captain board: server, reads, task detail, events stream, write token, captain queue cards, delivery record, token ledger | `bin/fm-api.sh`, `bin/fm-api-server.mjs`, `bin/fm-api-reads.mjs`, `bin/fm-api-task-detail.mjs`, `bin/fm-captain-queue.sh`, `bin/fm-delivery-record.sh`, `bin/fm-delivery-backfill.sh`, `bin/fm-token-ledger.sh`, `tests/fm-token-ledger.test.sh`, `docs/configuration.md` "Local API" and "Token ledger" | no; agee.dev/fleet depends on this |
| C4 | PR flow and landings: auto-arm merge watch, reviewer chase, unresolved-thread and captain-approved merge guards, issue close after merge, GitHub-health outage landing and sync, the per-project fast/full flow switch | `bin/fm-pr-autoarm.sh`, `bin/fm-pr-review-chase.sh`, `bin/fm-pr-merge.sh` (diff), `bin/fm-issue-close-after-merge.sh`, `bin/fm-issue-guard-lib.sh`, `bin/fm-github-health.sh`, `bin/fm-outage-sync.sh`, `bin/fm-flow.sh`, `bin/fm-merge-local.sh` (diff), `.agents/skills/outage-local-landing/SKILL.md` | root has `fm-merge-local.sh` and `fm-pr-merge.sh`; the rest is ours |
| C5 | Ship-brief rules and review loop: Matt flow entry, unslop gate, walked-path proof, PR feedback until landed, 1Password ban, caveman and ponytail launch, cd steer, stall rules, review-loop stop, bakeoff skill, vendored skills and lock | `bin/fm-brief.sh` (diff), `bin/fm-spawn.sh` (launch-skill part of the diff), `bin/fm-review-loop-stop.sh`, `bin/fm-skills-lock.sh`, `skills-lock.json`, `.agents/skills/review-loop-stop`, `.agents/skills/bakeoff`, the 85 fork-only skill files | no |
| C6 | Harness deltas the root lacks: OMP capabilities and process lib, Pi-compatible runtimes, primary watch core, chrome-devtools pin | `bin/fm-omp-capabilities.sh`, `bin/fm-omp-process-lib.sh`, `bin/fm-pi-compatible-lib.sh`, `bin/fm-pi-compatible-runtimes`, `bin/fm-primary-watch-core.ts`, `bin/fm-primary-watch-version-lib.sh`, `bin/fm-chrome-devtools-axi-lib.sh`, `bin/fm-chrome-devtools-mcp.js` | root has native OMP (149 references in its `fm-spawn.sh`); the ticket measures the gap first and ports only what the root lacks |
| C7 | CI: unslop gate on new findings, portable serial shards with the job-cap guard, cancel superseded runs | `.github/workflows/unslop.yml`, `.github/workflows/ci.yml` (diff), `docs/fm-test-portable-shards.md` | no |
| C8 | dnth extras, optional, after C1 to C7: treehouse pool sweep (A1, already ported here), receipts (A2 costing in `data/fm-upstream-a2-receipts-cost/report.md`), durable task inbox (#151) | `bin/fm-treehouse-sweep.sh`, `bin/fm-pool-lib.sh`, `bin/fm-treehouse-root-lib.sh`, `bin/fm-homes-lib.sh` | no |
| C9 | Shakedown and swap: run the trial home on `c/main` as a real fleet for one day of scratch work, then the swap plan for the live home | `docs/specs/upstream-rebase.md` (this file), `data/` migration notes | n/a |

Small fixes in the 105 that ride along with their feature's ticket rather than standing alone: stalled-validation wake (#119) and tmux relaunch after endpoint loss (#120) go with C1; Bash 3.2 status-scan speed (#77), mid-note decision keys (#71), scout cleanup after an archived decision (#90), machine-unsupported suite skips (#86) go with C0's baseline if the root still has the defect, else are dropped; pi launches under repo Node pins (#20) goes with C6; herdr husk relaunch (#11) goes with C1.

## Ordering and parallelism

C0 first, alone.
Then C1, C2, C5, C7 in parallel: their file sets do not overlap.
C3 after C2 lands (it reads the dispatch config shape).
C4 and C6 after C0, in parallel with the others; C4 touches `fm-pr-merge.sh` and `fm-merge-local.sh`, which no other ticket edits.
C8 only after C1 to C7 are on `c/main`.
C9 last.
Every ticket branches from the current `c/main` at its start and rebases onto it before landing.
The six-worker cap counts these lanes.

## Definition of done for a port ticket

1. The feature's behavior works on the root's code, proven by the fork's own tests carried over and adapted (never deleted) plus red tests for anything the root's structure forced to change.
2. `tests/` for the touched files pass in the worktree; the full `bin/fm-test-run.sh` (or the root's equivalent, see C0) once before the ready signal.
3. shellcheck clean on every touched `bin/*.sh`.
4. A `## What I walked` section in the ready report showing the feature exercised live in a throwaway `FM_HOME` (a scratch home under the worktree, never the live home or the trial home), with the commands and their output.
5. The ticket body on the backlog names what the root already had, what was adopted from the root instead of ported, and what was dropped.
6. Commits reference `Refs #<firstmate issue>` when the port maps to an existing issue.

## What C0 must establish before any port starts

- `c/main` exists on `origin`, equal to `kun/main` at a recorded SHA.
- The root's test runner and its shard layout are understood and written down here under a "Running the suite" section, with the exact commands and this Mac's baseline result (which tests fail on the root as-is, and why).
- Tool floors the root demands (`bin/fm-bootstrap.sh` on `kun/main`) are met or listed as blockers with versions.
- The trial home is on `c/main` with `origin` pointed at this fork, its September trial state cleared to a recorded archive under `data/` of the trial home, and `bin/fm-session-start.sh` there completes a locked digest.
- The 138 conflicting files are listed by ticket so each port worker knows which root files it will be rewriting.

## Out of scope

- Any change to the live home's `main` or its running supervision before C9.
- Merging `dnth/main` wholesale.
- Adopting the root's judgment-driven dispatch contract; the captain's 2026-08-30 rule stands.
- Renaming or restructuring the root's scripts to match ours; the root's layout wins on layout.
