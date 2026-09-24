---
tags: [evidence, completion, proof, golden, fixtures, tdd]
date: 2026-09-24
issue: fleet-evidence-e3
walked: 4eae8714f97e8a81c845e8562b74ef5c8a48b1e4
spec: /Users/evanagee/Sites/firstmate/data/scott-fleet-evidence-plan/tickets/2026-09-24-e3-goldens-and-fixtures.md
---

# Pinned acceptance inputs, and reviewed golden changes

Spec: `/Users/evanagee/Sites/firstmate/data/scott-fleet-evidence-plan/tickets/2026-09-24-e3-goldens-and-fixtures.md`, ticket E3, which owns AC4 and AC5.
That spec lives in the captain's private firstmate home, not in this repository.

This branch builds on E1 and E2's `bin/fm-evidence.sh` and extends `tests/fm-completion-evidence.test.sh`; it adds no second runner, no new review stage and no sandbox.
The skill half is two patches for the shared skills, listed under "Skill patches" below; they are not applied.
Activation is off: no landing path calls `fm-evidence.sh verify` yet; E5 owns that wiring.

## How it works

Firstmate pins a task's independent acceptance inputs with `pin <task> <path> --from <commit>`.
Typically that is one golden file and the acceptance runner that holds the grading policy.
`pin` runs only outside every task worktree, like `assign` and `defect`, and stores the input's bytes in the home under `data/<task>/evidence/pins/<sha256>`, recording its path, mode and digest in the assignment.
Firstmate pins only the declared inputs.
Every other test file stays the author's to write and change, red first.

`capture` checks out the exact revision in its scratch tree as before, then writes the selected bytes of every pinned input over whatever the revision holds at that path.
A changed file, a renamed or deleted one, a new mode, a symlink, a directory, or a runner edited to skip, all give way to the pinned bytes, so the task's copy never grades the run.
The pinned paths join the scratch index, so `capture` records a run that rewrites a pinned input as having changed tracked files, as E1 already does for any tracked file.
The run record and `capture`'s output name each pinned input's path, mode, digest and source.

A change to a pinned input counts only after the task's assigned verifier reviews those exact bytes with `golden <task> <path> --revision <commit> --verdict approved|rejected --justification <text>`.
`golden` refuses any caller but the verifier, a review with no justification, a path that is not pinned, and a path that is not a regular file at that revision, so a deletion cannot be approved.
The review record holds the old and new digests and modes, the reviewed revision, the justification and the verdict.
The selected version of each pinned input starts at firstmate's pin and moves to the new bytes of each approved review whose old version is exactly the current selection, in review order.
So an approved review selects its bytes for every later run, and a newer pin from firstmate supersedes a review of an older version.

`verify` adds two checks to E1 and E2's:

- each claimed run was graded with exactly the pinned inputs selected now, so a run from before a pin or a review cannot vouch for the candidate;
- each pinned input at the reviewed revision is exactly its selected version, so a candidate that changed, deleted, renamed, re-moded or symlinked one without an approved review of those bytes stays unverified.

The verified report prints each pinned input and, for a reviewed one, the change's old and new digests, the review id, the reviewer, the verdict and the justification.
`show <task>` prints the approved commands, declared defects and selected pinned inputs, so the verifier can read what grades the task without depending on firstmate's prompt.

Same-user files are not a security boundary against a hostile process, and nothing here sandboxes the run.
The pins decide which bytes grade the run and record which ones did.

## AC4

AC4: when the reviewed revision changes a declared acceptance golden, the fleet requires the old and new content identities, a semantic justification and an independent review of that exact change before using the new golden.

The fixture adds two inputs to E1's project: G1, `test/golden/value.json`, holding input 7 and expected 14, and P1, `test/accept.mjs`, a runner that grades `src/value.mjs` against G1.
Firstmate approves k1 (`node test/accept.mjs`) and pins G1 and P1 at the base B, which holds the constant-zero program.
The contract-change lane commits the amended spec and G1 expecting 0 as T, then code returning 0 as C.

Tests in `tests/fm-completion-evidence.test.sh`:

- `test_ac4_reviewed_golden_change_with_its_red_verifies`: before any review, v1's run on C grades with the pinned G1 and fails with `expected 14, got 0`.
  The author's own `golden` call is refused with `only t1's verifier v1 reviews a change to a pinned input`.
  After v1 approves G1's bytes at C with the justification `docs/specs/s1.md AC1 now requires value 0 for input 7: the doubling is withdrawn`, the run on T is red with `expected 0, got 14`, the run on C passes, and `verify` prints `Golden: test/golden/value.json sha256 <old> to <new>, reviewed t1-g1 by v1 (approved): ...` and `Pinned: test/golden/value.json mode 100644 sha256 <new>, from t1-g1`.
- `test_ac4_golden_update_without_a_justification_is_refused`: the lane regenerates G1 and P1 in one commit; v1's review without `--justification` is refused with `golden needs --justification`, and `verify` refuses naming both inputs, as `golden: test/golden/value.json at <C> is mode 100644, sha256 <new>; its selected version is mode 100644, sha256 <old>, from <B>, and no approved review covers the change`.
- `test_ac4_approval_for_other_bytes_is_refused`: v1 approves G1's bytes at T, then the lane changes G1 to input 8; the run grades with the reviewed bytes and passes, and `verify` refuses because G1 at C is not the version the review selected.
- `test_ac4_newer_pin_supersedes_an_earlier_review`: after v1 approves G1 at C, firstmate pins a reformatted G1 from a newer main; `show` lists the newer pin, the run grades with it, and `verify` refuses the lane's G1.
- `test_ac4_deleted_golden_without_review_is_refused`: the lane deletes G1; v1's review is refused with `test/golden/value.json is not a regular file at <C>`, the run passes against the pinned G1, and `verify` refuses with `golden: test/golden/value.json at <C> is not a regular file`.

## AC5

AC5: when independent acceptance runs, the fleet uses the pinned acceptance fixtures and runner policy held outside the author task, refuses unreviewed replacements, and permits ordinary test edits and reviewed fixture changes through observed-red TDD.

Tests:

- `test_ac5_pinned_inputs_grade_the_run_and_the_report_names_them`: the author's and the verifier's `pin` calls are refused with `only firstmate pins acceptance inputs; t1 is a recorded task`.
  `show` lists k1 and the pinned digests; `capture` prints `pinned: test/golden/value.json mode 100644 sha256 <G1> from <B>`; the run record names both pins; and `verify` prints a `Pinned:` line for each.
  A manifest whose copy of a run's pins was edited is refused with `run: the manifest's pins for t1-r1 differs from the run record`.
- `test_ac5_task_copy_substitutions_cannot_replace_the_pinned_inputs`: on the constant-zero program, the lane in turn changes G1 to expect 0, renames G1 and points its runner at the new name, makes G1 executable, replaces G1 with a symlink to a file expecting 0, and adds a skip file to the runner.
  Each run exits 1 with `expected 14, got 0`, and `verify` refuses each with a `golden:` line naming the changed input, as `is not a regular file` for the rename and the symlink and `is mode 100755` for the mode change.
- `test_ac5_ordinary_test_work_proceeds_beside_the_pins`: beside the pins, the lane edits the unpinned `test/value.mjs`, then commits E2's new regression test `test/pay.mjs` red first and the fix; the red shows `charges=2`, and `verify` passes with `D1 repaired` and the `Pinned:` lines.
- `test_ac5_run_graded_without_the_selected_inputs_is_refused`: a run captured before firstmate pinned G1 is refused with `pin: run t1-r1 was graded with no pinned inputs, not the inputs selected for t1: test/golden/value.json sha256 <G1>`.

A reviewed G1 change follows AC4, as `test_ac4_reviewed_golden_change_with_its_red_verifies` shows.

## Binding contract additions

These extend the manifest format in `docs/proof/fleet-evidence-e1.md` ("Binding contract") and `docs/proof/fleet-evidence-e2.md` ("Binding contract additions"):

| Field | Meaning |
|---|---|
| `runs[].pins` | the pinned inputs that graded the run, each `{path, mode, sha256, source}`, sorted by path; `[]` when the task pins none, absent for a run recorded before E3 |

The public checker can validate the shape only.
Which inputs a task pins, their stored bytes and the reviews that changed them live in the home, so only firstmate's `verify` checks that a run's pins are the ones selected now and that the pinned inputs at the reviewed revision match them.

## Red before green

The tests were written first, then the plumbing they needed to reach their assertions: the `pin`, `golden` and `show` subcommands, and `capture` recording its pins.
The overlay in `capture` and the new checks in `verify` did not exist yet.
Each new test, run alone on the uncommitted tree on `74e60846`, failed on its named assertion:

```
not ok - ac5-pins: the report did not name the pinned G1 (missing: 'Pinned: test/golden/value.json mode 100644 sha256 a2ecd6e766bc365e152166f55dcad098b1647075bedc1c65d40cfcdf70a3b1c7, from 0d084547b943d518aafe68513d7740743527aab6')
not ok - ac5-value: the task copy's substitution earned a pass: value(7)=0
not ok - ac5-tdd: the report did not name the pinned G1 (missing: 'Pinned: test/golden/value.json mode 100644')
not ok - ac5-stale: completion should be refused: expected exit 1, got 0
not ok - ac4-ok: the unreviewed golden graded the run
not ok - ac4-mass: completion should be refused: expected exit 1, got 0
not ok - ac4-other: completion should be refused: expected exit 1, got 0
not ok - ac4-deleted: the run should grade with the pinned G1 the lane deleted: node:fs:440
```

The first run of `ac5-pins` failed on a defect in the test itself, which expected the record's pin keys in the wrong order; the line above is its red after that fix.
The first green run exposed that the manifest's copy of a run is written with sorted keys, so the copy comparison now compares each field with sorted keys.
`test_ac4_newer_pin_supersedes_an_earlier_review` was added after the implementation, when a control that dropped the review-chain condition failed no test; its red is that control, in the table below.

## Controls

Each control copied `bin/` and `tests/` into a throwaway directory, applied one mutation to the copy's `bin/fm-evidence.sh`, and ran only the named test there; the worktree was never edited.
The unmutated copy passed `test_ac5_task_copy_substitutions_cannot_replace_the_pinned_inputs`, `test_ac4_deleted_golden_without_review_is_refused` and `test_ac4_newer_pin_supersedes_an_earlier_review`.

| AC | Mutation | Result |
|---|---|---|
| AC5 | Grade with the task copy: skip the overlay of pinned inputs (the spec's "use the task copy") | `not ok - ac5-value: the task copy's substitution earned a pass: value(7)=0` |
| AC5 | Skip the overlay of the runner only, so its skip policy stands (the spec's "its skip policy") | `not ok - ac5-rename: the task copy's substitution earned a pass: value(7)=0` |
| AC5 | Accept a run graded with other pinned inputs than the ones selected now | `not ok - ac5-stale: completion should be refused: expected exit 1, got 0` |
| AC5 | Let a recorded task pin inputs | `not ok - ac5-pins: the author pinning an acceptance input should be refused: expected exit 2, got 0` |
| AC5 | Leave the manifest's copy of a run's pins unchecked | `not ok - ac5-pins-manifest: completion should be refused: expected exit 1, got 0` |
| AC4 | Ignore a changed or deleted pinned golden (the spec's mutation), run against the mass update | `not ok - ac4-mass: refusal did not name the reason (missing: 'golden: test/golden/value.json at <C> is mode 100644, sha256 <new>; its selected v...` |
| AC4 | The same mutation, against the review of other bytes | `not ok - ac4-other: completion should be refused: expected exit 1, got 0` |
| AC4 | The same mutation, against the deleted golden | `not ok - ac4-deleted: completion should be refused: expected exit 1, got 0` |
| AC4 | Accept a golden review with no justification | `not ok - ac4-mass: a golden review with no justification should be refused: expected exit 2, got 0` |
| AC4 | Let the author review its own golden change | `not ok - ac4-ok: the author reviewing its own golden change should be refused: expected exit 2, got 0` |
| AC4 | Apply an approved review whatever version it reviewed | `not ok - ac4-repin: the newer pin did not replace the reviewed G1 (missing: '"sha256": "<newer pin>"')` |

In the mass-update row the candidate was still refused, because its run failed against the pinned inputs, but without the named `golden:` reason, so the test failed as required.

## What I walked

I walked commit `4eae8714`, whose `bin/` and `tests/` match the implementation commit `89fe0e29`, on macOS 27.0 with GNU bash 5.3.15, git 2.54.0 and node 22.22.0, running the real `bin/fm-evidence.sh` against a fresh scratch firstmate home and a synthetic project under the system temp directory, with `GIT_CONFIG_GLOBAL=/dev/null` and no network.
The project's base B held the constant-zero program, G1 (`test/golden/value.json`, input 7, expected 14) and P1 (`test/accept.mjs`).
The author t1 and the verifier v1 were recorded tasks, each with its own worktree.

1. From the scratch root, `assign t1 --verifier v1 --command-id k1 ... -- node test/accept.mjs` printed `approved k1 for t1: AC1 of docs/specs/value.md, verified by v1`.
   From t1's worktree, `pin t1 test/golden/value.json --from <B>` printed `error: only firstmate pins acceptance inputs; t1 is a recorded task`, exit 2.
   From the scratch root, both `pin` calls printed `pinned <path> for t1: mode 100644 sha256 <digest> from <B>`.
2. From v1's worktree, `show t1` printed k1's argv, spec and bounds, `"defects": {}`, and both pins with path, mode, digest and source.
3. t1 committed X: the constant-zero program, G1 expecting 0, and a runner that exits early when `test/.skip` exists, plus that file.
   The lane's own runner at X printed `skipped`.
   v1's `capture` on X printed `run t1-r1 exited exit=1` and one `pinned:` line per input from B, and its stderr was `expected 14, got 0`.
   After v1 judged it and t1 attached it, `verify t1` printed `refused:`, `- run: run t1-r1 exited 1`, and one `- golden:` line each for `test/accept.mjs` and `test/golden/value.json` at X, naming the lane's digest, the pinned digest from B and `no approved review covers the change`, exit 1.
4. t1 reset to B and committed C: the doubling repair and a new unpinned test, `test/double.mjs`.
   v1's run on C exited 0; after judging and attaching, `verify t1` printed `verified: t1 at <P> (reviewed <C>, base <B>)`, the E1 and E2 report lines, and `Pinned: test/accept.mjs mode 100644 sha256 e13b64be..., from <B>` and `Pinned: test/golden/value.json mode 100644 sha256 a2ecd6e7..., from <B>`, exit 0.
5. t1 committed T (the amended spec and G1 expecting 0) and C2 (code returning 0).
   Before any review, v1's run on C2 exited 1 with `expected 14, got 0`.
   From t1's worktree, `golden t1 test/golden/value.json --revision <C2> ...` printed `error: only t1's verifier v1 reviews a change to a pinned input`, exit 2.
   From v1's worktree, the same call without `--justification` printed `error: golden needs --justification: the behavior change that makes the new bytes right`, exit 2.
   With the justification it printed `golden t1-g1 approved test/golden/value.json: sha256 a2ecd6e7... to 3bdf8b21..., by v1`.
   v1's run on T then exited 1 with `expected 0, got 14`, and on C2 exited 0, both printing `pinned: test/golden/value.json mode 100644 sha256 3bdf8b21... from t1-g1`.
   After judging and attaching, `verify t1` printed `verified:`, `Pinned: test/golden/value.json mode 100644 sha256 3bdf8b21..., from t1-g1` and `Golden: test/golden/value.json sha256 a2ecd6e7... to 3bdf8b21..., reviewed t1-g1 by v1 (approved): docs/specs/value.md AC1 now requires value 0 for input 7: the doubling is withdrawn`, exit 0.
6. t1 committed C3, changing G1 to input 8.
   v1's run on C3 graded with the reviewed bytes and exited 0, and `verify t1` printed `refused:` and `- golden: test/golden/value.json at <C3> is mode 100644, sha256 dcf4cf42...; its selected version is mode 100644, sha256 3bdf8b21..., from t1-g1, and no approved review covers the change`, exit 1.
7. The home held `assignment.json`, `pins/` with the three stored versions (G1 at B, G1 as reviewed, and P1), `goldens/t1-g1.json`, `judges/t1-j1.json` to `t1-j4.json`, and `runs/t1-r1` to `t1-r6`.
   The review record held `old` (mode 100644, the B digest, source B), `new` (mode 100644, the reviewed digest, source C2), the justification, `verdict: approved` and `reviewer: v1`.

I did not walk a real verifier crewmate or the code-review Evidence reviewer: their instructions change only when the patches below are applied, and the canary tasks through each delivery mode belong to E5.

## Skill patches

Each patch is in the firstmate home, and `git -C /Users/evanagee/.agents apply --check` accepts each one alone and both together on `ae78010`; neither is applied:

- `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e3/tdd-pinned-inputs.patch`: adds the rule that pinned acceptance inputs change only by review, that every other test stays the author's to write red first, and that a pinned input changes as a contract change: new bytes that fail on the old code, the spec change that makes them right, and a request for review.
- `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e3/code-review-pinned-inputs.patch`: gives the Evidence sub-agent the pinned inputs (`fm-evidence.sh show`), has the verifier review every pinned input the diff changes with `fm-evidence.sh golden` before capturing, approving only when the spec's change requires the new values and rejecting a wholesale regeneration, and says capture grades with the pinned inputs.

## Checks run locally

- `bin/fm-lint.sh bin/fm-evidence.sh tests/fm-completion-evidence.test.sh` printed only `fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)`.
- `bash tests/fm-completion-evidence.test.sh` at `89fe0e29` and again at `4eae8714` printed 40 `ok` lines and no `not ok`.
- `bin/fm-test-run.sh --check-coverage` printed `FM_TEST_COVERAGE ok total=197 parallel=24 serial=161 serial_shards=8 herdr=12`.
- `bin/fm-doc-audience-check.sh` with this proof staged printed `fm-doc-audience-check: ok surfaces=161 local_links=310`, and `tests/fm-documentation-audiences.test.sh` printed four `ok` lines.
- `npx unslop` on the changed shell, JSON and Markdown files printed `No supported files found.`

## Follow-ups, not fixed here

- A pinned input can be retired only by firstmate: `golden` cannot approve a deletion, and there is no unpin command, because this ticket starts with one golden and one runner policy.
- `verify` does not require an observed red for a reviewed golden change; the tests and the walk show one, and the tdd patch asks for it, but a reviewer can approve without it.
- A pinned input under a directory that the revision replaced with a symlink or a file makes `capture` stop with `cannot place the pinned <path>`, rather than recording a failed run.
- E2's follow-up that `fm-evidence.sh` had no command to show a task's approved commands and declared defects is closed by `show`, and E1's `expect_refused` helper now matches a line starting `verified:` instead of the text inside `unverified:`.
