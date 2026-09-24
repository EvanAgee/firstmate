---
tags: [evidence, completion, proof, tdd, regression]
date: 2026-09-24
issue: fleet-evidence-e2
walked: a5116c118d8445cf3cc9b67d567f3468d0f78a34
spec: /Users/evanagee/Sites/firstmate/data/scott-fleet-evidence-plan/tickets/2026-09-24-e2-assertions-and-regressions.md
---

# A claim names its oracle, and a repaired defect names its red and green

Spec: `/Users/evanagee/Sites/firstmate/data/scott-fleet-evidence-plan/tickets/2026-09-24-e2-assertions-and-regressions.md`, ticket E2, which owns AC1 and AC2.
That spec lives in the captain's private firstmate home, not in this repository.

This branch builds on E1's `bin/fm-evidence.sh` and extends `tests/fm-completion-evidence.test.sh`; it adds no second runner and no new review stage.
The skill half is four patches for the shared skills, listed under "Skill patches" below; they are not applied.
Activation is off: no landing path calls `fm-evidence.sh verify` yet; E5 owns that wiring.

## How it works

The verifier's `judge` now takes the claim's oracle: `--assertion` (the test and the assertion it makes), `--expected` (the expected result) and `--source` (where that result comes from, independent of the code under review).
All three come together or not at all.
`verify` reports a supported claim whose judgement names no oracle as unchecked, and the verified report prints the assertion and its source beside the run.

Firstmate declares each defect a task claims to repair with the new `defect` subcommand, from outside every task worktree like `assign`.
A declaration names the symptom the report showed, the approved regression command, the regression test's path and the approved original reproducer command.
A defect with no seam is declared with `--no-seam <reason>` instead.
The verifier captures the regression on a pre-fix revision and names that run with `--red` when it judges the regression's run on the reviewed revision.
`attach` commits the red run's output beside the others.

`verify` leaves a declared defect unverified, and so refuses completion, unless all of these hold:

- a supported claim runs its regression command, and that claim's judgement names a red run;
- the red run is the verifier's run of the same command in its approved form, on a revision other than the reviewed one, holding the same regression test file as the reviewed revision;
- the red run exited non-zero and its captured output contains the declared symptom;
- the red run's captured bytes, its manifest entry and its committed output files agree, as E1 requires of every run;
- a supported claim reruns the original reproducer on the reviewed revision.

A defect declared with no seam is always unverified.
`capture` also prints the paths of its captured output, because the verifier has to read that output to judge the oracle and the red.

## AC1

AC1: when a completion claim uses test coverage as support, the fleet requires an assertion or property with an independently sourced expected result and a matching observed run before accepting that claim.

Tests in `tests/fm-completion-evidence.test.sh`, on E1's fixture (author t1, verifier v1, command k1, input 7 that must produce 14, a constant-zero program at the base B):

- `test_ac1_coverage_only_claim_is_unchecked`: k1 is `node test/cover.mjs`, which calls `value(7)` and prints `coverage: 100% of src/value.mjs`.
  Captured on B, where the program returns a constant 0, it still exits 0.
  A judgement naming an assertion but no expected value or source is refused with `an oracle needs --assertion, --expected and --source together`.
  Judged supported with no oracle, the claim is refused as `oracle: AC1 unchecked, missing oracle: judge t1-j1 names no assertion with an independently sourced expected result`.
- `test_ac1_assertion_with_an_independent_expected_value_verifies`: k1 is `node test/value.mjs`.
  Captured on B in capture's scratch checkout, the constant-zero program fails the assertion with `expected 14, got 0` on stderr.
  Captured on the reviewed revision C, it passes, and capture prints where the output lives.
  With the oracle `test/value.mjs: value(7) is 14`, expected `14`, from `docs/specs/s1.md AC1 worked example: input 7 gives 14`, the claim verifies and the report prints `Assertion:` and `Expected: 14, from ...` beside the run id.

## AC2

AC2: when a task claims defect D1 repaired, the fleet requires D1 to resolve to a retained regression test, its matching observed red, its passing run on the reviewed revision, and the original reproducer result, or leaves D1 unverified with the missing-seam reason.

The fixture's base holds `pay`, which charges an order again when it is retried, and `scripts/checkout.mjs`, the original reproducer, a checkout that retries once and prints `charges=2`.
The lane commits the regression test `test/pay.mjs` (two calls for one order, expecting one charge) as revision T, then the fix as C.
Firstmate approves k2 (`node test/pay.mjs`) and k3 (`node scripts/checkout.mjs`) and declares D1 with symptom `charges=2`.

Tests:

- `test_ac2_repaired_defect_names_its_red_green_and_reproducer`: v1 captures k2 on T (exit 1, `charges=2`), k2 on C and k3 on C, and judges the green naming the red.
  `verify` prints `D1 repaired, symptom charges=2`, then `Regression: test/pay.mjs, assertion: ...`, `Red: run <id> on <T>, exit 1, showed charges=2`, `Green: run <id> on <C>, exit 0` and `Reproducer: k3, run <id> on <C>, exit 0`.
- `test_ac2_repair_without_its_red_is_unverified`: a green judged with no red is refused as `D1 unverified, judge <id> names no red run of its regression k2`; a red captured by the author is refused as `red run <id> was executed by t1, not the independent verifier v1`.
- `test_ac2_red_from_a_parser_failure_is_unverified`: a red captured on a revision where `src/pay.mjs` is a syntax error exits 1 with `SyntaxError`, and is refused as `red run <id> does not show the symptom charges=2`.
- `test_ac2_red_of_another_test_is_unverified`: a red from a revision whose `test/pay.mjs` just prints `charges=2` and exits 1 is refused as `red run <id> ran another test/pay.mjs than the one retained at <C>`.
- `test_ac2_repair_without_its_reproducer_rerun_is_unverified`: with no claim for k3, the defect is refused as `D1 unverified, no supported claim reruns its original reproducer k3`.
- `test_ac2_defect_with_no_seam_is_unverified`: the author declaring a defect is refused with `only firstmate declares defects`; firstmate declares D2 with `--no-seam`, and an otherwise verified task is refused as `defect: D2 unverified, no seam: the double charge needs two gateway processes; ...`.

## Binding contract additions

These extend the manifest format in `docs/proof/fleet-evidence-e1.md` ("Binding contract"):

| Field | Meaning |
|---|---|
| `judges[].oracle` | `{assertion, expected, source}`, three non-empty strings, or null when the judgement named none |
| `judges[].red` | the run id of the regression's red run, or null |
| `runs[]` | also holds each red run a judgement names, once, with its `stdout` and `stderr` committed under `docs/proof/` like any other run |

The public checker can validate the shapes: a supported claim's judge has a non-null oracle, and each non-null `red` names a `runs[]` entry whose `exit` is non-zero and whose `revision` differs from `reviewed`.
Only firstmate's `verify` can check the defect declaration, the red's executor, command form, test file and symptom, because the declaration lives in the home, not in the manifest.

## Red before green

The tests were written first, then the plumbing they needed to reach their assertions: the judge's new arguments, the `defect` subcommand, and attach carrying red runs.
The verify rules did not exist yet.
Each new test, run alone at the uncommitted tree on `ccec9d50`, failed on its named assertion:

```
not ok - ac1-coverage: completion should be refused: expected exit 1, got 0
not ok - ac1-oracle: the report did not name the assertion (missing: 'Assertion: test/value.mjs: value(7) is 14')
not ok - ac2-ok: the report did not name D1 (missing: 'D1 repaired, symptom charges=2')
not ok - ac2-nored-missing: completion should be refused: expected exit 1, got 0
not ok - ac2-parser: completion should be refused: expected exit 1, got 0
not ok - ac2-othertest: completion should be refused: expected exit 1, got 0
not ok - ac2-norepro: refusal did not name the reason (missing: 'defect: D1 unverified: no supported claim reruns its original reproducer k3')
not ok - ac2-noseam: completion should be refused: expected exit 1, got 0
```

The first green run then exposed a test defect: E1's `expect_refused` rejects any output containing `verified:`, which `unverified:` matches, so the defect messages now read `D1 unverified, <reason>`.

The capture output paths came later, found while building the reviewer's prompt, and went red first too: `not ok - ac1-oracle: capture did not tell the verifier where to read the output it judges (missing: 'output: <home>/data/t1/evidence/runs/t1-r2/stdout <home>/data/t1/evidence/runs/t1-r2/stderr')`.

## Controls

Each control copied `bin/` and `tests/` into a throwaway directory, applied one mutation to the copy's `bin/fm-evidence.sh`, and ran only the named test there; the worktree was never edited.
The unmutated copy passed `test_ac1_coverage_only_claim_is_unchecked` and `test_ac2_red_from_a_parser_failure_is_unverified`.

| AC | Mutation | Result |
|---|---|---|
| AC1 | Accept a supported claim with no oracle (the spec's "accept the coverage-only case") | `not ok - ac1-coverage: completion should be refused: expected exit 1, got 0` |
| AC2 | Accept any failing run as the red, with no symptom match (the spec's "accept any failing test") | `not ok - ac2-parser: completion should be refused: expected exit 1, got 0` |
| AC2 | Accept a regression judgement that names no red | `not ok - ac2-nored-missing: completion should be refused: expected exit 1, got 0` |
| AC2 | Accept the author's red | `not ok - ac2-nored-author: completion should be refused: expected exit 1, got 0` |
| AC2 | Accept a red of a different test file | `not ok - ac2-othertest: completion should be refused: expected exit 1, got 0` |
| AC2 | Drop the original reproducer rerun requirement | `not ok - ac2-norepro: refusal did not name the reason (missing: 'defect: D1 unverified, no supported claim reruns its original reproducer k3')` |
| AC2 | Let a no-seam defect pass | `not ok - ac2-noseam: completion should be refused: expected exit 1, got 0` |
| AC2 | Leave the red run out of the manifest in `attach` | `not ok - ac2-ok: a repair with its red, green and reproducer should verify: refused: t1 at <P>` |

The spec's other AC1 control, "replace the program with a constant 0 in a disposable copy and require its assertion to fail", is part of the AC1 test itself: B is the constant-zero program, capture runs it in a scratch checkout, and the assertion fails with `expected 14, got 0` while the coverage command still exits 0.

## The Evidence reviewer on the synthetic cases

With the captain's approval, I ran the Evidence reviewer headless, one run per case, with `claude -p --model opus` and `CLAUDE_CODE_NO_MODEL_FALLBACK=1 CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1`, no MCP servers and no slash commands.
Its tools were Read, Grep, Glob and Bash limited to `git`, `node`, `cat`, `ls` and a scratch wrapper around `bin/fm-evidence.sh` at `85206018`.
The prompt was the Evidence sub-agent prompt that the patched code-review skill builds, with its brief copied verbatim from the patched `SKILL.md`.
Each case was a scratch firstmate home and project where the author t1 had committed the lane and firstmate had approved the commands; the reviewer ran in the verifier v1's own worktree, so its captures and judgements were recorded as v1's.
After each run, t1 attached the reviewer's judgements and firstmate ran `verify`.

| Case | Lane | Reviewer's verdict | modelUsage | `verify` |
|---|---|---|---|---|
| AC1, coverage only | `test/cover.mjs` calls `value(7)` and prints a coverage line; k1 is `node test/cover.mjs` | unsupported: "`test/cover.mjs` passes but checks nothing: it would still pass if `value` doubled nothing" | `claude-opus-5-5` only, 5 turns | refused: `judge: t1-j1 found AC1 unsupported` |
| AC1, oracle | `test/value.mjs` exits 1 unless `value(7)` is 14; k1 is `node test/value.mjs` | supported, oracle `test/value.mjs: value(7) !== 14 -> exit 1`, expected `14`, source `docs/specs/value.md AC1 worked example: value(7) returns 14` | `claude-opus-5-5` only, 9 turns | verified, report names the assertion, the source and run t1-r1 |
| AC2, one-commit repair | `test/pay.mjs` and the fix in one commit, so no lane revision holds the failing test; D1 declared with symptom `charges=2` | supported; it built control commit `95da622` in its own worktree with `src/pay.mjs` reverted to the merge base, captured k2 there (exit 1, `charges=2`), and named that run as the red | `claude-opus-5-5` only, 16 turns | verified, report prints `D1 repaired, symptom charges=2` with red t1-r3 on `95da622`, green t1-r1 and reproducer k3 run t1-r2 |

In the oracle and repair runs, `permission_denials` lists one compound Bash command each (a `cd ... &&` chain and a `;` chain), which the allow list refused; the reviewer reran the same steps as separate allowed commands.

The reviewer rejected the coverage-only case on its own, as unsupported, so the missing-oracle backstop in `verify` did not fire there; the AC1 tests and the walk exercise that backstop.
In the oracle case the reviewer also noted that the shared fixture spec's AC2 and D1 had no command, which is true of that fixture and outside its brief.

## What I walked

I walked commit `a5116c11` on macOS 27.0 with GNU bash 5.3.15, git 2.54.0 and node 22.22.0, running the real `bin/fm-evidence.sh` against a fresh scratch firstmate home and a synthetic project under the system temp directory, with `GIT_CONFIG_GLOBAL=/dev/null` and no network.
The project's default branch held a constant-zero `value`, a `pay` that charges a retried order twice, and the checkout reproducer.
t1 and t2 were author tasks and v1 the verifier, each with its own worktree.

1. From the scratch root, firstmate approved k1 for t1 as `node test/cover.mjs`.
   From v1's worktree, `capture` on the base printed `run t1-r1 exited exit=0` and on C1 `run t1-r2 exited exit=0`, each followed by an `output:` line naming the captured stdout and stderr; t1-r2's stdout was `coverage: 100% of src/value.mjs`.
2. `judge ... --verdict supported --assertion 'the program runs'` printed `error: an oracle needs --assertion, --expected and --source together` and exited 2.
3. v1 judged t1-r2 supported with no oracle, t1 attached it and committed its proof, and `verify t1` printed `refused:` with `- oracle: AC1 unchecked, missing oracle: judge t1-j1 names no assertion with an independently sourced expected result`, exit 1.
4. Firstmate re-approved k1 as `node test/value.mjs`.
   v1's capture on the base exited 1 with stderr `expected 14, got 0`; on C1 it exited 0.
   v1 judged it with the oracle `test/value.mjs: value(7) is 14`, expected `14`, from `docs/specs/value.md AC1 worked example: input 7 gives 14`, and after t1 attached it `verify t1` printed `verified:` with `Assertion: test/value.mjs: value(7) is 14` and `Expected: 14, from docs/specs/value.md AC1 worked example: input 7 gives 14`, exit 0.
5. Firstmate approved k2 (`node test/pay.mjs`) and k3 (`node scripts/checkout.mjs`) for t2.
   From t2's worktree, `defect t2 D1 ...` printed `error: only firstmate declares defects; t2 is a recorded task`; from the scratch root it printed `declared D1 for t2`.
6. v1 committed a control revision in its own worktree with `src/pay.mjs` as a syntax error, captured k2 there (exit 1), captured k2 and k3 on C2 (exit 0), and judged the green naming the parser failure as its red.
   `verify t2` printed `- defect: D1 unverified, red run t2-r1 does not show the symptom charges=2`, exit 1.
7. v1 captured k2 on T, the lane's commit holding the failing test: exit 1, stdout `charges=2`.
   v1 judged the green again naming that red, t2 attached both claims, and `verify t2` printed `verified:` with `D1 repaired, symptom charges=2`, `Red: run t2-r4 on <T>, exit 1, showed charges=2`, `Green: run t2-r2 on <C2>, exit 0` and `Reproducer: k3, run t2-r3 on <C2>, exit 0`, exit 0.
   The committed proof held the manifest, the proof and the output files of all three runs, the red's included.
8. Firstmate declared D2 with `--no-seam 'the double charge needs two gateway processes; no single-process seam replays it'`, and `verify t2` printed `- defect: D2 unverified, no seam: the double charge needs two gateway processes; no single-process seam replays it`, exit 1.

The canary tasks through each delivery mode belong to E5, and I did not walk them.

## Skill patches

Each patch is in the firstmate home and `git -C /Users/evanagee/.agents apply --check` accepts each one alone and all four together; none is applied:

- `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e2/tdd-evidence.patch`: adds the coverage-only anti-pattern, says every test has an oracle, and adds the rule that a repair's red is the defect's symptom, kept reachable by committing the failing test before the fix or naming the fix's files for a control commit.
  Ordinary red-then-green test writing is unchanged.
- `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e2/implement-evidence.patch`: the definition of done names each criterion's oracle, says a coverage figure proves no criterion, and requires each repaired defect's regression, red, green and reproducer rerun, or an unverified report with the missing seam.
- `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e2/diagnosing-bugs-evidence.patch`: phase 5's red must show the user's symptom, the original loop's rerun is recorded, and a missing seam leaves the defect unverified rather than repaired.
- `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e2/code-review-evidence.patch`, on top of E1's change in `ed3d3f2`: the Evidence brief counts a test with no oracle as no test, names each oracle and each defect's red, green and reproducer rerun, passes the oracle to `judge`, and has the verifier capture a red on a pre-fix revision or its own control commit and name it with `--red`.
  It also passes the approved command ids and declared defects into the verifier's prompt.

## Checks run locally

- `bin/fm-lint.sh bin/fm-evidence.sh tests/fm-completion-evidence.test.sh` printed only `fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)`.
- `bash tests/fm-completion-evidence.test.sh` at `85206018` printed 31 `ok` lines and no `not ok`.
- `bin/fm-test-run.sh --check-coverage` printed `FM_TEST_COVERAGE ok total=197 parallel=24 serial=161 serial_shards=8 herdr=12`.
- `bin/fm-doc-audience-check.sh` with this proof staged printed `fm-doc-audience-check: ok surfaces=160 local_links=310`, and `tests/fm-documentation-audiences.test.sh` printed three `ok` lines.
- `npx unslop` on the changed shell and Markdown files printed `No supported files found.`

## Follow-ups, not fixed here

- The oracle is the reviewer's statement: `verify` requires it and binds it to the run's exact output bytes, but does not check that the expected text appears in that output, because E1's AC6 keeps a run with empty output valid.
  In the coverage case the reviewer recorded an oracle of "none" beside its unsupported verdict, which `verify` accepts because the verdict already refuses.
- `fm-evidence.sh` has no command that shows a task's approved commands and declared defects, so the verifier learns them only from firstmate's prompt.
- E1's `expect_refused` helper matches `verified:` anywhere in the output, including inside `unverified:`; this lane worded its messages around it rather than changing the helper.
