---
tags: [spec-gate, spec-point, landing]
date: 2026-09-24
---

# Spec pointing finds the lane's real spec among index files and design specs

The captain approved this on 2026-09-24 ("yes", after picking the fix that prefers the brief-named spec).

## Problem Statement

Before a local landing, firstmate runs `bin/fm-spec-point.sh <task>` to point a brief still on `Spec: to-spec phase` at the spec its lane wrote, because the captain's spec gate refuses the landing until the brief names a real spec.
The command counts every `docs/specs/*.md` the lane changed and requires exactly one, so it refuses lanes that wrote a valid spec:

- Two aos-light-2 lanes on 2026-09-24, `harness-light-unmapped-specs` and `harness-r39-core-host-fixes`, each changed its own spec plus `docs/specs/MAP.md`, the repo's spec index, which every new spec with a rows table must now join.
  The command refused both with "changed 2 specs", and R15 hit the same refusal earlier.
- Harness slices in the candidate aos repo write their spec at `docs/design/<date>-harness-core-light-<slug>-spec.md`, which the command never looks at, so R12 was refused with "changed 0 specs".

Each time firstmate set the brief's `Spec:` line by hand, the hand edit the command exists to remove.

## Solution

The command picks the lane's spec in two steps.

1. When the brief's `# Spec first` section names a spec path in backticks (the scaffold writes `docs/specs/<task>.md` there) and the lane changed that file, that file is the spec.
   It must lint clean, or the command refuses with the linter's output.
2. Otherwise the command lints every changed `docs/specs/*.md` and `docs/design/*-spec.md` and drops each file that fails.
   Exactly one must remain.
   An index such as `MAP.md` never lints as a spec, so no list of index file names is needed.

When zero or several files remain, the command still refuses and leaves the brief untouched, and the refusal names each changed candidate with whether it lints clean or was dropped, plus the linter's faults for each dropped file.

## Seams

- `bin/fm-spec-point.sh` as a command - existing - `tests/fm-spec-point.test.sh` already builds a fixture firstmate home and a scratch project with a lane worktree and supplies the linter through `FM_SPEC_LINT`; the rewritten brief is exactly what the spec gate reads, so nothing sits higher.

## User Stories

### US1 - Point the brief at the spec the brief asked for (P1)

As firstmate, I want the command to prefer the spec the brief told the worker to write, so that a lane that also updates a spec index or another spec still lands without a hand edit.
**Independent Test:** run the command against a lane that changed its brief-named spec and a second spec, and read the brief's `Spec:` line.
**Criteria:** AC1, AC5

### US2 - Find the one real spec among candidates (P1)

As firstmate, I want the command to ignore changed files that are not specs and to look in `docs/design/` too, so that index files and design-folder specs stop causing refusals.
**Independent Test:** run the command against a lane that changed one spec plus `docs/specs/MAP.md`, and against a lane whose only spec is `docs/design/<date>-...-spec.md`.
**Criteria:** AC2, AC3

### US3 - Refusals say why (P2)

As firstmate, I want a refusal to name every candidate and why it was kept or dropped, so that I can tell the worker exactly what to fix.
**Independent Test:** run the command against a lane with two real specs and an index, and read the refusal.
**Criteria:** AC4

## Decisions

- The captain chose the fix that prefers the brief-named spec, falling back to the lint filter when the brief names none or the lane did not change it.
- Candidate specs are the changed `docs/specs/*.md` and `docs/design/*-spec.md` files; the lint filter, not a file-name list, excludes index files such as `MAP.md`.
- Refusals stay refusals for zero or several real specs, and the refusal names each candidate and why it was dropped.
- Tests extend `tests/fm-spec-point.test.sh`, whose stub linter fails any file containing `BADSPEC`.

## Acceptance Criteria

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | While a task's brief says `Spec: to-spec phase`, when its `# Spec first` section names a spec path in backticks that the lane changed and that file lints clean, `bin/fm-spec-point.sh` shall rewrite the brief's first `Spec:` line to that path, even when the lane changed other specs that lint clean. | `tests/fm-spec-point.test.sh` case `test_points_at_the_brief_named_spec_among_others` writes a brief whose Spec first section names `docs/specs/t9.md` and a lane that commits `docs/specs/t9.md` and `docs/specs/other.md`, both passing the stub linter; assert exit 0 and the `Spec:` line reads `Spec: docs/specs/t9.md`. **Skip the brief-named lookup and prove AC1 goes red, because two clean specs are refused.** | `bin/fm-spec-point.sh t9` prints `pointed t9's brief at docs/specs/t9.md`. | `tests/fm-spec-point.test.sh` |
| AC2 | While a task's brief says `Spec: to-spec phase` and names no spec the lane changed, when the lane changed several candidate files and exactly one lints clean, `bin/fm-spec-point.sh` shall drop the files that fail the linter and point the brief at the one that remains. | `tests/fm-spec-point.test.sh` case `test_drops_a_spec_index_that_does_not_lint` writes a brief with no Spec first section and a lane that commits `docs/specs/widget.md` and `docs/specs/MAP.md`, where the stub linter fails `MAP.md`; assert exit 0 and the `Spec:` line reads `Spec: docs/specs/widget.md`. **Count every changed candidate without linting it and prove AC2 goes red with `changed 2 specs`.** | With the real `spec-lint`, `bin/fm-spec-point.sh t2` prints `pointed t2's brief at docs/specs/t2.md` for a lane that also changed `docs/specs/MAP.md`. | `tests/fm-spec-point.test.sh` |
| AC3 | The `bin/fm-spec-point.sh` command shall treat each changed `docs/design/*-spec.md` as a candidate spec alongside `docs/specs/*.md`, and shall ignore other files under `docs/design/`. | `tests/fm-spec-point.test.sh` case `test_points_at_a_design_folder_spec` builds a lane that commits `docs/design/2026-09-24-harness-core-light-r12-spec.md` and `docs/design/notes.md`; assert exit 0 and the `Spec:` line reads `Spec: docs/design/2026-09-24-harness-core-light-r12-spec.md`. **Drop the `docs/design/*-spec.md` pathspec and prove AC3 goes red with `changed 0 specs`.** | `bin/fm-spec-point.sh t3` prints `pointed t3's brief at docs/design/2026-09-24-harness-core-light-r12-spec.md`. | `tests/fm-spec-point.test.sh` |
| AC4 | If zero or more than one changed candidate lints clean, then `bin/fm-spec-point.sh` shall exit 1, leave the brief unchanged, say how many lint clean, and name each changed candidate as `lints clean` or `dropped, does not lint` followed by the linter's faults. | `tests/fm-spec-point.test.sh` case `test_refuses_two_real_specs_and_names_each_candidate` builds a lane that commits `docs/specs/a.md`, `docs/specs/b.md`, and `docs/specs/MAP.md`, where the stub linter fails only `MAP.md`; assert exit 1, stderr contains `changed 2 specs that lint clean`, `docs/specs/a.md: lints clean`, `docs/specs/b.md: lints clean`, `docs/specs/MAP.md: dropped, does not lint`, and `- missing section: Seams`, and the brief's bytes are unchanged. **Leave the per-candidate lines out of the refusal and prove AC4 goes red.** | `bin/fm-spec-point.sh t4` prints `refused: ... changed 2 specs that lint clean ...` followed by one line per candidate, and exits 1. | `tests/fm-spec-point.test.sh` |
| AC5 | If the brief-named spec was changed by the lane but fails the linter, then `bin/fm-spec-point.sh` shall exit 1, print the linter's faults, and leave the brief unchanged, even when another changed spec lints clean. | `tests/fm-spec-point.test.sh` case `test_refuses_a_brief_named_spec_that_does_not_lint` writes a brief whose Spec first section names `docs/specs/bad.md` and a lane that commits `docs/specs/bad.md` (fails the stub) and `docs/specs/good.md` (passes); assert exit 1, stderr contains `- missing section: Seams` and `docs/specs/bad.md`, and the brief's bytes are unchanged. **Fall through to the lint filter when the brief-named spec fails and prove AC5 goes red, because the brief is pointed at `docs/specs/good.md`.** | `bin/fm-spec-point.sh t5` prints the linter's faults and `refused: docs/specs/bad.md, which t5's brief names, does not lint clean`, and exits 1. | `tests/fm-spec-point.test.sh` |

## End-to-end verification

Run the fixed command with the captain's real `spec-lint` against a scratch home whose lane reproduces the aos-light-2 case: its own spec plus the real `docs/specs/MAP.md` index.

```sh
fm=$(git rev-parse --show-toplevel)   # a firstmate checkout on this branch
d=$(mktemp -d); home="$d/home"; proj="$d/proj"; wt="$d/wt"
mkdir -p "$home/state" "$home/data"
git init -q -b main "$proj"; echo x > "$proj/README.md"
git -C "$proj" add -A; git -C "$proj" commit -qm init
FM_HOME="$home" "$fm/bin/fm-brief.sh" t1 proj --mode local-only
git -C "$proj" worktree add -q -b fm/t1 "$wt"
mkdir -p "$wt/docs/specs"
cp "$fm/docs/specs/fm-spec-point-design-specs.md" "$wt/docs/specs/t1.md"
printf '# Map of areas\n\n- Widget: `docs/specs/t1.md`\n' > "$wt/docs/specs/MAP.md"
git -C "$wt" add -A; git -C "$wt" commit -qm work
printf '%s\n' "project=$proj" "worktree=$wt" mode=local-only kind=ship > "$home/state/t1.meta"
FM_HOME="$home" "$fm/bin/fm-spec-point.sh" t1; grep '^Spec:' "$home/data/t1/brief.md"
```

Expected: the command prints `pointed t1's brief at docs/specs/t1.md` and the brief's line reads `Spec: docs/specs/t1.md`.
The same fixture run through the command at the pre-change commit is refused with `changed 2 specs under docs/specs/`.
Failure looks like any refusal from the fixed command, or a `Spec:` line still on `to-spec phase`.

## Non-goals

- The spec gate hook and `spec-lint` stay as they are; they belong to the captain's skills, not to firstmate.
- No list of index file names such as `MAP.md`: the linter already tells a spec from an index, and a list would need edits for every new index.
- The command does not search folders other than `docs/specs/` and `docs/design/`, because no lane has written a spec anywhere else.
- The command still never checks the proof's acceptance criterion ids; the hook owns that check at landing.
- A brief that already names a spec is still left alone.

## Open questions

None.

## Further Notes

Two behaviors here are the implementer's call, not the captain's words.
A brief-named spec that fails the linter is refused rather than passed over for another candidate, because pointing a brief at a spec other than the one it asked for would hide the worker's broken spec.
Only a backticked path in the `# Spec first` section counts as the brief naming a spec, because that is the one place the scaffold writes it.
This spec supersedes the counting rule in AC5 and AC6 of `docs/specs/fm-spec-gate-brief-and-landing.md`.
