---
tags: [spec-gate, spec-point, landing]
date: 2026-09-24
issue: fm-spec-point-design-specs
walked: e07e45dbb682e269f3e6f5f93f1439492f79fa89
---

# Spec pointing finds the lane's real spec among index files and design specs

Spec: [`docs/specs/fm-spec-point-design-specs.md`](../specs/fm-spec-point-design-specs.md).

## What I walked

I walked commit `e07e45db` on macOS 27.0 with GNU bash 5.3.15 and git 2.54.0.
Every walk used the real `bin/fm-brief.sh` and `bin/fm-spec-point.sh` from this branch against a fresh scratch firstmate home, with the captain's real linter at `~/.agents/skills/spec-lint/spec-lint`.
For the before picture I extracted the pre-change commit `c50fc8ec` with `git archive` and ran its `fm-spec-point.sh` on the same fixtures.
Each lane was a scratch project on `main` with a worktree on `fm/<task>`, and each brief came from `fm-brief.sh <task> proj --mode local-only`, so its `# Spec first` section named `docs/specs/<task>.md`.

### Walk 1: the aos-light-2 case, own spec plus the real MAP.md

The lane committed a copy of this task's spec as `docs/specs/t1.md`, the real `/Users/evanagee/Sites/memory.net/aos-light-2/docs/specs/MAP.md` with a row for `t1.md` appended, and `docs/proof/t1.md` listing the ids `spec-lint --ids` printed.

1. The pre-change command printed `refused: t1's lane in <wt> changed 2 specs under docs/specs/ against main: docs/specs/MAP.md docs/specs/t1.md; it must change exactly one`, exited 1, and the brief still read `Spec: to-spec phase`.
2. The fixed command printed `pointed t1's brief at docs/specs/t1.md`, exited 0, and the brief read `Spec: docs/specs/t1.md`.
3. The captain's real hook, `~/.agents/skills/spec-lint/spec-gate`, fed the hook JSON for `fm-merge-local.sh t1`, printed nothing and exited 0, which is an allow.

### Walk 2: MAP.md plus a spec the brief does not name

The lane committed a real spec as `docs/specs/widget.md` and the real aos-light-2 `MAP.md`, while the brief named `docs/specs/t2.md`.

1. The pre-change command refused with `changed 2 specs under docs/specs/ against main: docs/specs/MAP.md docs/specs/widget.md` and exited 1.
2. The fixed command printed `pointed t2's brief at docs/specs/widget.md` and exited 0, because the real linter fails `MAP.md` with 7 faults.

### Walk 3: a design-folder spec only

The lane committed a real spec as `docs/design/2026-09-24-harness-core-light-r12-spec.md` and a plain `docs/design/notes.md`.

1. The pre-change command refused with `changed 0 specs under docs/specs/ against main` and exited 1, as R12 was refused.
2. The fixed command printed `pointed t3's brief at docs/design/2026-09-24-harness-core-light-r12-spec.md` and exited 0, and it ignored `notes.md`.

### Walk 4: two real specs plus MAP.md, none named by the brief

The lane committed two real specs as `docs/specs/a.md` and `docs/specs/b.md`, plus the real `MAP.md`.
The fixed command exited 1, left the brief on `Spec: to-spec phase`, and printed:

```
refused: t4's lane in <wt> changed 2 specs that lint clean among docs/specs/*.md and docs/design/*-spec.md against main; it must change exactly one
  docs/specs/MAP.md: dropped, does not lint:
    spec-lint: not a spec in the hardened shape (7 faults)
    - missing section: Problem Statement
    - missing section: Seams
    - missing section: Acceptance Criteria
    - missing section: End-to-end verification
    - missing section: Non-goals
    - missing section: Open questions
    - no acceptance criteria table with columns: AC, Requirement, Red test, Observable, Judge
  docs/specs/a.md: lints clean
  docs/specs/b.md: lints clean
```

### Walk 5: the brief-named spec fails the linter

The lane committed a non-spec `docs/specs/t5.md`, which the brief names, and a real spec as `docs/specs/good.md`.
The fixed command printed the linter's 7 faults, then `refused: docs/specs/t5.md, which t5's brief names, does not lint clean; the worker fixes it before landing`, exited 1, and left the brief on `Spec: to-spec phase`.

### Walk 6: this lane's own brief

This branch changes two specs, its own and `docs/specs/fm-spec-gate-brief-and-landing.md`, which it updates to point at the new rule.
I copied this task's real brief into a scratch home and recorded this worktree as the task's worktree.

1. The pre-change command refused with `changed 2 specs under docs/specs/ against main: docs/specs/fm-spec-gate-brief-and-landing.md docs/specs/fm-spec-point-design-specs.md`.
2. The fixed command printed `pointed fm-spec-point-design-specs's brief at docs/specs/fm-spec-point-design-specs.md` and exited 0.

So this landing needs the fixed command, run from this branch with `FM_HOME` set to the landing home, or a hand-set `Spec:` line.

## Acceptance criteria

The red run used the new tests in the working tree on top of commit `33d826ca`, whose script was still the old one: the five new cases failed and the five existing cases passed.
The green runs below are at `e07e45db`.
Each mutation ran on a throwaway copy of every tracked file, never on the worktree, and an unmutated control copy passed all ten cases first.

- AC1: `test_points_at_the_brief_named_spec_among_others` in `tests/fm-spec-point.test.sh` failed on the old script with `changed 2 specs under docs/specs/ against main: docs/specs/other.md docs/specs/t9.md` and passes now.
  Replacing the brief-named lookup's `if [ -n "$named" ] &&` with `if false &&` turned it red again with `changed 2 specs that lint clean`.
  Walks 1 and 6 show it on the real surface.
- AC2: `test_drops_a_spec_index_that_does_not_lint` failed on the old script with `changed 2 specs ... docs/specs/MAP.md docs/specs/widget.md` and passes now.
  Replacing the lint filter's check with `if true; then` turned it red with `changed 2 specs that lint clean`.
  Walk 2 shows it with the real linter.
- AC3: `test_points_at_a_design_folder_spec` failed on the old script with `changed 0 specs under docs/specs/` and passes now.
  Dropping the `'docs/design/*-spec.md'` pathspec turned it red with `changed 0 specs that lint clean`.
  Walk 3 shows it.
- AC4: `test_refuses_two_real_specs_and_names_each_candidate` failed on the old script with `missing: 'changed 2 specs that lint clean'` and passes now.
  Leaving the per-candidate lines out of the refusal turned it red with `missing: 'docs/specs/a.md: lints clean'`.
  Walk 4 shows the full refusal.
- AC5: `test_refuses_a_brief_named_spec_that_does_not_lint` failed on the old script with `missing: '- missing section: Seams'` and passes now.
  Requiring the brief-named spec to lint before taking it, so a failing one falls through to the lint filter, turned it red with `expected exit 1, got 0`.
  Walk 5 shows it.

## Checks

- `bash tests/fm-spec-point.test.sh` printed 10 `ok` lines and exited 0.
- `bash tests/fm-brief.test.sh` printed 43 `ok` lines and exited 0 after the scaffold's landing line changed.
- `bin/fm-lint.sh` exited 0 under the pinned ShellCheck 0.11.0.
- `spec-lint` passes both `docs/specs/fm-spec-point-design-specs.md` (AC1 to AC5) and the edited `docs/specs/fm-spec-gate-brief-and-landing.md` (AC1 to AC10).
- `bin/fm-doc-audience-check.sh` exited 0.
