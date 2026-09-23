---
tags: [brief, spec-gate, merge-local, landing]
date: 2026-09-23
issue: fm-spec-gate-brief-and-landing
walked: fb2944b6839225b1000ac93a018d7e9c2e28a322
---

# Briefs carry the spec contract, and local landing tolerates unrelated local changes

Spec: [`docs/specs/fm-spec-gate-brief-and-landing.md`](../specs/fm-spec-gate-brief-and-landing.md).

## What I walked

I walked commit `fb2944b6` on macOS 27.0 with GNU bash 5.3.15 and git 2.54.0.
Every run used the real `bin/fm-brief.sh`, `bin/fm-spec-point.sh`, and `bin/fm-merge-local.sh` from this branch against a fresh scratch firstmate home.
The spec gate in every run was the captain's real hook, `~/.agents/skills/spec-lint/spec-gate`, fed the same hook JSON Claude Code sends, and the linter was the real `~/.agents/skills/spec-lint/spec-lint`.
For the before picture I extracted the pre-change commit `cd0143e0` with `git archive` and ran its scripts on the same fixtures.

### Walk 1: scaffold, spawn gate, point, land, refuse

The fixture was a scratch project on `main` tracking `telemetry/knobs.jsonl` and `shared.txt`, and a lane worktree `fm/t1` that committed `src/feature.txt`, a copy of this task's spec as `docs/specs/t1.md`, and `docs/proof/t1.md` listing the ids `spec-lint --ids` printed.

1. The pre-change `fm-brief.sh t1 proj --mode local-only` wrote a brief with no `Spec:` line, and the hook denied `fm-spawn.sh old1 --mode local-only` with `has no "Spec:" line naming its spec`.
2. The new scaffold wrote `Spec: to-spec phase` and a `# Spec first` section naming `docs/specs/t1.md`, the lint command `/Users/evanagee/.agents/skills/spec-lint/spec-lint docs/specs/t1.md`, `docs/proof/t1.md`, and the done line.
   The hook printed nothing for `fm-spawn.sh t1 --mode local-only`, which is an allow.
3. With `--spec /Users/evanagee/.treehouse/firstmate-df5ff1/3/firstmate/docs/specs/fm-spec-gate-brief-and-landing.md` the brief's line was `Spec: <that path>`, and the hook linted the spec and allowed the spawn.
4. Before pointing, the hook denied `fm-merge-local.sh t1` with `t1's brief still says "Spec: to-spec phase"`.
5. `fm-spec-point.sh t1` printed `pointed t1's brief at docs/specs/t1.md` and exited 0, and the brief's `Spec:` line read `Spec: docs/specs/t1.md`.
   A second run printed `t1's brief already names docs/specs/t1.md; nothing to point` and exited 0.
6. After pointing, the hook printed nothing for `fm-merge-local.sh t1`, so it found every id in the lane's proof.
7. I then edited `telemetry/knobs.jsonl` to `{"k":2}` and added untracked `records/run-1/out.json`; `git status --short` showed ` M telemetry/knobs.jsonl` and `?? records/`.
   The pre-change `fm-merge-local.sh t1` refused with `has a dirty working tree; refusing to merge into it` and exited 1.
8. The new `fm-merge-local.sh t1` printed `merged fm/t1 into local main (7bec7e5 -> 67b8f2d)` and `left 2 unrelated local change(s) ... untouched`, and exited 0.
   `main` and `fm/t1` both pointed at `67b8f2d`, `git status --short` still showed ` M telemetry/knobs.jsonl` and `?? records/`, and the file still held `{"k":2}`.
9. A second lane `fm/t2` committed an edit to `telemetry/knobs.jsonl`.
   `fm-merge-local.sh t2` printed `error: local changes overlap the landing in <project>; refusing to merge into it:` then `  telemetry/knobs.jsonl`, and exited 1.
   `main` stayed at `67b8f2d` and the file still held `{"k":2}`.

### Walk 2: a clone carrying aos-light-2's real local changes

I cloned `/Users/evanagee/Sites/memory.net/aos-light-2` into the scratchpad, read only from the source, and copied in its real local state: the modified `telemetry/knobs.jsonl` and every untracked file, 256 entries in `git status --porcelain --untracked-files=all`.

1. A lane that only appended to `README.md` landed: `merged fm/aos1 into local main (3b81de9 -> 6d754d4)` and `left 256 unrelated local change(s) ... untouched`.
   After the landing the checkout still had 256 local entries, and `cmp` found `telemetry/knobs.jsonl` byte-identical to the real checkout's copy.
2. A lane that edited `telemetry/knobs.jsonl` and added `records/review/board.findings.json`, a path the checkout already held untracked, was refused and named both paths.
   `main` stayed at `6d754d4`.

### Acceptance criteria

Each criterion's test passes on this branch.
For each one I also ran a control: I extracted `git archive HEAD` into a throwaway directory, applied the mutation the spec names, and ran only that test there.
Every mutation went red for the stated reason, and an unmutated copy of each suite ran green.

- AC1: `test_spec_option_writes_the_named_spec` in `tests/fm-brief.test.sh` passes.
  Dropping the `Spec: $SPEC` line failed it with `--spec did not become the brief's first Spec: line (got: )`.
- AC2: `test_ship_brief_defaults_to_spec_first` passes for all three ship modes.
  Emptying the section when no `--spec` is given failed it with `no-mistakes: brief without --spec did not say Spec: to-spec phase (got: )`.
- AC3: `test_spec_option_is_ship_only` passes.
  Removing the ship-only check failed it with `scout: --spec should be refused: expected exit 1, got 0`.
- AC4: `test_matt_flow_requires_a_spec` passes.
  Removing the `--matt-flow` requirement failed it with `--matt-flow without --spec should be refused: expected exit 1, got 0`.
  The existing Matt-flow cases in `tests/fm-brief.test.sh` now pass `--spec`.
- AC5: `points a to-spec-phase brief at its one linted spec` in `tests/fm-spec-point.test.sh` passes.
  Skipping the rewrite failed it with `point: brief was not rewritten to exactly the spec line`.
- AC6: the zero-spec and two-spec cases pass.
  Accepting more than one spec failed the two-spec case with `two: a lane with two specs should be refused: expected exit 1, got 0`.
- AC7: `refuses a spec that does not lint` passes.
  Ignoring the linter's status failed it with `lint: a spec that fails the linter should be refused: expected exit 1, got 0`.
- AC8: `leaves an already-pointed brief alone` passes.
  Dropping the early exit failed it because the two-spec lane was refused: `refused: t8's lane ... changed 2 specs under docs/specs/`.
- AC9: `test_local_only_lands_past_unrelated_local_changes` in `tests/fm-merge-local.test.sh` passes.
  Restoring the refusal of any dirty checkout failed it with `landing past unrelated local changes failed`, followed by the old `has a dirty working tree` error.
- AC10: `test_overlapping_local_changes_refuse_the_landing` passes for the edited, added, and file-over-directory fixtures.
  Deleting the overlap check failed it with `overlap-edited: refusal did not say the local changes overlap`, because git's own refusal carries different wording.

### Checks run locally

- `bin/fm-lint.sh` exited 0 under the pinned ShellCheck 0.11.0.
- `tests/fm-brief.test.sh` (43 ok), `tests/fm-spec-point.test.sh` (5 ok), and `tests/fm-merge-local.test.sh` (14 ok) exited 0.
- `tests/fm-ask-user-authority.test.sh`, `tests/fm-decision-hold-lifecycle.test.sh`, `tests/fm-subagent-pretool-check.test.sh`, and `tests/fm-tangle-guard.test.sh` also scaffold briefs, and each exited 0.
- `tests/fm-agents-coverage.test.sh`, `tests/fm-agents-size.test.sh`, `tests/fm-documentation-audiences.test.sh`, and `bin/fm-doc-audience-check.sh` exited 0.
- `npx unslop` on the changed files printed `No supported files found.`, since it reads neither shell nor Markdown.
