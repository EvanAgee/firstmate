---
tags: [project-memory, fm-ensure-agents-md, opt-out]
date: 2026-09-23
---

# Opt-out for fm-ensure-agents-md

This spec describes behavior already built on branch `fm/fm-ensure-agents-md-light-claude`.
The captain said "go" on 2026-09-23.

## Problem Statement

`bin/fm-ensure-agents-md.sh` always writes a `CLAUDE.md` `@AGENTS.md` pointer and injects a `## Maintaining this file` section into a project's `AGENTS.md`.
Some projects read `CLAUDE.md` or `AGENTS.md` as their own instructions, so those writes change what the project's own tooling loads.
aos-light-2 is one: its `src/instructions.mjs` lists both files in `REPO_FILES`, and its census requires a registry claim for every file.
On 2026-09-23 a harness builder found both writes in aos-light-2 and had to revert them.
Nothing lets a project tell the script to leave its memory files alone.

## Seams

- `bin/fm-ensure-agents-md.sh [dir]`: a directory in; memory files written or left alone, one stdout line, and an exit code out.
  Tested through `tests/fm-ensure-agents-md.test.sh`, which builds fixture directories under a temp root and runs the real script.
- `bin/fm-brief.sh`: the ship brief's project-memory section, the instruction a crewmate reads before touching a project `AGENTS.md`.
  Tested through `tests/fm-brief.test.sh`, which scaffolds a real brief and reads the generated text.

## Acceptance Criteria

The opt-out marker is the exact whole line `<!-- fm-ensure-agents-md: off -->`, with an optional trailing carriage return.

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | When a project's `AGENTS.md` carries the opt-out marker line, fm-ensure-agents-md.sh shall exit 0, print a `skipped:` line, write no `CLAUDE.md`, and leave `AGENTS.md` byte-identical with no injected section. | `test_opt_out_agents_md_gets_no_pointer_or_section`; fixture: an `AGENTS.md` with the marker and no `CLAUDE.md`. Replacing the opt-out check with `if false` turns it red with "opted-out project did not report skipped". The pre-change script also failed it by printing "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer". | In a scratch git repo whose committed `AGENTS.md` carries the marker, running the script prints `skipped:` and `git status --short` stays empty. | tests/fm-ensure-agents-md.test.sh |
| AC2 | When a project has only a real `CLAUDE.md` that carries the opt-out marker line, with LF or CRLF line endings, fm-ensure-agents-md.sh shall exit 0, print a `skipped:` line, create no `AGENTS.md`, and leave `CLAUDE.md` byte-identical. | `test_opt_out_crlf_claude_md_is_not_promoted`; fixture: a CRLF `CLAUDE.md` with the marker and no `AGENTS.md`. Dropping the `\r` marker variant from the grep turns it red. The pre-change script also failed it by printing "promoted: moved CLAUDE.md to AGENTS.md". | Running the script on a directory like that fixture prints `skipped:`, and no `AGENTS.md` appears. | tests/fm-ensure-agents-md.test.sh |
| AC3 | If neither `AGENTS.md` nor `CLAUDE.md` carries the opt-out marker line, then fm-ensure-agents-md.sh shall create, promote, inject, write the pointer, and refuse exactly as it did before this change. | The existing sixteen cases in `tests/fm-ensure-agents-md.test.sh`, such as `test_created_agents_md_includes_self_governance`; fixtures: empty, `AGENTS.md`-only, `CLAUDE.md`-only, symlink, CRLF, and conflict directories. Replacing the opt-out check with `if true` turns them red, starting with "AGENTS.md was not created". | In a scratch git repo without the marker, the script prints "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer". A re-run prints "unchanged:". | tests/fm-ensure-agents-md.test.sh |
| AC4 | If `CLAUDE.md` is a FIFO, then fm-ensure-agents-md.sh shall refuse with a `conflict:` line and a non-zero exit without blocking on a read of the FIFO. | `test_fifo_claude_md_is_refused_without_hanging`; fixture: a real `AGENTS.md` plus `mkfifo CLAUDE.md`, with a five-second watchdog that unblocks the reader. Removing `-D skip` from the opt-out grep turns it red with "fm-ensure-agents-md.sh blocked reading a FIFO CLAUDE.md". | The test's watchdog run finishes at once with the `conflict:` refusal. | tests/fm-ensure-agents-md.test.sh |
| AC5 | When fm-brief.sh scaffolds a ship brief, the project-memory section shall exempt a project that carries the opt-out line from the rule to hand-add `## Maintaining this file`. | `test_ship_project_memory_wording` asserts "unless the project carries that script's opt-out line"; fixture: a no-mistakes ship brief for `some-proj`. The brief text without that clause turned it red with "project-memory contract would have a crewmate hand-add the section to an opted-out project". | The generated `brief.md` Project memory section carries the clause. This session's own launch brief showed the old sentence without it. | tests/fm-brief.test.sh |

## End-to-end verification

On a scratch machine directory, create two git repos with a committed `AGENTS.md` that lacks `## Maintaining this file` and has no `CLAUDE.md`, and add the marker line to only one.
Run `bin/fm-ensure-agents-md.sh` on each and read its output and `git status --short`.
The marked repo prints `skipped:` and stays clean.
The unmarked repo gains the section and the two-line pointer, exactly as before.
Re-run both, then add a `git worktree` of the marked repo and run the script there.
The marked worktree prints `skipped:` and stays clean, which shows the tracked marker reaches a fresh worktree.
The proof at `docs/proof/ensure-agents-md-opt-out.md` records what this walk showed.

## Non-goals

- Adding the marker to aos-light-2 is a separate step for firstmate, and this change does not touch that repo.
- A per-project setting in firstmate-private config, such as `data/projects.md`.
- Opting out of only the pointer or only the section.
- Detecting on its own which projects read `CLAUDE.md` as instructions.
- Any special case for a project name in code.

## Open questions

None.
