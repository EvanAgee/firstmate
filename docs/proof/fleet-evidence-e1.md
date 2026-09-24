---
tags: [evidence, completion, proof, spec-lock]
date: 2026-09-24
issue: fleet-evidence-e1
walked: 517290b295a4110e90d9178aed599a456f811d45
spec: /Users/evanagee/Sites/firstmate/data/scott-fleet-evidence-plan/tickets/2026-09-24-e1-recorded-runs.md
---

# An independent recorded run, and a completion claim bound to it

Spec: `/Users/evanagee/Sites/firstmate/data/scott-fleet-evidence-plan/tickets/2026-09-24-e1-recorded-runs.md`, ticket E1, which owns AC3, AC6 and AC7.
That spec lives in the captain's private firstmate home, not in this repository.

This branch is the firstmate half of E1: `bin/fm-evidence.sh` and `tests/fm-completion-evidence.test.sh`.
The public spec-lock checker's half of AC6 and AC7, validating the committed binding, belongs to the later lane fleet-evidence-e1-lock, which will build on the binding contract below.
Activation is off: no landing path calls `fm-evidence.sh verify` yet; E5 owns that wiring.

## How it works

Firstmate approves each acceptance command for a task with `assign`, naming the command's argv, spec, criterion, timeout and output bound, and the task's independent verifier, which is another recorded task with its own worktree.
The verifier runs each approved command with `capture` on one exact commit and records its verdict with `judge`.
The author renders that evidence into its lane with `attach` and names the manifest in its proof.
`verify` resolves the committed claim against the records in the home and prints the completion report.

The actor behind every call is the recorded task whose worktree holds the current directory.
No argument and no committed field can name the executor or the judge.
`assign` refuses any caller inside a task worktree, so a worker cannot choose the command that grades it.
Same-user files are not a security boundary against a hostile process; the records say who ran what, they do not attest it.

## AC3

AC3: when a ship task requests verified completion, the fleet obtains an independent execution of each approved acceptance command on the exact reviewed revision, with executor and judge provenance distinct from the author, and refuses missing, mismatched, failed or incomplete runs.

`capture` reads the exact commit's tree from the task's repository into a scratch checkout and runs the approved argv there, with no shell and no stdin, under `env -i` with only `PATH`, a scratch `HOME` and a scratch `TMPDIR`, bounded by the approved timeout.
It writes a started record before the command runs and the final record after, so an interrupted capture leaves a record with no exit.
It records a timeout, a tracked file changed by the run, or output over the declared bound, and each of those can never verify.

Tests in `tests/fm-completion-evidence.test.sh`, each on its own fixture home and project (author t1, verifier v1, command k1, reviewed revision C, fixture input 7 that must produce 14):

- `test_ac3_independent_run_on_the_reviewed_revision_is_verified`: v1's run of `node test/value.mjs` on C prints `value=14`, exits 0 and verifies; the report names v1 and the judge record.
- `test_ac3_author_only_run_is_refused_even_with_a_forged_executor`: t1's own run is refused as `executor: run t1-r1 was executed by t1, not the independent verifier v1`, even after the author edits the manifest to say v1.
- `test_ac3_unapproved_command_and_author_approval_are_refused`: capturing k2 is refused; the author approving its own command, the author as its own verifier, and a caller whose worktree two tasks claim are refused.
- `test_ac3_run_on_another_revision_is_refused`: a run on C2, a descendant of C, cannot vouch for C.
- `test_ac3_author_environment_never_reaches_the_run`: with `SKIP_TESTS=1` exported and a `.env` holding `SKIP_TESTS=1` in both worktrees, the captured output is still `value=14` and the record keeps no inherited variable.
- `test_ac3_failed_run_is_refused` (exit 1), `test_ac3_unsupported_verdict_is_refused`, `test_ac3_interrupted_run_is_refused` (capture killed, exit null), `test_ac3_timed_out_run_is_refused`, `test_ac3_run_killed_by_a_signal_is_refused` (exit 137), `test_ac3_output_over_its_bound_is_refused`, `test_ac3_run_that_rewrites_a_tracked_file_is_refused`, and `test_ac3_every_approved_command_needs_a_claim`.

## AC6

AC6: when the fleet publishes a verified completion result, it renders the exact executed command, reviewed revision, observed exit and captured output reference from the run record, and refuses absent or altered evidence bytes.

`verify` prints, for each claim, lines rendered from the run record, never from the proof's prose.
This is its output in the walk at `517290b2`:

```
verified: t1 at 8b2816af6f4cf58ab43215a1cfd3a85eac5bf715 (reviewed e55dc9eba22a38f922854b8feec6d9ca149b1a22, base 08bcf1454f6cfbe16d927a3cee1664a6ce4b00f2)
AC1 docs/specs/value.md: run t1-r2 by v1, judged t1-j2 by v1 (supported)
  Ran: node test/value.mjs
  Revision: e55dc9eba22a38f922854b8feec6d9ca149b1a22
  Exit: 0
  Observed: stdout docs/proof/t1.evidence/t1-r2.stdout (9 bytes, sha256 e41cdd0474e463c82e1bda285008ad1d002ebc878fe67155b4f706608c5aa98a)
  Observed: stderr docs/proof/t1.evidence/t1-r2.stderr (0 bytes, sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)
```

Tests:

- `test_ac6_report_renders_the_run_record` asserts the Ran, Revision, Exit and Observed lines, with the digest computed from the captured bytes.
- `test_ac6_absent_or_altered_evidence_bytes_are_refused` removes the captured output in the home, commits a hand-written `PASS` line in place of the output, removes the committed output file, and alters the manifest's digest; each is refused and names the output field, and the untouched candidate verifies again afterwards.
- `test_ac6_unrelated_receipt_is_refused` cites a real run recorded for another task, t2, and is refused as `run: unknown run t2-r1 for t1`.
- `test_ac6_empty_output_needs_zero_length_artifacts`: a command with no output verifies with zero-length committed files, and is refused once the empty stderr file is removed.

The spec-lock half, the `spec-lock check` command rejecting a corrupted committed attachment, is fleet-evidence-e1-lock.

## AC7

AC7: when a fleet completion claim is emitted or consumed, the fleet resolves its evidence ids against the same repository, task, spec, acceptance criterion, reviewed revision and independent judge record, and rejects stale or cross-task evidence.

The reviewed revision C must be the candidate P or an ancestor of it, and every change from C to P must add or edit a regular file under `docs/proof/`.
That is exact identity, not ancestry: code committed after C invalidates the evidence even though C is still an ancestor.

Tests:

- `test_ac7_proof_only_commits_after_the_review_pass`: proof and attachment commits after C, including a later prose repair, verify, and the result names C, the run and the judge.
- `test_ac7_code_after_the_reviewed_revision_is_refused`: a code commit after C is refused as `candidate: src/value.mjs changed after the reviewed revision <C>`.
- `test_ac7_old_run_after_a_rebase_is_refused`: after the lane's commit is rewritten, the old run is refused both ways the manifest can name it, and a fresh run on the rewritten commit (id t1-r2) verifies.
- `test_ac7_mismatched_bindings_are_refused`: a claim with no judge, a forged well-shaped run id `t1-r99`, a manifest for task t2, a claim naming `docs/specs/s2.md` with its own AC1, and a substituted judge digest are each refused.
- `test_ac7_review_on_another_base_is_refused`: a judge that reviewed against a base that is not an ancestor of C is refused, and so is a manifest whose base differs from the judge's.
- `test_ac7_changed_command_is_refused`: re-approving k1 with a different argv refuses the run of the old form.

The spec-lock half, diagnostics naming the mismatched field for a malformed committed binding, is fleet-evidence-e1-lock.

## Binding contract

This is the committed format the public checker will validate.
Every path is relative to the repository root.

The proof names its manifest in its front matter, beside `spec:`:

```markdown
---
spec: docs/specs/feature.md
evidence: docs/proof/<name>.evidence.json
---
```

The manifest is a JSON object, version 1:

| Field | Meaning |
|---|---|
| `version` | `1` |
| `task` | the task the claim is for |
| `reviewed` | the full commit id C that was reviewed and run |
| `base` | the full commit id of the review base, an ancestor of C |
| `claims[]` | one per criterion: `spec` (path), `spec_blob` (the spec's blob id at C), `ac` (`AC<n>`), `state` (`supported` or `unsupported`), `run` (a run id), `judge` (a judge id) |
| `runs[]` | `id`, `executor`, `command_id`, `argv` (array of strings), `revision`, `exit` (integer, or null when the run never exited), `outcome` (`exited`, `timeout`, `started`, `tracked-files-changed` or `output-over-bound`), `stdout` and `stderr`, each `{path, bytes, sha256}` or null |
| `judges[]` | `id`, `judge`, `run`, `ac`, `revision`, `base`, `evidence` (`{stdout_sha256, stderr_sha256}`), `verdict` (`supported` or `unsupported`) |

This manifest came from a run of the walk script; the judge's `evidence` digests and the run's `stderr` entry are left out here for length:

```json
{
  "base": "aa0fb1272e57d7bed7c4beca2990fdb79184a669",
  "claims": [{ "ac": "AC1", "judge": "t1-j2", "run": "t1-r2", "spec": "docs/specs/value.md",
               "spec_blob": "692b48c2ef7d4f83ee6f2f129a0551ce772cd1d3", "state": "supported" }],
  "judges": [{ "ac": "AC1", "base": "aa0fb1272e57d7bed7c4beca2990fdb79184a669", "id": "t1-j2", "judge": "v1",
               "revision": "f1cbbac648650060a0fee070e771ed5aab75a426", "run": "t1-r2", "verdict": "supported" }],
  "reviewed": "f1cbbac648650060a0fee070e771ed5aab75a426",
  "runs": [{ "argv": ["node", "test/value.mjs"], "command_id": "k1", "executor": "v1", "exit": 0, "id": "t1-r2",
             "outcome": "exited", "revision": "f1cbbac648650060a0fee070e771ed5aab75a426",
             "stdout": { "bytes": 9, "path": "docs/proof/t1.evidence/t1-r2.stdout",
                         "sha256": "e41cdd0474e463c82e1bda285008ad1d002ebc878fe67155b4f706608c5aa98a" } }],
  "task": "t1",
  "version": 1
}
```

Given a candidate commit P, the public checker can validate these from committed objects alone, and each refusal names its field:

1. `evidence` is a path under `docs/proof/` with no empty, `.` or `..` segment, and is a regular file at P holding a JSON object with `version` 1.
2. `reviewed` and `base` are full commit ids (40 or 64 hex digits, never a prefix); `base` is an ancestor of `reviewed`; `reviewed` is P or an ancestor of P; and every path that differs between `reviewed` and P is an added or edited regular file (mode 100644) under `docs/proof/`, with no deletion, rename, symlink or executable.
3. Each claim's `spec` is a regular file at `reviewed` whose blob id is `spec_blob`, and its `ac` is a live criterion of that spec.
4. Each claim's `run` and `judge` name exactly one entry in `runs[]` and `judges[]`, and that judge's `run` is the claim's run and its `ac` is the claim's `ac`.
5. Each claimed run has `revision` equal to `reviewed`, `outcome` `exited` and `exit` 0, and non-null `stdout` and `stderr` whose `path` is under `docs/proof/`, is a regular file at P, and has exactly `bytes` bytes with SHA-256 `sha256`; a zero-length file is valid only when it is present.
6. Each claimed judge has `revision` equal to `reviewed`, `base` equal to the manifest's `base`, `evidence` equal to its run's two digests, and `verdict` `supported`, and the claim's `state` is `supported`.

The public checker cannot establish who ran or judged anything: `executor` and `judge` are copies for reading, and it never executes a command or fetches a private record.
Firstmate's `verify` adds what only the home knows: each run and judge id must be a record of that task in the home, executed and judged by the assigned verifier and not the author, for the command still approved in the same form, with the home's captured bytes matching the manifest and the committed files, and every approved command must have a supported claim.

## Red before green

The test file was written before the script, but its first run came after the script existed, so there is no whole-suite red from a missing script, which would only have shown a missing binary anyway.
The first real run caught a defect: `test_ac7_code_after_the_reviewed_revision_is_refused` failed with `not ok - ac7-code: completion should be refused: expected exit 1, got 0`, because an `A || B && C || D` test in the candidate check let a code change through.
That check is now a `case` over status and mode.
Three tests were added after reviewing the script and before fixing it: `test_ac3_run_killed_by_a_signal_is_refused`, the ambiguous-worktree case in `test_ac3_unapproved_command_and_author_approval_are_refused`, and the fresh-run half of `test_ac7_old_run_after_a_rebase_is_refused`.
Their red is shown by the controls below, which put each defect back.

## Controls

Each control ran at `517290b2`: it copied `bin/` and `tests/` into a throwaway directory, applied one mutation to the copy's `bin/fm-evidence.sh`, and ran only the named test there; the worktree was never edited.
The unmutated copy passed: `none: exit 0: ok - AC3: an independent run of the approved command on the reviewed revision verifies`.

| AC | Mutation | Result |
|---|---|---|
| AC3 | Take the executor from the manifest instead of the run record (trust a worker-supplied executor field) | `not ok - ac3-author: refusal did not name the reason (missing: 'executor: run t1-r1 was executed by t1')` |
| AC3 | Match the run's revision by ancestry instead of equality | `not ok - ac3-rev: refusal did not name the reason (missing: 'revision: run t1-r1 ran on 8f1f8c5208a9629776a4c09abc1096b0ecafdcee, not the reviewed revision 6b93e28e66ccdd8f7984302919ad66059c0a44a0')` |
| AC3 | Drop `env -i` so the caller's environment reaches the run | `not ok - ac3-env: SKIP_TESTS or a .env reached the run: skipped` |
| AC3 | Run in the author's worktree instead of the scratch checkout | `not ok - ac3-env: SKIP_TESTS or a .env reached the run: skipped` |
| AC3 | Drop the wrapper that records the command's own exit status | `not ok - ac3-signal: completion should be refused: expected exit 1, got 0` |
| AC3 | Let an ambiguous caller through as firstmate | `not ok - ac3-unapproved: an actor that two tasks claim must not read as firstmate: expected exit 2, got 0` |
| AC6 | Accept a missing captured output file | `not ok - ac6-bytes-native: completion should be refused: expected exit 1, got 0` |
| AC6 | Accept a missing committed output file | `not ok - ac6-empty: completion should be refused: expected exit 1, got 0` |
| AC7 | Replace the identity check with ancestry only | `not ok - ac7-code: completion should be refused: expected exit 1, got 0` |
| AC7 | Reissue a run id after its claim is removed | `not ok - <tmp>/ac7-rebase: capture from <tmp>/ac7-rebase/wt-v1 failed:` (the second capture reused `t1-r1`) |

In the two AC3 provenance rows the claim was still refused, by the separate check that the manifest's copy of each run field matches the record, but without the named reason, so the test failed as required.

## What I walked

I walked commit `517290b2` on macOS 27.0 with GNU bash 5.3.15, git 2.54.0 and node 22.22.0, running the real `bin/fm-evidence.sh` against a fresh scratch firstmate home and a synthetic project under the system temp directory, with `GIT_CONFIG_GLOBAL=/dev/null` and no network.
The project's default branch held a constant-zero program at B, and the author's lane fm/t1 committed the doubling repair as C.
The author t1 and the verifier v1 were recorded tasks, each with its own worktree of that project.

1. From t1's worktree, `assign t1 --verifier t1 ...` printed `error: the verifier cannot be the author t1` and exited 2.
2. From the scratch root, which is no task's worktree, `assign t1 --verifier v1 --command-id k1 --spec docs/specs/value.md --ac AC1 --timeout 30 -- node test/value.mjs` printed `approved k1 for t1: AC1 of docs/specs/value.md, verified by v1`.
3. From t1's worktree, the same assign with `node -e 'console.log("value=14")'` printed `error: only firstmate approves acceptance commands; t1 is a recorded task` and exited 2.
4. From t1's worktree, `capture t1 --command-id k1 --revision <C>` printed `run t1-r1 exited exit=0 revision=<C> by t1`.
   v1 judged it supported, t1 attached it, wrote the proof naming the manifest, and committed.
   `verify t1` printed `refused: t1 at <P>` and `- executor: run t1-r1 was executed by t1, not the independent verifier v1`, exit 1.
5. After resetting the lane to C, from v1's worktree, `capture` printed `run t1-r2 exited exit=0 revision=<C> by v1`, and the recorded stdout was `value=14`.
   v1 judged it supported against B, t1 attached it and committed P, and `git diff --stat C P` showed only `docs/proof/t1.evidence.json`, the two output files and `docs/proof/t1.md`.
6. `verify t1` printed `verified: t1 at <P> (reviewed <C>, base <B>)` and the report shown under AC6, exit 0.
7. t1 then committed a code change to `src/value.mjs` on top.
   `verify t1` printed `- candidate: src/value.mjs changed after the reviewed revision <C>`, exit 1.
8. v1 captured the new commit: `run t1-r3 exited exit=1`, judged it unsupported, and t1 attached it.
   `verify t1` refused with `- run: run t1-r3 exited 1`, `- judge: t1-j3 found AC1 unsupported`, and `- claim: no supported claim for approved command k1 (AC1 of docs/specs/value.md)`.
9. The home held `assignment.json`, `runs/t1-r1` to `runs/t1-r3` (each `record.json`, `stdout`, `stderr`) and `judges/t1-j1.json` to `judges/t1-j3.json`.

An earlier pass of the same walk, whose script forgot to rewrite the proof after resetting the lane, got `unchecked: docs/proof/t1.md is not in the candidate <P>` from `verify`, which is the intended result for a claim with no proof.

I did not walk a real verifier crewmate or the code-review Evidence reviewer: that reviewer's instructions change only when the patch below is applied, and the canary tasks through each delivery mode belong to E5.

## Evidence reviewer instructions

The proposed change to `/Users/evanagee/.agents/skills/code-review/SKILL.md` is `/Users/evanagee/Sites/firstmate/data/fleet-evidence-e1/code-review-evidence.patch`.
It keeps "you run nothing" as the default, and when firstmate names the session a task's evidence verifier it has the Evidence sub-agent run each approved command through `capture` and record its verdict through `judge`.
It also says that a run from the author's worktree, including one by a sub-agent of the author's session, is recorded as the author's and never verifies.
`git -C /Users/evanagee/.agents apply --check` accepts it; it is not applied.

## Checks run locally

- `bin/fm-lint.sh bin/fm-evidence.sh tests/fm-completion-evidence.test.sh` printed only `fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)`.
- `bash tests/fm-completion-evidence.test.sh` at `517290b2` printed 23 `ok` lines and no `not ok`.
- `bin/fm-test-run.sh --check-coverage` printed `FM_TEST_COVERAGE ok total=197 parallel=24 serial=161 serial_shards=8 herdr=12`, with the new test in the portable-serial lane.
- `bin/fm-doc-audience-check.sh` on the final tree printed `fm-doc-audience-check: ok surfaces=159 local_links=310`, and `tests/fm-documentation-audiences.test.sh` printed three `ok` lines.
- `npx unslop` on the changed shell and Markdown files printed `No supported files found.`

## Follow-ups, not fixed here

- `fm_run_timed` in `bin/fm-timeout-lib.sh` returns 0 for a command killed by a signal on its perl path, which is the path on macOS without coreutils: `fm_run_timed 5 bash -c "kill -SEGV \$\$"` printed `rc=0`.
  `capture` records the command's own status through a wrapper, so this lane does not depend on it, but other callers do.
- AC6 also names the implement skill as an owner: its proof guidance could point at the rendered Ran, Revision, Exit and Observed lines instead of a pasted output line.
  This lane changed only the Evidence reviewer text it was asked for.
- `verify` checks that the review base is an ancestor of C and is the judge's base; tying it to the current target branch, calling `verify` from the landing wrappers, and calling the shared checker for committed structure are E5's.
