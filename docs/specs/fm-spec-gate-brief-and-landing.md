---
tags: [brief, spec-gate, merge-local, landing]
date: 2026-09-23
---

# Briefs carry the spec contract, and local landing tolerates unrelated local changes

The captain approved both parts on 2026-09-23 ("2: do it", "4: ok").

## Problem Statement

On 2026-09-23 the captain made the hardened spec format mandatory for every work item.
A Claude Code hook outside this repo (`spec-gate`, from the captain's `spec-lint` skill) now refuses two firstmate commands:

- `bin/fm-spawn.sh` for a ship task whose brief has no `Spec:` line.
  `Spec: to-spec phase` passes for a task whose first job is writing its spec.
- `bin/fm-merge-local.sh <task>` unless the brief's `Spec:` line names a spec that lints clean and the lane branch's changed `docs/proof/*.md` names every acceptance criterion id of that spec.
  A brief still on `Spec: to-spec phase` is refused.

`bin/fm-brief.sh` writes no `Spec:` line, so firstmate hand-added `Spec: to-spec phase` to 12 briefs that day.
Before each landing it then hand-edited the brief to the spec path the worker wrote, and two landings were refused until it did.

Separately, `bin/fm-merge-local.sh` refuses any dirty project checkout, even when the local changes have nothing to do with the files the landing changes.
The main checkout of `/Users/evanagee/Sites/memory.net/aos-light-2` always carries a modified `telemetry/knobs.jsonl` and untracked `records/` folders, so firstmate has been landing there with a plain `git merge --ff-only` outside the guarded path.
That skips the guarded path's mode gate, its delivery record, and its push-then-close sequence.

## Solution

`bin/fm-brief.sh` gains `--spec <issue URL | owner/repo#N | path>` for ship briefs.
With it, the brief carries `Spec: <value>` and one line telling the worker to name every acceptance criterion id of that spec in `docs/proof/<task>.md`.
Without it, the brief carries `Spec: to-spec phase` and a short standing "Spec first" section: write `docs/specs/<task>.md` in the `to-spec` template's shape, lint it, prove every acceptance criterion in `docs/proof/<task>.md`, and name the spec path in the done line.
Scout and secondmate scaffolds stay as they are, and refuse `--spec`.
A `--matt-flow` brief requires `--spec`, because a Matt-flow brief declares its spec phase done and enters at `tdd`, which a spec-first section would contradict.

A new command, `bin/fm-spec-point.sh <task>`, points a brief still on `Spec: to-spec phase` at the one spec its lane branch added or changed.
It lints that spec first and refuses loudly when the branch changed no spec, more than one, or one that does not lint.
Firstmate runs it on its own before `bin/fm-merge-local.sh`, because the hook judges each command before that command runs.

`bin/fm-merge-local.sh` lands past local changes in the project's main checkout when none of them touches a path the fast-forward changes.
It still refuses when they overlap, and it still refuses a branch that is not a fast-forward.
It never stashes, discards, or rewrites the local changes.

## Seams

- `bin/fm-brief.sh` as a command - existing - `tests/fm-brief.test.sh` already scaffolds briefs into a fixture home and reads the generated file; the brief file is the only thing the worker and the hook read, so nothing sits higher.
- `bin/fm-spec-point.sh` as a command - **new** - a fixture firstmate home plus a scratch project with a lane worktree, with the linter supplied through `FM_SPEC_LINT`; the rewritten brief is exactly what the hook reads, and no existing command can host this step because the hook must see the pointed brief before the landing command starts.
- `bin/fm-merge-local.sh` as a command - existing - `tests/fm-merge-local.test.sh` already lands scratch projects through the real script; the project checkout and its default branch are the landing's whole observable result.

## User Stories

### US1 - A spec-first brief with no hand edits (P1)

As firstmate, I want the scaffold to write the brief's spec contract, so that a ship spawn passes the spec gate without my editing the brief.
**Independent Test:** scaffold a local-only ship brief with no `--spec` and read its `Spec:` line and its Spec first section.
**Criteria:** AC1, AC2, AC3, AC4

### US2 - Point the brief before landing (P1)

As firstmate, I want one command to point a to-spec-phase brief at the spec its branch wrote, so that the landing command passes the spec gate without my editing the brief.
**Independent Test:** run `bin/fm-spec-point.sh` against a task whose branch added one linted spec and read the brief's `Spec:` line.
**Criteria:** AC5, AC6, AC7, AC8

### US3 - Land past unrelated local changes (P1)

As firstmate, I want the guarded local landing to work in a checkout that carries unrelated local changes, so that I never fall back to a plain `git merge --ff-only`.
**Independent Test:** land a lane branch into a scratch checkout holding a modified unrelated tracked file and an untracked folder.
**Criteria:** AC9, AC10

## Decisions

- The captain chose a separate pointing command over folding the step into the landing command, because the hook judges a command before it runs.
- A pointed brief names the spec by its path relative to the task worktree, which is where the hook resolves a relative path at landing time.
- The pointing command reads the lane from the task's recorded worktree and diffs its checked-out commit against the project's default branch, because the hook reads the spec file from that same worktree.
- The linter is the captain's `spec-lint`, at `~/.agents/skills/spec-lint/spec-lint` unless `FM_SPEC_LINT` names another; tests supply a stub through `FM_SPEC_LINT`, because CI has no copy of the captain's skills.
- The overlap rule for landing compares paths, not contents: a local path overlaps when it equals a path the fast-forward changes, lies inside one, or contains one.
  Local changes come from `git status` with every untracked file listed and renames split; the fast-forward's changes come from the diff between the default branch and the lane with renames split.
- Tests stay beside the existing ones: `tests/fm-brief.test.sh`, `tests/fm-merge-local.test.sh`, and a new `tests/fm-spec-point.test.sh`.

## Acceptance Criteria

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | When `bin/fm-brief.sh` scaffolds a ship brief with `--spec <value>`, the scaffold shall write `Spec: <value>` as the brief's first `Spec:` line, one line requiring every acceptance criterion id of that spec in `docs/proof/<task>.md`, and no Spec first section. | `tests/fm-brief.test.sh` case `test_spec_option_writes_the_named_spec` scaffolds `spec-named` with `--mode local-only --spec EvanAgee/firstmate#140`; assert the first `^Spec:` line is exactly `Spec: EvanAgee/firstmate#140`, the proof line names `docs/proof/spec-named.md`, and `# Spec first` is absent. **Drop the `Spec: $SPEC` line from the scaffold and prove AC1 goes red.** | `bin/fm-brief.sh t1 proj --mode local-only --spec EvanAgee/firstmate#140` then `grep '^Spec:' data/t1/brief.md` prints `Spec: EvanAgee/firstmate#140`. | `tests/fm-brief.test.sh` |
| AC2 | When `bin/fm-brief.sh` scaffolds a ship brief without `--spec`, the scaffold shall write `Spec: to-spec phase` as the brief's first `Spec:` line and a Spec first section that names `docs/specs/<task>.md`, the lint command, `docs/proof/<task>.md`, and the done line. | `tests/fm-brief.test.sh` case `test_ship_brief_defaults_to_spec_first` scaffolds one brief per ship mode with `FM_SPEC_LINT=/opt/lint/spec-lint`; assert the first `^Spec:` line is `Spec: to-spec phase`, and the section contains `docs/specs/<id>.md`, `/opt/lint/spec-lint docs/specs/<id>.md`, `docs/proof/<id>.md`, and `done line`. **Skip the Spec first section when no `--spec` is given and prove AC2 goes red.** | `bin/fm-brief.sh t2 proj --mode local-only` then `sed -n '/^# Spec first/,/^# /p' data/t2/brief.md` prints the section. | `tests/fm-brief.test.sh` |
| AC3 | If `--spec` is given to a scout or secondmate scaffold, then `bin/fm-brief.sh` shall exit non-zero, name `--spec` in its error, and write no brief. | `tests/fm-brief.test.sh` case `test_spec_option_is_ship_only` runs `fm-brief.sh s1 proj --scout --spec o/r#1` and `fm-brief.sh s2 --secondmate --no-projects --spec o/r#1`; assert exit 1, stderr contains `--spec`, and no `brief.md` exists. **Accept `--spec` on every kind and prove AC3 goes red.** | `bin/fm-brief.sh s1 proj --scout --spec o/r#1; echo $?` prints the error and `1`. | `tests/fm-brief.test.sh` |
| AC4 | If `--matt-flow` is given without `--spec`, then `bin/fm-brief.sh` shall exit non-zero, name `--spec` in its error, and write no brief. | `tests/fm-brief.test.sh` case `test_matt_flow_requires_a_spec` runs `fm-brief.sh mf proj --mode local-only --matt-flow`; assert exit 1, stderr contains `--spec`, and no `brief.md` exists. **Remove the `--matt-flow` spec requirement and prove AC4 goes red.** | `bin/fm-brief.sh mf proj --mode local-only --matt-flow; echo $?` prints the error and `1`. | `tests/fm-brief.test.sh` |
| AC5 | While a task's brief says `Spec: to-spec phase`, when `bin/fm-spec-point.sh <task>` finds exactly one `docs/specs/*.md` that the task worktree's commit added or changed against the default branch and that spec lints clean, the command shall rewrite the brief's first `Spec:` line to `Spec: <that path>` and leave every other byte of the brief unchanged. | `tests/fm-spec-point.test.sh` case `points a to-spec-phase brief at its one linted spec` builds a scratch project whose lane worktree commits `docs/specs/widget.md`, a brief with `Spec: to-spec phase` between two fixed lines, and a stub linter that passes; assert exit 0, the `Spec:` line reads `Spec: docs/specs/widget.md`, and the brief equals the original with only that line changed. **Skip the brief rewrite and prove AC5 goes red.** | `bin/fm-spec-point.sh t5` prints `pointed t5's brief at docs/specs/widget.md`, and `grep '^Spec:'` on the brief prints `Spec: docs/specs/widget.md`. | `tests/fm-spec-point.test.sh` |
| AC6 | If the task worktree's commit changed no `docs/specs/*.md` or more than one, then `bin/fm-spec-point.sh` shall exit non-zero, say how many it found and list them, and leave the brief unchanged. | `tests/fm-spec-point.test.sh` cases `refuses a branch that changed no spec` (lane commits only `src/a.txt`) and `refuses a branch that changed two specs` (lane commits `docs/specs/a.md` and `docs/specs/b.md`); assert exit 1, stderr names `0` or both paths, and the brief's bytes are unchanged. **Point at the first changed spec instead of refusing more than one, and prove AC6 goes red.** | `bin/fm-spec-point.sh t6` prints `refused: ... changed 2 specs: docs/specs/a.md docs/specs/b.md` and exits 1. | `tests/fm-spec-point.test.sh` |
| AC7 | If the one changed spec fails the linter, then `bin/fm-spec-point.sh` shall exit non-zero, print the linter's output, and leave the brief unchanged. | `tests/fm-spec-point.test.sh` case `refuses a spec that does not lint` uses a stub linter that prints `- missing section: Seams` and exits 1; assert exit 1, stderr contains that fault, and the brief's bytes are unchanged. **Ignore the linter's exit status and prove AC7 goes red.** | `bin/fm-spec-point.sh t7` prints the linter's faults and exits 1. | `tests/fm-spec-point.test.sh` |
| AC8 | While a task's brief already names a spec other than `to-spec phase`, when `bin/fm-spec-point.sh <task>` runs, the command shall leave the brief unchanged, say which spec it names, and exit 0. | `tests/fm-spec-point.test.sh` case `leaves an already-pointed brief alone` seeds `Spec: EvanAgee/firstmate#140` and a lane that changed two specs; assert exit 0, stdout contains `EvanAgee/firstmate#140`, and the brief's bytes are unchanged. **Drop the already-pointed early exit and prove AC8 goes red, because the two-spec lane is refused.** | `bin/fm-spec-point.sh t8` prints `t8's brief already names EvanAgee/firstmate#140` and exits 0. | `tests/fm-spec-point.test.sh` |
| AC9 | While the project checkout holds uncommitted or untracked files and none of them overlaps a path the fast-forward changes, when `bin/fm-merge-local.sh` lands a local-only task, the command shall fast-forward the default branch and leave each of those files with the same bytes and the same uncommitted or untracked state. | `tests/fm-merge-local.test.sh` case `test_local_only_lands_past_unrelated_local_changes` builds a project whose `main` tracks `telemetry/knobs.jsonl`, modifies that file and adds untracked `records/run-1/out.json`, and a lane branch that adds `src/feature.txt`; assert exit 0, `main` equals the lane tip, and both files keep their bytes and their `git status` codes. **Restore the refusal of any dirty checkout and prove AC9 goes red.** | `bin/fm-merge-local.sh t9` prints `merged fm/t9 into local main (...)`, and `git status --short` still shows ` M telemetry/knobs.jsonl` and `?? records/run-1/out.json`. | `tests/fm-merge-local.test.sh` |
| AC10 | If any uncommitted or untracked path in the project checkout equals, lies inside, or contains a path the fast-forward changes, then `bin/fm-merge-local.sh` shall exit non-zero naming each overlapping path, leave the default branch where it was, and leave every local file unchanged. | `tests/fm-merge-local.test.sh` case `test_overlapping_local_changes_refuse_the_landing` runs three fixtures: a local edit to `shared.txt`, which the lane also edits; an untracked `new.txt`, which the lane adds; and an untracked `notes/draft.md` where the lane adds a file named `notes`. Assert exit 1, stderr contains `local changes overlap` and the path, `main` is unmoved, and the local file keeps its bytes. **Delete the overlap check and prove AC10 goes red, because git's own refusal lacks that wording.** | `bin/fm-merge-local.sh t10` prints `error: ... local changes overlap the landing: shared.txt` and exits 1. | `tests/fm-merge-local.test.sh` |

## End-to-end verification

Run the whole chain against a scratch home and a scratch project with the captain's real `spec-lint` and `spec-gate`.
The walk scaffolds a spec-first brief, has a lane worktree commit a real spec and a proof that names every id, points the brief, asks the real hook whether the landing command may run, lands past an unrelated dirty file and an untracked folder, and then is refused on an overlapping file.

```sh
fm=$(git rev-parse --show-toplevel)   # a firstmate checkout on this branch
d=$(mktemp -d); home="$d/home"; proj="$d/proj"; wt="$d/wt"
mkdir -p "$home/state" "$home/data"
git init -q -b main "$proj"
mkdir -p "$proj/telemetry"; echo '{"k":1}' > "$proj/telemetry/knobs.jsonl"
git -C "$proj" add -A; git -C "$proj" commit -qm init
FM_HOME="$home" "$fm/bin/fm-brief.sh" t1 proj --mode local-only
grep '^Spec:' "$home/data/t1/brief.md"                     # Spec: to-spec phase
git -C "$proj" worktree add -q -b fm/t1 "$wt"
mkdir -p "$wt/docs/specs" "$wt/docs/proof"
cp "$fm/docs/specs/fm-spec-gate-brief-and-landing.md" "$wt/docs/specs/t1.md"
"$HOME/.agents/skills/spec-lint/spec-lint" --ids "$wt/docs/specs/t1.md" | tr '\n' ' ' > "$wt/docs/proof/t1.md"
git -C "$wt" add -A; git -C "$wt" commit -qm work
printf '%s\n' "project=$proj" "worktree=$wt" mode=local-only kind=ship > "$home/state/t1.meta"
FM_HOME="$home" "$fm/bin/fm-spec-point.sh" t1
grep '^Spec:' "$home/data/t1/brief.md"                     # Spec: docs/specs/t1.md
jq -n --arg c "$fm/bin/fm-merge-local.sh t1" --arg h "$home" '{tool_name:"Bash",tool_input:{command:$c},cwd:$h}' \
  | FM_HOME="$home" "$HOME/.agents/skills/spec-lint/spec-gate"; echo "hook printed the line above (empty means allow)"
echo '{"k":2}' > "$proj/telemetry/knobs.jsonl"; mkdir -p "$proj/records/run-1"; echo x > "$proj/records/run-1/out.json"
FM_HOME="$home" "$fm/bin/fm-merge-local.sh" t1; git -C "$proj" status --short
```

Expected: the first `grep` prints `Spec: to-spec phase`, `fm-spec-point` prints that it pointed the brief at `docs/specs/t1.md`, the hook prints nothing, the landing prints `merged fm/t1 into local main`, and `git status --short` still shows ` M telemetry/knobs.jsonl` and `?? records/`.
A second lane that edits `telemetry/knobs.jsonl`, landed the same way, is refused with `local changes overlap the landing: telemetry/knobs.jsonl`, and `main` stays put.
Failure looks like a hook deny naming `to-spec phase`, or a landing refused for a dirty working tree.

## Non-goals

- The `spec-gate` hook and `spec-lint` stay as they are; they belong to the captain's skills, not to firstmate.
- `bin/fm-spec-point.sh` does not check the proof's acceptance criterion ids; the hook already checks them at landing, and a second copy of that rule would drift.
- The landing command does not point the brief itself, because the hook has already judged the landing command by the time it runs.
- A `--spec` value is written as given; the scaffold does not resolve or validate issue references or paths, because the hook validates them at spawn.
- Ignored files in the project checkout stay out of the overlap rule, as they stay out of today's clean check.
- The landing still requires the checkout to be on its default branch, and a diverged lane is still refused.
- `bin/fm-spawn.sh`, the outage landing rules, and the push-then-close sequence are unchanged.

## Open questions

None.

## Further Notes

The brief delegated the pointing seam and the landing overlap rule to the implementer ("pick the smallest reliable seam"), so the Decisions above that are not the captain's words record those picks.
The `--matt-flow` requirement for `--spec` is the implementer's call too: without it, a Matt-flow brief would both declare its spec done and demand a spec first.
