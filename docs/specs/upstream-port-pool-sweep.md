# Upstream port, phase A1: the treehouse pool-hygiene sweep

Captain authorized Option A on 2026-09-18 ("Let's start with A but make a note that C comes next",
then "go"). This spec covers the one piece of Option A that measurement proved is a genuine port.
Phases A2 and C are recorded at the end and are NOT authorized by this spec.

Upstream: `dnth/firstmate` @ `dnth/main`. Fork: `EvanAgee/firstmate` @ `origin/main`.
Merge base: `bea3d23d`, 2026-08-04.

## Why this and not the rest of Option A

Yesterday's comparison report (`.lavish/firstmate-upstream-comparison.html`) ranked four ports as
self-contained. Re-measuring each against the real code on 2026-09-18 found that only one is.
The numbers below are from this checkout, not from the report:

| Report's claim | Measured reality | Verdict |
| --- | --- | --- |
| Pool sweep is self-contained, report-only | All files new; needs 4 helper functions, ~100 lines total | Port it. This spec. |
| Receipts is a self-contained `bin/` subsystem | All 7 files new, but `fm-receipt-check.sh` needs 6 functions from our shared libs and 4 do not exist here | Cost it, then decide. Phase A2. |
| Brief additions are small, testable edits | Upstream `fm-spawn.sh` differs by ~4,390 changed lines, `fm-brief.sh` by 424 | Not a port. Folded into C. |
| Task-inbox doorbell is a moderate port | Requires upstream `fm-send.sh`: +972 / -129 lines, the script every steer flows through | Not a port. Folded into C. |

A straight merge remains unavailable: 178 files conflict, concentrated in `bin/` (54) and `tests/`
(67), plus `AGENTS.md` and five skills.

## What the sweep is

`bin/fm-treehouse-sweep.sh` wraps treehouse's own `prune` and `destroy` verbs and layers
firstmate's ownership proof on top, because treehouse cannot see `.fm-slot-owner` claims or another
home's `state/*.meta` records.

It classifies every unleased slot into four tiers through an ordered ownership proof: slot claim,
cross-home record scan, live occupancy, then landedness. Tiers are `clean` (provably returnable),
`dirty` (unlanded or unmerged), `damaged` (broken link, inspect-only forever), and `skipped`.

Safety properties that make it eligible, read from the script header:

- Default run is classify plus dry-run. It removes nothing.
- The `clean` tier needs the gitignored `config/treehouse-sweep-clean` presence flag, default off.
- The `dirty` tier is never batched. One exact path at a time via
  `--apply-slot <path> --captain-approved`.
- `--include-in-use` and `--include-leased` are never forwarded.
- An apply pass refuses when another pool operation holds the project lock, or when any scanned
  slot has an unreadable claim or unprovable occupancy.

This matches the standing rule that unlanded work is never torn down, and it complements the
teardown guard the fork already grew.

## Files to bring over

New files, no conflicts (verified absent from `origin/main`):

- `bin/fm-treehouse-sweep.sh`
- `bin/fm-pool-lib.sh` (70 lines; sources `fm-treehouse-root-lib.sh`)
- `bin/fm-treehouse-root-lib.sh`
- `docs/verification/treehouse-pool-audit.md`

Bring the upstream tests too, adapted only where the fork's paths differ:

- `tests/fm-treehouse-orphan-recovery.test.sh`

## Functions to backport

The sweep calls eight `fm_*` functions. Four already exist here and are unchanged in behavior:
`fm_lock_release` and `fm_lock_try_acquire` (`bin/fm-wake-lib.sh`), `fm_meta_get`
(`bin/fm-backend.sh`), and `status`/porcelain helpers that arrive with `fm-pool-lib.sh`
(`fm_pool_worktree_clean`, `fm_pool_worktree_idle`, `fm_pool_first_real_porcelain_line`).

Four are missing here and must be backported into `bin/fm-wake-lib.sh`:

- `fm_treehouse_project_lock_path` (~26 lines)
- `fm_treehouse_slot_owner_state` (~39 lines)
- `fm_treehouse_slot_owner_marker`
- `fm_firstmate_root_home`

`bin/fm-wake-lib.sh` is a shared file, so this is an additive edit to code the fleet depends on.
Add the four functions; change no existing function in that file. If a name already exists with
different behavior, stop and report rather than overwriting.

The sweep also sources `bin/fm-backend.sh` and `bin/fm-homes-lib.sh`. It calls nothing from
`fm-homes-lib.sh`, which does not exist in the fork. Resolve that by either porting the file or
dropping the unused source line. Prefer dropping the unused source, per the smallest-correct-change
rule, and say which was chosen and why.

## Acceptance criteria

1. `bin/fm-treehouse-sweep.sh --help` runs in this home and prints its usage.
2. A default run with no flags classifies the real pool and removes nothing. Capture the tier
   counts in the proof.
3. Every tier boundary holds under test: `clean` refuses to act without the
   `config/treehouse-sweep-clean` flag, `dirty` refuses without both `--apply-slot` and
   `--captain-approved`, and `damaged` never acts.
4. An apply pass refuses when the project lock is held, and refuses on an unreadable claim or
   unprovable occupancy.
5. A slot claimed by another task, or named by any `state/*.meta` `worktree=` in any registered
   home, lands in `skipped` and is never removed. This is the rule that protects live lanes.
6. The ported test file passes, plus one new red-first test per backported function.
7. `shellcheck` clean on every changed and added script.
8. No existing function in `bin/fm-wake-lib.sh` changes behavior. Prove it by running the existing
   wake and supervision tests.

## Walked-path proof

Required before done, under `## What I walked` in the PR body:

- The default classify run against the real `~/.treehouse` pool, with tier counts.
- One refusal observed for each gate in criteria 3 and 4, with the exact refusal text.
- A named live slot proven to land in `skipped`, showing the claim or meta record that protected it.

Never run an apply pass against the live pool for the proof. Use a scratch pool or fixture for
anything that removes a slot. The fleet's live worktrees are in that pool.

## Constraints

- This is firstmate's own shared tracked material, so load `firstmate-coding-guidelines` before
  editing.
- Additive only in shared files. Do not resolve unrelated upstream divergence in passing.
- One sentence per line in docs. Plain dash, never an em-dash. No agent co-author on commits.
- Do not import upstream's `config/crew-dispatch.json` schema or any part of it. The fork's
  deterministic routing is the captain's standing rule and upstream's is judgment-driven.
- Attribute the port: note the upstream commit each file came from in the PR body.

## Not in scope, recorded for later

**Phase A2, receipts, costed but not authorized.** `bin/fm-receipt.sh`, `fm-receipt-check.sh`,
`fm-receipt-store.sh`, `fm-receipt-schema.sh`, their two test files, and
`docs/verification/evidence-receipts.md` are all new files and conflict with nothing. The blocker
is that `fm-receipt-check.sh` sources `fm-nm-run-lib.sh`, `fm-worktree-clean-lib.sh`, and
`fm-classify-lib.sh` and needs six functions, of which four are missing here:
`fm_nm_run_branch_ownership`, `fm_nm_run_is_active`, `fm_nm_run_is_terminal_passed`, and
`status_done_line_has_artifact`. It also calls `bin/fm-local-default.sh`, which the fork lacks.
Deliverable for A2 is a real line-count cost for those four functions plus a
port-or-reimplement recommendation. Receipts matters because it would answer the open
`aos-review-receipts-decision` on the board with working machinery instead of another plan.

**Phase C, the full reconciliation, is next per the captain on 2026-09-18.** Scope: the 178
conflicting files, and the two pieces pulled out of Option A because each means adopting upstream's
version of a core script the fork rewrote (`fm-send.sh` for the doorbell, `fm-spawn.sh` and
`fm-brief.sh` for the brief additions). The upstream supervision branch belongs here too, and the
report's advice stands: prototype it in the trial home at `~/Sites/firstmate-trial`, never on this
home, because it would re-architect the machinery currently supervising the live fleet.
Start C from the measurements in this spec, not from the comparison report's estimates, which were
optimistic on all four pieces.

**Unrelated and higher value than any of this.** Pooled capacity is invisible to route admission.
`quota-axi` read Codex at 0% while the pool had 94% left, so admission declared a healthy pool dead
and burned the relief route, which killed two lanes on 2026-09-17. That is fork-only work, no
upstream port involved, and it pays off on the next dispatch. Tracked separately.
