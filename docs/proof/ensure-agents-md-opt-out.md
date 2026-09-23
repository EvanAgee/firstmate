---
tags: [project-memory, fm-ensure-agents-md, opt-out]
date: 2026-09-23
issue: fm-ensure-agents-md-light-claude
walked: 61eb4f1a3fa42eb9d4babe6073d87f96c1d6f475
---

# Opt-out for fm-ensure-agents-md

Spec: [`docs/specs/ensure-agents-md-opt-out.md`](../specs/ensure-agents-md-opt-out.md).

## What I walked

I walked commit `61eb4f1a` on macOS.
I ran the real `bin/fm-ensure-agents-md.sh` against scratch git repos in the session scratchpad, then deleted them.
Each repo's `AGENTS.md` was committed before the run, so `git status --short` shows exactly what the script wrote.
Exit codes came from a second run that did not pipe the output.
Below, `<walk>` stands for the scratch directory.

### AC1: an `AGENTS.md` with the marker gets no pointer and no section

- Fixture repo `with`: a committed `AGENTS.md` ending in `<!-- fm-ensure-agents-md: off -->`, no `## Maintaining this file` section, and no `CLAUDE.md`.
- The script printed `skipped: <walk>/with opts out with <!-- fm-ensure-agents-md: off -->; left AGENTS.md and CLAUDE.md untouched` and exited 0.
- `git status --short` was empty, and `ls` showed only `AGENTS.md`.
- A re-run printed the same `skipped:` line, and the status stayed empty.
- A `git worktree add` of `with` also printed `skipped:` with an empty status, so the tracked marker reaches a fresh worktree.
- Test: `test_opt_out_agents_md_gets_no_pointer_or_section` passes.
  It failed against the pre-change script, which printed `updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer`.
  It failed again on a throwaway copy where the opt-out check was replaced with `if false`.

### AC2: a CRLF `CLAUDE.md` with the marker is not promoted

- Fixture repo `claude-only`: a committed CRLF `CLAUDE.md` carrying the marker, and no `AGENTS.md`.
- The script printed `skipped: <walk>/claude-only opts out with <!-- fm-ensure-agents-md: off -->; left AGENTS.md and CLAUDE.md untouched` and exited 0.
- `git status --short` was empty, and `ls` showed only `CLAUDE.md`.
- Test: `test_opt_out_crlf_claude_md_is_not_promoted` passes.
  It failed against the pre-change script, which printed `promoted: moved CLAUDE.md to AGENTS.md`.
  It failed again on a throwaway copy with the `\r` marker variant dropped from the grep.

### AC3: a project without the marker behaves as before

- Fixture repo `without`: the same committed `AGENTS.md` as `with`, minus the marker line.
- The script printed `updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in <walk>/without` and exited 0.
- `git status --short` showed ` M AGENTS.md` and `?? CLAUDE.md`.
- The four-sentence section ended `AGENTS.md`, and `CLAUDE.md` held the two-line `@AGENTS.md` pointer.
- A re-run printed `unchanged: AGENTS.md with CLAUDE.md @AGENTS.md pointer in <walk>/without`.
- Tests: the sixteen cases in `tests/fm-ensure-agents-md.test.sh` that predate this change all pass.
  On a throwaway copy where the opt-out check was replaced with `if true`, they failed, starting with `AGENTS.md was not created`.

### AC4: a FIFO `CLAUDE.md` is refused without hanging

- Fixture directory `fifo`: a real `AGENTS.md` plus `mkfifo CLAUDE.md`.
- The script printed `conflict: CLAUDE.md exists in <walk>/fifo but is not a regular file or symlink`, exited 1, and took under a second.
- Test: `test_fifo_claude_md_is_refused_without_hanging` passes.
  On a throwaway copy without `-D skip`, it failed with `fm-ensure-agents-md.sh blocked reading a FIFO CLAUDE.md` after its five-second watchdog.

### AC5: the ship brief exempts an opted-out project

- I ran `FM_HOME=<walk>/home bin/fm-brief.sh walk-ac5 some-proj --mode no-mistakes`.
  Line 94 of the generated `brief.md` reads "If you touch a project `AGENTS.md` that lacks `## Maintaining this file`, add that short self-governance section from `.../bin/fm-ensure-agents-md.sh` in the same pass, unless the project carries that script's opt-out line."
- Test: `test_ship_project_memory_wording` in `tests/fm-brief.test.sh` passes.
  Before I added the clause to the brief, it failed with `project-memory contract would have a crewmate hand-add the section to an opted-out project`.

### Checks run at the walked commit

- `bash tests/fm-ensure-agents-md.test.sh`: 19 `ok` lines, exit 0.
- `bash tests/fm-brief.test.sh`: exit 0.
- `/Users/evanagee/.agents/skills/spec-lint/spec-lint` on the spec: `spec-lint: ok (5 acceptance criteria: AC1, AC2, AC3, AC4, AC5)`.
- GitHub Actions run https://github.com/EvanAgee/firstmate/actions/runs/35897654894 passed on the implementation commit `d7b17a13`.
  One test group failed first in `tests/fm-remote-job.test.sh`, with "remote job worker did not report ready after startup".
  That test touches no file in this change, and it passed on rerun.
