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
- The trial home at `/Users/evanagee/Sites/firstmate-trial` runs `c/main` for the shakedown. It had no live fleet work at switch time; its state was archived rather than cleared, because a later trial fleet's records had accumulated past the September trial.
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

### Handover for the trial home

The trial home at `/Users/evanagee/Sites/firstmate-trial` runs `c/main` for the shakedown.
It is a separate clone of `dnth/firstmate` whose `origin` is re-pointed at this fork and whose checkout is `c/main`.
The switch ran on 2026-09-23, from the disposable C0 worktree rather than from either home; the original brief reserved it for firstmate, and firstmate delegated it to that worktree in the relaunch that followed.
The commands below stay the recipe, and each step records what it actually produced.

1. Publish the integration branch, because the trial home can only fetch a branch that exists on a remote.
   `git -C /Users/evanagee/Sites/firstmate push origin c/main:c/main`
   Confirm the remote carries the recorded SHA:
   `git -C /Users/evanagee/Sites/firstmate ls-remote origin refs/heads/c/main`
   No push was needed at switch time: `origin` already carried `c/main` at `0491f54ccdb54c8e84b7546569ffac9982e4992e`, three landing commits ahead of this clone's `c/main` ref at `3425dd1f` (`cbf0c2eb`, `a1634b53`, `0491f54c`); the published branch had moved on while the shared local ref stayed where it was, so the trial home fetched the publication rather than the local ref.
   That SHA supersedes the `43bf6d3d9e5384cc02557929be220e03477d3068` recorded when C0 started, and the trial home runs the newer tip.

2. Re-point the trial home's `origin` at this fork and fetch.
   `git -C /Users/evanagee/Sites/firstmate-trial remote set-url origin https://github.com/EvanAgee/firstmate`
   `git -C /Users/evanagee/Sites/firstmate-trial fetch origin`
   `git -C /Users/evanagee/Sites/firstmate-trial rev-parse origin/c/main` then prints `0491f54ccdb54c8e84b7546569ffac9982e4992e`.

3. Archive the trial state into a recorded directory under the trial home's own `data/`, before the checkout changes what `state/` and `data/` mean.
   `mkdir -p /Users/evanagee/Sites/firstmate-trial/data/archive-2026-09-trial`
   Move every `state/` and every `data/` entry except the archive directory itself into it, hidden entries included:
   `(cd /Users/evanagee/Sites/firstmate-trial && shopt -s dotglob && for f in state/*; do [ -e "$f" ] && mv "$f" data/archive-2026-09-trial/; done)`
   `(cd /Users/evanagee/Sites/firstmate-trial && shopt -s dotglob && for f in data/*; do [ "$f" = data/archive-2026-09-trial ] || mv "$f" data/archive-2026-09-trial/; done)`
   `shopt -s dotglob` is load-bearing: the trial home's `state/` is almost entirely hidden files, so the plain `state/*` glob in the first version of this recipe would have left them behind.
   The archive holds 311 entries: 266 state records, 44 data records, and a `MANIFEST.txt` naming the pre-switch HEAD (`a6f5d0e`, `dnth`'s `main`), the pre-switch `origin`, and those counts.
   The state was larger than the 14 and 18 records of the September trial because a later trial fleet had accumulated its own backlog, captain notes, and per-task reports here.
   The trial home's `state/` and `data/` are then empty except that archive directory.

4. Check out `c/main` and confirm the recorded SHA.
   `git -C /Users/evanagee/Sites/firstmate-trial checkout -B c/main origin/c/main`
   `git -C /Users/evanagee/Sites/firstmate-trial log -1 --format=%H` prints `0491f54ccdb54c8e84b7546569ffac9982e4992e`, on a clean working tree, with the local `main` ref left at its pre-switch commit.

5. Start the trial home and confirm a locked digest.
   Run session start inside the trial home with `FM_HOME` set to it, from the trial home directory, so the digest's lock step reports the home's own session lock held and its fleet-state digest lists no tasks:
   `(cd /Users/evanagee/Sites/firstmate-trial && FM_HOME=/Users/evanagee/Sites/firstmate-trial bin/fm-session-start.sh)`
   The digest named `/Users/evanagee/Sites/firstmate-trial`, reported `lock acquired: harness pid 40972`, listed `(none)` under work under way, `ABSENT` for `data/backlog.md`, no orphan status logs, and `AFK absent`, and its deferred stage completed the network checks off the blocking path.
   It started the trial home's own local fleet API and wrote a fresh `state/` of session records.

6. Record the switch: the trial home runs `c/main` at `0491f54c`, its trial state is archived at `data/archive-2026-09-trial/` with its manifest, and its `origin` is this fork.

Three lines from that digest are worth a later shakedown session's attention; none of them blocked the switch or the digest.

- `TANGLE: primary checkout on feature branch 'c/main' (expected 'main')`.
  `c/main` is a named branch that is not the clone's default branch, and `bin/fm-tangle-lib.sh` alarms on exactly that in a primary checkout, whose stated remedy is `git -C <root> checkout main` - which would undo this switch.
  The same library documents detached HEAD as the legitimate off-default posture for every non-primary checkout, so `git -C /Users/evanagee/Sites/firstmate-trial checkout --detach origin/c/main` pins the same commit silently and is a one-command alternative to the named branch left in place here.
  The alarm is advisory: it prints a banner on fleet actions and never blocks a spawn, a sweep, or the digest.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs non-empty class`.
  The trial home keeps a `config/crew-dispatch.json` from the old fork whose rules carry `when` and `use` and no `class`, which `bin/fm-dispatch-validate.sh` on `c/main` rejects.
  `config/` is deliberately outside the archive step, so that file survived the switch untouched and still governs dispatch in the trial home.
- `FLEET_SYNC: agee-dev-dashboard: skipped: not a clone root`.
  `projects/agee-dev-dashboard` holds no `.git`, so the fleet sync refuses it and git commands there would act on the trial home itself, which is why the sync reported that it would act on the home.

### The rideable fixes from the inventory paragraph

The inventory paragraph names four small fixes that ride along with C0 when the root still has the defect.
Each was checked against the root and handled as follows.

- `#77` Bash 3.2 status-scan speed: dropped.
  The root already carries this fix from `kunchenguid/firstmate#3273`; its `_fm_decision_fold_line` already answers the blank-line question with a `case` glob instead of the slow `${line//[[:space:]]/}` substitution.
- `#71` mid-note decision keys: ported as its own commit.
  The root still folded a `needs-decision` or `blocked` line whose key sat inside the note to `default`, so the drain printed one key while `fm-send --resolve-key` refused the very key it printed; the fold now accepts the single canonical interior token, its fork tests were adapted, and the fold version bumped to 10.
- `#90` scout cleanup after an archived decision: ported as its own commit.
  The root still failed its completion gate once an answered captain-held task was dropped from the backlog by Done-history retention; a close now records a durable answered entry in the origin metadata, and verify tolerates a not-found entry only when that record names it.
- `#86` machine-unsupported suite skips: the calm-export half ported, the OMP half not applicable.
  On this Mac the export DOM assertion failed because the Homebrew `chromium` wrapper points at an absent `/Applications/Chromium.app`; the assertion now renders a minimal control page first and skips only itself when the browser cannot render. The other half of that fork commit moves OMP launch-shape evidence into `bin/fm-omp-process-lib.sh` and rewrites `tests/fm-omp-detection.test.sh`; neither file exists on the root, whose native OMP ancestry probe lives in `bin/fm-harness.sh`, so nothing there applies.

## Conflict map

`git merge-tree --write-tree c/main origin/main` reports 138 conflicting files between the root and this fork.
Every one is assigned below to the ticket whose feature owns its reconciliation, using the inventory table above.
A file goes to the ticket that must rewrite that behavior on the root, not to the ticket that first added it in this fork.
C1 owns the largest share because the root itself has a Claude supervision loop, so the whole supervision and runtime-backend surface lands on one ticket.

| Ticket | Feature | Conflicting files |
| --- | --- | --- |
| C1 | Claude Stop-hook supervision | 83 |
| C2 | Deterministic dispatch | 8 |
| C3 | Local fleet API and captain board | 4 |
| C4 | PR flow and landings | 9 |
| C5 | Ship-brief rules and review loop | 6 |
| C6 | Harness deltas the root lacks | 17 |
| C7 | CI | 5 |
| C8 | dnth extras (optional) | 0 |
| none | cross-cutting integration surface | 6 |
| total | | 138 |

C8 owns no conflicting file: the dnth extras it ports (`fm-treehouse-sweep.sh`, `fm-pool-lib.sh`, `fm-treehouse-root-lib.sh`, `fm-homes-lib.sh`) exist on only one side of the merge, so none of them conflicts.
The six files that fit no ticket are `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, `docs/architecture.md`, `docs/documentation-audiences.json`, and `docs/scripts.md`.
They are the shared instruction, README, and reference-index surfaces that every ticket edits, so their reconciliation belongs to the integration step that lands C1 to C7 onto `c/main`, not to any one port ticket.
Two files are shared by more than one feature and are assigned to their primary owner with that noted: `docs/configuration.md` to C3 (it owns the Local API and Token ledger sections, and C3 reconciles the rest), and `bin/fm-classify-lib.sh` to C1 (the open-decisions and status-scan code C1 depends on).

| File | Ticket |
| --- | --- |
| `.agents/skills/afk/SKILL.md` | C1 |
| `.agents/skills/bootstrap-diagnostics/SKILL.md` | C1 |
| `.agents/skills/decision-hold-lifecycle/SKILL.md` | C1 |
| `.agents/skills/harness-adapters/SKILL.md` | C6 |
| `.agents/skills/process-event-sources/SKILL.md` | C1 |
| `.agents/skills/quota-array-dispatch/SKILL.md` | C2 |
| `.github/workflows/ci.yml` | C7 |
| `.github/workflows/no-mistakes-required.yml` | C7 |
| `.pi/extensions/fm-primary-pi-watch.ts` | C6 |
| `.pi/extensions/fm-primary-turnend-guard.ts` | C1 |
| `AGENTS.md` | none |
| `CONTRIBUTING.md` | none |
| `README.md` | none |
| `bin/backends/herdr.sh` | C1 |
| `bin/backends/tmux.sh` | C1 |
| `bin/fm-afk-launch.sh` | C1 |
| `bin/fm-backend.sh` | C1 |
| `bin/fm-bootstrap.sh` | C1 |
| `bin/fm-brief.sh` | C5 |
| `bin/fm-busy-lib.sh` | C6 |
| `bin/fm-classify-lib.sh` | C1 |
| `bin/fm-claude-stop-autoarm.sh` | C1 |
| `bin/fm-composer-lib.sh` | C1 |
| `bin/fm-control-lib.sh` | C1 |
| `bin/fm-control.sh` | C1 |
| `bin/fm-crew-state.sh` | C1 |
| `bin/fm-decision-hold.sh` | C1 |
| `bin/fm-dispatch-resolve.sh` | C2 |
| `bin/fm-ensure-agents-md.sh` | C5 |
| `bin/fm-fleet-snapshot.sh` | C3 |
| `bin/fm-guard.sh` | C1 |
| `bin/fm-harness.sh` | C6 |
| `bin/fm-lock.sh` | C1 |
| `bin/fm-merge-local.sh` | C4 |
| `bin/fm-nm-run-lib.sh` | C4 |
| `bin/fm-pr-check-migrate.sh` | C4 |
| `bin/fm-pr-check.sh` | C4 |
| `bin/fm-pr-lib.sh` | C4 |
| `bin/fm-pr-merge.sh` | C4 |
| `bin/fm-procevent-lavish.sh` | C1 |
| `bin/fm-procevent.sh` | C1 |
| `bin/fm-remote-entrypoint.sh` | C1 |
| `bin/fm-remote-home-seed.sh` | C1 |
| `bin/fm-send.sh` | C1 |
| `bin/fm-session-lock-lib.sh` | C1 |
| `bin/fm-session-start.sh` | C1 |
| `bin/fm-spawn.sh` | C5 |
| `bin/fm-supervise-daemon.sh` | C1 |
| `bin/fm-supervision-instructions.sh` | C1 |
| `bin/fm-supervision-lib.sh` | C1 |
| `bin/fm-tasks-axi-lib.sh` | C1 |
| `bin/fm-teardown.sh` | C1 |
| `bin/fm-test-run.sh` | C7 |
| `bin/fm-tmux-lib.sh` | C1 |
| `bin/fm-turnend-guard.sh` | C1 |
| `bin/fm-wake-drain.sh` | C1 |
| `bin/fm-wake-lib.sh` | C1 |
| `bin/fm-watch.sh` | C1 |
| `docs/agent-control.md` | C1 |
| `docs/architecture.md` | none |
| `docs/arm-pretool-check.md` | C1 |
| `docs/cd-guard.md` | C5 |
| `docs/configuration.md` | C3 |
| `docs/decision-hold-lifecycle.md` | C1 |
| `docs/documentation-audiences.json` | none |
| `docs/examples/crew-dispatch.json` | C2 |
| `docs/fm-test-portable-shards.md` | C7 |
| `docs/gitlab-merge-watch.md` | C4 |
| `docs/herdr-backend.md` | C1 |
| `docs/remote-secondmates.md` | C1 |
| `docs/scripts.md` | none |
| `docs/sessionstart-nudge.md` | C1 |
| `docs/supervision-protocols/claude.md` | C1 |
| `docs/supervision-protocols/omp.md` | C6 |
| `docs/supervision-protocols/pi.md` | C6 |
| `docs/tmux-backend.md` | C1 |
| `docs/trace-context.md` | C1 |
| `docs/turnend-guard.md` | C1 |
| `docs/verification/dispatch-auth.md` | C2 |
| `docs/verification/process-event-sources.md` | C1 |
| `docs/verification/runtime-backends.md` | C6 |
| `docs/verification/supervision.md` | C1 |
| `docs/watcher-continuity.md` | C1 |
| `tests/fm-backend-herdr.test.sh` | C1 |
| `tests/fm-bearings-snapshot.test.sh` | C3 |
| `tests/fm-bootstrap.test.sh` | C1 |
| `tests/fm-brief.test.sh` | C5 |
| `tests/fm-busy-adapter-wiring.test.sh` | C6 |
| `tests/fm-calm-pi-extension.test.sh` | C6 |
| `tests/fm-classify-decision-key.test.sh` | C1 |
| `tests/fm-claude-stop-autoarm-live-e2e.test.sh` | C1 |
| `tests/fm-claude-stop-autoarm.test.sh` | C1 |
| `tests/fm-composer-lib.test.sh` | C1 |
| `tests/fm-control-herdr-smoke.test.sh` | C1 |
| `tests/fm-control-relaunch.test.sh` | C1 |
| `tests/fm-control.test.sh` | C1 |
| `tests/fm-crew-state.test.sh` | C1 |
| `tests/fm-cursor-harness.test.sh` | C6 |
| `tests/fm-daemon.test.sh` | C1 |
| `tests/fm-decision-hold-lifecycle.test.sh` | C1 |
| `tests/fm-dispatch-resolve.test.sh` | C2 |
| `tests/fm-ensure-agents-md.test.sh` | C5 |
| `tests/fm-fleet-snapshot-view.test.sh` | C3 |
| `tests/fm-gate-refuse.test.sh` | C1 |
| `tests/fm-gotmp.test.sh` | C1 |
| `tests/fm-grok-harness.test.sh` | C6 |
| `tests/fm-guard-stale-banner.test.sh` | C1 |
| `tests/fm-inactive-reconcile.test.sh` | C1 |
| `tests/fm-kimi-harness.test.sh` | C6 |
| `tests/fm-omp-harness.test.sh` | C6 |
| `tests/fm-omp-primary-live-e2e.test.sh` | C6 |
| `tests/fm-on.test.sh` | C1 |
| `tests/fm-pi-primary-types.test.sh` | C6 |
| `tests/fm-pi-watch-extension.test.sh` | C6 |
| `tests/fm-pr-check-security.test.sh` | C4 |
| `tests/fm-pr-merge.test.sh` | C4 |
| `tests/fm-quota-array-dispatch-live-e2e.test.sh` | C2 |
| `tests/fm-remote-job.test.sh` | C1 |
| `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` | C1 |
| `tests/fm-secondmate-harness.test.sh` | C6 |
| `tests/fm-secondmate-lifecycle-e2e.test.sh` | C1 |
| `tests/fm-send-popup-settle.test.sh` | C1 |
| `tests/fm-send-resolve-key.test.sh` | C1 |
| `tests/fm-send-strict.test.sh` | C1 |
| `tests/fm-session-lock-ancestry.test.sh` | C1 |
| `tests/fm-spawn-dispatch-profile.test.sh` | C2 |
| `tests/fm-spawn-pool-base-freshen.test.sh` | C2 |
| `tests/fm-supervision-instructions.test.sh` | C1 |
| `tests/fm-tangle-guard.test.sh` | C1 |
| `tests/fm-teardown.test.sh` | C1 |
| `tests/fm-test-run.test.sh` | C7 |
| `tests/fm-turnend-guard.test.sh` | C1 |
| `tests/fm-wake-queue.test.sh` | C1 |
| `tests/fm-watch-arm.test.sh` | C1 |
| `tests/fm-watch-triage.test.sh` | C1 |
| `tests/fm-watcher-lock.test.sh` | C1 |
| `tests/secondmate-helpers.sh` | C1 |
| `tests/wake-helpers.sh` | C1 |

## Running the suite

`bin/fm-test-run.sh` is the root's single test runner; its own header owns every mode, flag, and marker line.
Its selection mode `--all` runs the complete behavior suite, 219 scripts, strictly serially.
That count belongs to the C0-time base: the C0 worktree at `44754565` and the `c/main` it branched from print 219 script paths, while the published `c/main` at `0491f54c` that the trial home now runs prints 249, because the port tickets landed 30 further test scripts after this baseline was measured.
CI never runs `--all`; `.github/workflows/ci.yml` splits the same suite into these jobs:

| CI job | Command | What it runs |
| --- | --- | --- |
| `lint` | `bin/fm-lint.sh --partition <k>of2` | ShellCheck over `bin/*.sh`, `bin/backends/*.sh`, and `tests/*.sh`, plus workflow lint, in two partitions |
| `test-coverage` | `bin/fm-test-run.sh --check-coverage` | Proves the portable lanes plus the Herdr family equal the whole `tests/*.test.sh` inventory with no gap or duplicate |
| `tests-portable-parallel-1` | `bin/fm-test-run.sh --lane portable-parallel-1 --fail-on-gate-skip 'Pi extension typecheck prerequisite not found'` | The first duration-balanced half of the proven-isolated set |
| `tests-portable-parallel-2` | `bin/fm-test-run.sh --lane portable-parallel-2` | The second duration-balanced half |
| `tests-portable-serial` | `FM_SERIAL_LANE=portable-serial-<k>of9 bin/fm-test-run.sh --lane "$FM_SERIAL_LANE" --fail-on-gate-skip 'Pi extension typecheck prerequisite not found'` | The stateful remainder, split across nine separate runners, each shard serial in itself |
| `tests-herdr` | `bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip 'herdr not found'` | The pinned real-Herdr family, serial, after a pinned Herdr and Treehouse install |

`bin/fm-test-run.sh --list-lanes` prints the lane names, and `--list --all` prints the 219 script paths.
A single script runs as `bin/fm-test-run.sh tests/<name>.test.sh`, which is how every failure below was re-run alone.
Every script prints `FM_TEST_BEGIN` and `FM_TEST_END` markers, and the runner ends with one `FM_TEST_SUMMARY` line; `--json <path>` writes a deterministic per-script timing artifact.

The complete local run on this Mac, from a clean `c/main` worktree, was `bin/fm-test-run.sh --all`, which measured:

    FM_TEST_SUMMARY total=219 failed=18 skipped_gate=28 duration_ms=14813624

That is 4 hours 7 minutes of wall clock (13:04:21 to 17:11:14 on 2026-09-21), on a Mac that was already carrying a load average near 40 from the live fleet and other captain work, so the timing is an upper bound rather than a clean-machine measurement; 28 of the 219 scripts gate-skipped for the reasons the runner prints (live harness opt-in not set, `cmux` not installed, and the like).
The baseline below therefore describes the pre-port suite; no full run of the 249-script suite on today's `c/main` has been recorded.

Eighteen scripts failed.
Each was then re-run alone in the same clean `c/main` worktree; the table records whether it passed alone and the classification the brief asks for.

| Test | Full run | Alone | Reason |
| --- | --- | --- | --- |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | failed (902s) | failed (1025s) | root defect: "concurrent primary recovery failed ... herdr presentation recovery could not acquire its session lock; refusing a concurrent resume" |
| `tests/fm-secondmate-harness.test.sh` | failed (230s) | failed (221s) | root defect: "first config push did not reach pointer delivery" |
| `tests/fm-harness-liveness-drift-live-e2e.test.sh` | failed (124s) | failed (128s) | this-machine environment: the installed Kimi 1.5 reports its process title as `Python`, which the detector classifies `ambiguous` |
| `tests/fm-backlog-atomicity.test.sh` | failed (121s) | failed (150s) | root defect: "a timed-out verification did not report the preservation as attempted, not verified" |
| `tests/fm-claude-stop-autoarm.test.sh` | failed (62s) | failed (63s) | root defect: "failure must exhaust exactly two bounded arm attempts" |
| `tests/fm-composer-codex-idle-live-e2e.test.sh` | failed (53s) | failed (57s) | this-machine environment: codex-cli 0.154.0 idle screen is not classified empty |
| `tests/fm-calm-pi-extension.test.sh` | failed (31s) | failed (37s) | this-machine environment: the Homebrew `chromium` wrapper points at an absent `/Applications/Chromium.app`, so the export DOM cannot render (ported fix below) |
| `tests/fm-wake-queue.test.sh` | failed (29s) | passed (152s) | load |
| `tests/fm-turnend-guard.test.sh` | failed (27s) | failed (20s) | root defect: "healthy no-supervision-needed native stop must allow: expected exit 0, got 2" |
| `tests/fm-control-herdr-smoke.test.sh` | failed (20s) | failed (5s) | this-machine environment: Herdr 0.9.0 differs from the CI pin 0.7.4 |
| `tests/fm-lint.test.sh` | failed (9s) | passed (154s) | missing tool: `actionlint` was absent; installed, then it passes |
| `tests/fm-remote-doctor.test.sh` | failed (8s) | failed (6s) | this-machine environment: `--fix` cannot ready a host whose launch-agent install is not permitted here |
| `tests/fm-watcher-lock.test.sh` | failed (8s) | failed (9s) | root defect: "guard repair line did not source the X-mode cadence config" |
| `tests/fm-secondmate-liveness.test.sh` | failed (8s) | failed (5s) | this-machine environment: Herdr 0.9.0 returns `missing` where the pinned version returns `unknown` |
| `tests/fm-backend-herdr-prune-safety-e2e.test.sh` | failed (5s) | passed (10s) | load (the live heartbeat marker never started under the full run's load) |
| `tests/fm-arm-pretool-check.test.sh` | failed (5s) | failed (5s) | root defect: "A13 via codex must allow, got exit 2" |
| `tests/fm-remote-herdr-guard.test.sh` | failed (0.8s) | failed (0.7s) | this-machine environment: macOS hides a platform binary's environment, and `/usr/bin/jq` is a platform binary |
| `tests/fm-lint-workflows.test.sh` | failed (0.4s) | passed (5s) | missing tool: `actionlint`; installed, then it passes |

Two of the failures are addressed by this ticket's rides: the `actionlint` install clears both lint failures, and the ported `#86` calm-page skip clears `fm-calm-pi-extension` on this Mac.
Thirteen scripts still fail alone after those two fixes: seven are root defects and six are this-machine tool or platform differences, listed here so a later ticket can pick them up rather than fixed in C0.
The machine had Herdr 0.9.0 and codex-cli 0.154.0 installed while CI pins Herdr 0.7.4, which is the whole difference behind three of the six environment failures.

## Out of scope

- Any change to the live home's `main` or its running supervision before C9.
- Merging `dnth/main` wholesale.
- Adopting the root's judgment-driven dispatch contract; the captain's 2026-08-30 rule stands.
- Renaming or restructuring the root's scripts to match ours; the root's layout wins on layout.
