---
tags: [upstream, rebase, phase-c, shakedown, swap]
date: 2026-09-23
---

# Upstream rebase, Phase C: put the fork back on the root

Captain 2026-09-21: "Start C. option 1", then "Root".
Option 1 takes `kunchenguid/firstmate` main (remote `kun`) as the new base and re-applies this fork's features on top as ports, one worker per feature, integrated on `c/main` and shaken down in `/Users/evanagee/Sites/firstmate-trial` before any swap of the live home.
This revision, dated 2026-09-23, puts the remaining work in the hardened spec shape.
The ports already on `c/main` are listed under Done as history and are not acceptance work.
Phases A1 and A2 are recorded in `docs/specs/upstream-port-pool-sweep.md`.

## Problem Statement

The live home at `/Users/evanagee/Sites/firstmate` runs this fork's `main`.
That branch left the root on 2026-08-16 and was 298 commits behind it on 2026-09-21, with 138 conflicting files.
Every root fix the fleet wants costs a hand port, and the root adds 5 to 8 commits a day.
The integration branch `c/main` now carries the root plus ports C0 to C7, and its CI is green, but the live home cannot move to it yet.
Three gaps remain.
First, the fork kept shipping.
Since this spec was first committed (`40094579`, 2026-09-21), 25 commits on `main` touched `bin/`, `tests/`, `.agents/`, `.github/`, or `AGENTS.md`, and `c/main` has not taken them.
The dnth pool sweep that the live fleet runs was never ported either.
Second, `c/main` has never run real fleet work.
The trial home switched to it on 2026-09-23 with an empty backlog, and its digest still prints a dispatch-config fault and a tangle alarm.
Third, there is no swap recipe for the live home, and no rollback if the swapped home fails.

## Solution

The remaining work runs in four steps, in this order.

1. Port what `c/main` still lacks: the pool sweep (ticket C8) and every commit in the drift ledger below, each under the port-ticket definition of done in Decisions.
2. Carry this spec onto `c/main`, because C8, C9, and drift-port worktrees branch from `c/main` and read the spec there.
   From then on the `c/main` copy owns this spec and its drift ledger, and this copy on `main` stays as it is until the swap replaces it.
3. Shake down (ticket C9): clear the trial home's digest faults, pin one `c/main` commit as the shakedown SHA, and run the trial home on it as a real fleet for one day of scratch work.
4. Swap (ticket C9): rehearse the swap and the rollback on a scratch clone, write both recipes into this spec, then move the live home to the shakedown SHA on the captain's word.

The shakedown SHA is the one `c/main` commit the trial home runs for the whole shakedown, and the swap takes exactly that commit's tree.

## Seams

- `bin/fm-test-run.sh <test>` on a `c/main` worktree - existing - the root's runner and every port ticket's seam; a carried-over test proves a port's behavior, and nothing above one script isolates it (AC1).
- git and GitHub refs - existing - `git log`, `git show`, `git merge-base`, `git ls-remote`, and `gh run list` against `/Users/evanagee/Sites/firstmate`, `origin`, and scratch clones; the ledger, the spec copy, the swap, and the rollback are facts about refs, and no script owns them (AC2, AC3, AC7, AC8).
- A firstmate home's session start and task records under `FM_HOME` - existing - the `bin/fm-session-start.sh` digest, `data/backlog.md`, and `state/<id>.status`; the digest is the first place a home's fitness shows, and the one the captain reads (AC4 to AC8).

## Decisions

Settled when the captain approved this spec's first version on 2026-09-21, and still in force.

- The base is `kun/main`, and `c/main` in this repo, pushed to `origin`, is the future `main`.
- Every port is a ship task on a branch off the current `c/main`, rebased onto it before landing, and landed into `c/main` by firstmate with `bin/fm-merge-local.sh` (local-only, no PR) after firstmate reads the diff and the proof.
- Nothing lands on `main` and nothing touches the live home until the shakedown passes.
- Workers take pooled worktrees of this repo (`~/.treehouse/firstmate-*`), never the live checkout and never the trial home.
- A port re-implements the feature's behavior on the root's current code and does not cherry-pick our commits.
  Where the root already grew an equivalent, the port adopts the root's version and records what changed.
- Every port loads `firstmate-coding-guidelines` and follows the root's conventions: colocated `tests/*.test.sh`, shellcheck-clean `bin/`, and one sentence per line in docs.

Definition of done for a port ticket, including C8 and every drift port:

1. The feature's behavior works on the root's code, proven by the fork's own tests carried over and adapted (never deleted) plus red tests for anything the root's structure forced to change.
2. `tests/` for the touched files pass in the worktree, and the full suite passes once in GitHub Actions (`ci.yml` on the branch) before the ready signal, because full suites no longer run on this Mac.
3. shellcheck is clean on every touched `bin/*.sh`.
4. A `## What I walked` section in the ready report shows the feature exercised live in a throwaway `FM_HOME` under the worktree, never the live home or the trial home, with the commands and their output.
5. The ticket body names what the root already had, what was adopted from the root instead of ported, and what was dropped, and a drift port settles its ledger rows.
6. Commits reference `Refs #<firstmate issue>` when the port maps to an existing issue.

## Acceptance Criteria

Every row was red at `main` `4d80f458` and `c/main` `7530c480` on 2026-09-23, except AC6, whose state there is unmeasured because no rehearsal has run.

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | When `bin/fm-treehouse-sweep.sh` runs on `c/main` without an apply flag, the sweep shall classify every unleased pool slot as clean, dirty, skipped, or damaged and shall run neither `treehouse prune --yes` nor `treehouse destroy`. | `tests/fm-treehouse-sweep.test.sh`, carried over from `main`; fixture: a fake `treehouse` that records every call and serves slot 1 clean, slot 2 dirty, slot 3 claimed by task `other-task`, slot 4 named in another task's record, slot 5 damaged, and slot 6 leased. **Make the default pass call `treehouse prune --yes` and prove AC1 goes red with "the default pass executed a destructive treehouse verb".** At base the script and its test are absent from `c/main`. | `bin/fm-treehouse-sweep.sh --pool <repo>` run from a `c/main` checkout prints one row per slot and the prune dry-run verdict, and the treehouse call log holds no destructive verb. | `bin/fm-test-run.sh tests/fm-treehouse-sweep.test.sh` on `c/main` |
| AC2 | When the swap is proposed, every commit on the live home's `main` after `40094579` that touches `bin/`, `tests/`, `.agents/`, `skills/`, `.github/`, `AGENTS.md`, or `skills-lock.json` shall have a drift-ledger row whose disposition is `ported` with a `c/main` commit, `root has it` with a root commit, or `dropped` with a reason. | The ledger check in End-to-end verification step 1; fixture: the drift ledger below, seeded with 25 `pending` rows, so the check prints 25 `unsettled` lines at base. **Set one settled row back to `pending` and prove the check prints that commit.** A `ported` row whose commit is not an ancestor of `origin/c/main` also prints a `not on c/main` line. | The ledger check, run against the live home's `main` and `origin/c/main`, prints nothing. | The ledger check command in End-to-end verification step 1 |
| AC3 | When a C8, C9, or drift-port task starts from `c/main`, the `docs/specs/upstream-rebase.md` in its worktree shall pass spec-lint. | `/Users/evanagee/.agents/skills/spec-lint/spec-lint` on the `c/main` copy of this file; fixture: the `c/main` copy at `7530c480`, which exits 1 at base with 7 faults, the first being "missing section: Problem Statement". **Put the `7530c480` copy back on `c/main` and prove AC3 goes red.** | spec-lint prints `spec-lint: ok (8 acceptance criteria: AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8)` for `git show origin/c/main:docs/specs/upstream-rebase.md`. | The spec-lint command in End-to-end verification step 2 |
| AC4 | While the trial home runs the shakedown SHA, `bin/fm-session-start.sh` there shall complete a locked digest with no `CREW_DISPATCH: invalid` line and no `TANGLE:` line. | Fixture: the trial home at `/Users/evanagee/Sites/firstmate-trial`, whose switch digest on 2026-09-23 printed `TANGLE: primary checkout on feature branch 'c/main' (expected 'main')` and `CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs non-empty class`. **Check out the named branch `c/main` again, or remove `class` from one rule in `config/crew-dispatch.json`, and prove the matching line returns.** | The trial-home digest names `/Users/evanagee/Sites/firstmate-trial`, reports `lock acquired`, and holds neither line. | The trial-home session start in End-to-end verification step 3 |
| AC5 | While the trial home runs the shakedown SHA, when its firstmate dispatches scratch work for one day (24 hours), the trial home shall carry at least one local-only ship task and one scout from spawn through a `done:` status line and teardown, shall wake its firstmate on each `done:` line, and shall need no hand edit to any record under `state/`. | Fixture: a scratch project registered in the trial home (a throwaway git repo with one failing test), a ship task that fixes the test and lands with `bin/fm-merge-local.sh`, and a scout that reports on the repo. **In a throwaway home on the same SHA, stop the supervision watcher before the worker's `done:` line and prove the wake never reaches firstmate's turn.** | The trial home's `data/backlog.md` Done entries name both tasks, the ship task's landing commit is on the scratch project's `main`, each `state/<id>.status` holds its `done:` line, and no task metadata remains after teardown. | Evan Agee, from the trial home's Done entries and status logs |
| AC6 | When `c/main`'s `bin/fm-session-start.sh` runs with `FM_API=0` and `FM_HOME` set to a scratch copy of the live home's `data/` and `config/` with empty `state/` and `projects/`, the digest shall report `lock acquired` and shall print no `CREW_DISPATCH: invalid` line and no absent, corrupt, or unreadable diagnostic for `data/backlog.md`, `data/projects.md`, or `config/`. | Fixture: the live home's `data/` and `config/`, copied at rehearsal time into a scratch directory that is deleted afterwards. **Remove `class` from one rule in the copy's `config/crew-dispatch.json` and prove `CREW_DISPATCH: invalid` appears.** | The rehearsal digest, with the `c/main` SHA it ran and the time of the copy, pasted into the C9 proof. | The rehearsal command in End-to-end verification step 4 |
| AC7 | While no task is in flight in the live home, when Evan Agee approves the swap, the live home at `/Users/evanagee/Sites/firstmate` shall check out a default branch whose tree equals the shakedown SHA's tree, shall keep the pre-swap `main` commit reachable from a named ref on `origin`, and shall complete a locked session-start digest with no `TANGLE:` line. | Rehearsal on a scratch clone of the live repo whose `origin` is a scratch bare repo: run the swap recipe, then assert that `git diff --quiet <shakedown SHA> main` exits 0, that the preserved ref resolves to the recorded pre-swap SHA, and that `gh run list --repo EvanAgee/firstmate --workflow ci.yml --commit <shakedown SHA> --json conclusion` reads `success`. **Drop the preserve step from the recipe and prove the preserved-ref assertion goes red.** | `tasks-axi list` in the live home shows nothing in flight before the swap; afterwards `git -C /Users/evanagee/Sites/firstmate diff --quiet <shakedown SHA> HEAD` exits 0, `git ls-remote origin` lists the preserved ref at the pre-swap SHA, and the live digest reports `lock acquired` with no `TANGLE:` line. | Evan Agee approves the live swap; the rehearsal and the observable commands in End-to-end verification steps 5 and 6 judge it |
| AC8 | If the swapped live home does not complete a locked session-start digest, or Evan Agee calls a rollback, then the live home shall return its default branch to the pre-swap `main` commit from the preserved ref and shall complete a locked session-start digest on it. | Rehearsal on the AC7 scratch clone after its swap: run the rollback recipe, then assert that `git rev-parse main` prints the pre-swap SHA and that `bin/fm-session-start.sh` with `FM_HOME` set to the clone reports `lock acquired`. **Delete the preserved ref before the rollback and prove the rehearsal goes red.** | The rehearsal output in the C9 proof; after a live rollback, `git -C /Users/evanagee/Sites/firstmate rev-parse HEAD` prints the pre-swap SHA. | The rollback rehearsal in End-to-end verification step 5; Evan Agee for a live rollback |

## End-to-end verification

A fresh agent runs steps 1 to 5 without touching the live home.
Step 6 needs Evan Agee's approval.

1. Ledger check (AC2): prints nothing when every ledger commit is settled.

   ```sh
   L=/Users/evanagee/Sites/firstmate
   spec=$(git -C "$L" show origin/c/main:docs/specs/upstream-rebase.md)
   for s in $(git -C "$L" log --abbrev=8 --format=%h 40094579..main -- bin tests .agents skills .github AGENTS.md skills-lock.json); do
     row=$(printf '%s\n' "$spec" | grep "^| \`$s\` |")
     case "$row" in
       ""|*"| pending |"*) echo "unsettled $s" ;;
       *"| ported \`"*)
         p=$(printf '%s\n' "$row" | sed 's/.*| ported `\([0-9a-f]*\)`.*/\1/')
         git -C "$L" merge-base --is-ancestor "$p" origin/c/main || echo "not on c/main $s -> $p" ;;
     esac
   done
   ```

2. Spec and pool sweep on `c/main` (AC3, AC1), the second command run from a `c/main` worktree:

   ```sh
   git -C /Users/evanagee/Sites/firstmate show origin/c/main:docs/specs/upstream-rebase.md | /Users/evanagee/.agents/skills/spec-lint/spec-lint -
   bin/fm-test-run.sh tests/fm-treehouse-sweep.test.sh
   ```

3. Trial home on the shakedown SHA (AC4), then one day of scratch work there (AC5):

   ```sh
   git -C /Users/evanagee/Sites/firstmate-trial rev-parse HEAD
   (cd /Users/evanagee/Sites/firstmate-trial && FM_HOME=/Users/evanagee/Sites/firstmate-trial bin/fm-session-start.sh)
   ```

4. Live-records rehearsal (AC6), run from a `c/main` worktree at the shakedown SHA:

   ```sh
   R=$(mktemp -d)/live-copy && mkdir -p "$R/state" "$R/projects"
   cp -R /Users/evanagee/Sites/firstmate/data /Users/evanagee/Sites/firstmate/config "$R/"
   FM_API=0 FM_HOME="$R" bin/fm-session-start.sh
   rm -rf "$R"
   ```

5. Swap and rollback rehearsal on a scratch clone (AC7, AC8), with the recipes C9 writes into this spec under "Swap and rollback recipes".
6. With Evan Agee's approval and nothing in flight, the live swap (AC7), its session-start digest, and one scratch scout dispatched from the live home and carried through teardown.

Expected: step 1 prints nothing; step 2 prints `spec-lint: ok (8 acceptance criteria: ...)` and an `FM_TEST_SUMMARY` line with `failed=0`; steps 3, 4, and 6 print digests with `lock acquired` and neither a `TANGLE:` nor a `CREW_DISPATCH: invalid` line; step 5's assertions all hold.
Failure looks like any `unsettled` or `not on c/main` line, a spec-lint fault, a failed test, a digest diagnostic, or a failed rehearsal assertion.
A failure at step 6 triggers the rollback in AC8.

## Non-goals

- Opening a PR, issue, or comment on, or pushing to, `kunchenguid/firstmate` or `dnth/firstmate`.
  Both are fetch-only remotes here, and anything sent to them is the captain's call, outside this spec.
- Any change to the live home's checkout, its `main`, or its running supervision before Evan Agee approves the swap in AC7.
- Porting dnth's acceptance receipts or its durable task inbox (#151).
  The captain said on 2026-09-21 that dnth's extras are optional and none is required for the swap, so C8 here is the pool sweep only; the root already ships its own inbox in `bin/fm-inbox.sh` (root #5103).
- Merging `dnth/main` wholesale.
- Adopting the root's judgment-driven dispatch contract; the captain's 2026-08-30 deterministic rule stands.
- Renaming or restructuring the root's scripts to match ours; the root's layout wins.
- Clearing the 13 local full-suite failures C0 recorded on this Mac.
  The swap gate is a green `ci.yml` run on the shakedown SHA (AC7), as the red-baseline ticket set it, and those failures stay listed in the C0 record for later work.
- Moving any other home: `data/secondmates.md` in the live home is empty on 2026-09-23, and the trial home stays a trial home after the swap.

## Open questions

- `[NEEDS CLARIFICATION: take the root's commits past 43bf6d3d into c/main before the shakedown, or after the swap? kun/main was 34 commits ahead, at 9296f9b9, on 2026-09-23.]` - Evan Agee
- `[NEEDS CLARIFICATION: does the swap rewrite origin main to c/main's history, which needs a force push, or land c/main on main as a merge commit whose tree equals the shakedown SHA, which keeps pooled worktrees fast-forwardable? AC7 accepts either.]` - Evan Agee
- `[NEEDS CLARIFICATION: is one local-only ship task plus one scout enough for the shakedown, or must it cover each primary and crew harness the live fleet runs?]` - Evan Agee

## Done

History only; none of this is acceptance work.
`git log --oneline 43bf6d3d..7530c480` lists every commit on `c/main`, including the lint and CI commits `afdf3f9c` and `075f3a4a` that rode with the ports.

| Ticket | What landed on `c/main` | Commits |
| --- | --- | --- |
| C0 | `c/main` cut from `kun/main` at `43bf6d3d`; rides #71, #90, and the calm-export half of #86 ported, #77 dropped because the root had it; suite baseline; conflict map; trial home switched to `0491f54c` on 2026-09-23 | `3ebbdf6f`, `09043c81`, `3be17f57`, `05d63289`, `44754565`, `7530c480` |
| C1 | Claude Stop-hook supervision | `4e94cb26`, `2cc6f8b8`, `b832cbb0`, `fafe74f4`, `32d31062` |
| C1b | Rides #119 stalled-validation wake, #120 tmux relaunch, #11 herdr husk relaunch | `5750336b`, `f9ff9612`, `3425dd1f` |
| C2 | Deterministic dispatch pools, availability admission, route refresh | `f3097ee5` |
| C3 | Local fleet API, captain board, delivery record, token ledger | `323a8887` |
| C4 | PR flow and landings | `e96d12db` |
| C5 | Ship-brief rules, review-loop stop, bakeoff, vendored skills and lock | `818596c2` |
| C6 | OMP capabilities probe, chrome-devtools-axi pin, pi launches under repo Node pins (#20) | `97e931c7`, `8b672c16`, `b8d1973e` |
| C6b | Bootstrap test fixtures after C6's Chrome probe | `bed7ce76` |
| Red baseline | `c/main` CI green, run 35794810970 | `cbf0c2eb`, `a1634b53`, `0491f54c` |

C0's detailed records stay in the `c/main` copy of this spec at `7530c480`: the trial-home handover recipe, the rideable-fix notes, the conflict map by ticket, and the suite baseline (219 scripts, 18 failed under load, 13 still failing alone).
Read them with `git show 7530c480:docs/specs/upstream-rebase.md`.
The first version of this spec, with the full inventory of the 105 fork commits, is `40094579`.

## Drift ledger

One row per commit in the AC2 range, seeded 2026-09-23 from `main` at `4d80f458`.
Firstmate adds a `pending` row whenever `main` gains such a commit before the swap.
A disposition is `pending`, `ported` followed by the `c/main` commit in backticks, `root has it` followed by the root commit, or `dropped` followed by a reason.

| Commit | Subject | Disposition |
| --- | --- | --- |
| `d7b17a13` | feat(ensure-agents-md): let a project opt out of the CLAUDE.md pointer | pending |
| `0a74250b` | test(ci): add shard timing hints for the CI watch and wedge tests | pending |
| `a8a7186a` | feat(ci-watch): watch a GitHub Actions run through GraphQL | pending |
| `c887c081` | fix(docs): keep the evidence-first pushback rule inline | pending |
| `177cd45d` | fix(docs): keep the PR-link rule inline and guard must-stay sentences | pending |
| `05727885` | fix(docs): keep moved AGENTS.md sentences verbatim and fix review findings | pending |
| `33cf0cfa` | fix(docs): keep firstmate instructions below harness cap | pending |
| `05f15af1` | feat(control): record a deliberate exit and name it where a lane looks parked | pending |
| `98d35d28` | fix(send): refuse to type text into a pane with no live agent | pending |
| `e3fc9eab` | fix(send): refuse Claude steers longer than one terminal read | pending |
| `63ba6402` | feat(issue-close): close issues on outage sync and keep Refs issues open | pending |
| `dae53535` | fix(afk): keep each away-mode digest inside one terminal read | pending |
| `cdd7874c` | fix(guard): clear retired markers, away gap, and ambient test home | pending |
| `dfd36382` | feat(merge-local): close linked issues after a pushed local landing | pending |
| `83c747a7` | fix(guard): stop turn-end false alarms in away mode and crew worktrees | pending |
| `cefd5600` | fix(afk): parse stale background-output suffix before matching window | pending |
| `9ddfc6b4` | fix(watch): interrupt stalled Claude background waits | pending |
| `560eacb6` | feat(watch): continue unfinished worker turns twice | pending |
| `f30466bb` | feat(spawn): launch claude tasks through the AOS coding pilot on request | pending |
| `fd71cd40` | feat(brief): pin worker self-review to Opus 5.5 at xhigh | pending |
| `572abbec` | feat(brief): name the four early stops and a frontend avoid-list | pending |
| `e681ac1b` | feat(ci): run worker full suites in GitHub Actions | pending |
| `c6dfc42d` | test(brief): require GitHub full-suite validation | pending |
| `fb42327d` | feat(agents): apply Fable prompting lessons | pending |
| `feb4201d` | fix(bin): classify pools from the plain status table when treehouse has no --json | pending |
