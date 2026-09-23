---
tags: [specs, upstream, rebase, spec-lint]
date: 2026-09-23
issue: fm-spec-catchup-upstream-rebase
walked: a5cdcbb8
---

# Upstream rebase spec in the hardened shape

## What I walked

I walked commit `a5cdcbb8`, rebased onto `main` at `4d80f458`, with `origin/c/main` at `7530c480`.
Nothing in the live home, the trial home, or `c/main` was changed.

### Reconciling what is done

`git log origin/c/main` holds every C0 to C7 port, C1b, C6b, and the red-baseline fix, and each matches its Done record in the live home's `data/done-archive.md` (for example C4 "Landed on c/main as e96d12db", C3 "landed on c/main as 323a8887", red baseline "c/main fast-forwarded to 0491f54c; CI green run 35794810970").
`tasks-axi show fm-upstream-c8-dnth-extras --full` and `tasks-axi show fm-upstream-c9-shakedown-swap --full` both read `state: queued`, with bodies "Ticket C8. Optional; after C1 to C7." and "Ticket C9. Last."
Four gaps were not in the spec on `main`, so they became the remaining work:

- `git log --abbrev=8 --format=%h 40094579..main -- bin tests .agents skills .github AGENTS.md skills-lock.json` lists 25 fork commits, and `git cat-file -e origin/c/main:bin/fm-ci-watch.sh` and the same check for `bin/fm-treehouse-sweep.sh` both fail, so `c/main` lacks them.
- `git log --oneline origin/c/main..kun/main` counts 34 root commits past `c/main`'s base `43bf6d3d`, now at `9296f9b9`; that became an open question, not a criterion.
- `git -C /Users/evanagee/Sites/firstmate-trial rev-parse --abbrev-ref HEAD` prints `c/main`, and the trial home's `config/crew-dispatch.json` rules carry only `use`, `when`, and `why`, so both digest faults from the 2026-09-23 switch still stand.
- `git show origin/c/main:docs/specs/upstream-rebase.md` fails spec-lint, as shown below.

### spec-lint

```
$ /Users/evanagee/.agents/skills/spec-lint/spec-lint /Users/evanagee/.treehouse/firstmate-df5ff1/4/firstmate/docs/specs/upstream-rebase.md
spec-lint: ok (8 acceptance criteria: AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8)
exit=0
$ git show a5cdcbb8:docs/specs/upstream-rebase.md | /Users/evanagee/.agents/skills/spec-lint/spec-lint -
spec-lint: ok (8 acceptance criteria: AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8)
exit=0
$ git show origin/c/main:docs/specs/upstream-rebase.md | /Users/evanagee/.agents/skills/spec-lint/spec-lint -
spec-lint: not a spec in the hardened shape (7 faults)
- missing section: Problem Statement
- missing section: Seams
- missing section: Acceptance Criteria
- missing section: End-to-end verification
- missing section: Non-goals
- missing section: Open questions
- no acceptance criteria table with columns: AC, Requirement, Red test, Observable, Judge
exit=1
```

The last run is AC3's red state at base.

### Each criterion against its seam

| AC | Seam | What I checked |
| --- | --- | --- |
| AC1 | `bin/fm-test-run.sh` on a `c/main` worktree | `bin/fm-test-run.sh tests/fm-treehouse-sweep.test.sh` on `main` printed `ok - fm-treehouse-sweep guarded classification and tier gates hold` and `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0`, so the test to carry over runs through the root's runner. The mutation's failure text, "the default pass executed a destructive treehouse verb", is the test's own `fail` line. The script and the test are absent from `c/main`, so AC1 is red there. |
| AC2 | git refs | I pulled the ledger check verbatim out of the spec's step-1 block and ran it. Against `origin/c/main` it printed 25 `unsettled` lines. Against the seeded ledger read from a file it printed 25. With every row set to `ported` at `7530c480` it printed nothing. With one row set back to `pending` it printed `unsettled 63ba6402`. With one row ported to `d7b17a13`, which is not on `c/main`, it printed `not on c/main 98d35d28 -> d7b17a13`. With one row `dropped` with a reason it printed nothing. |
| AC3 | git refs | The spec-lint runs above: the `c/main` copy exits 1 with 7 faults today, and this commit's copy exits 0 through the same stdin form End-to-end verification step 2 uses. |
| AC4 | trial home session start | The switch digest recorded at `7530c480` holds both lines, and the two read-only checks above show neither cause has cleared. I did not run session start in the trial home, because that would take its session lock. |
| AC5 | trial home task records | Testable only by running the shakedown. Its observables are the trial home's `data/backlog.md` Done entries and `state/<id>.status` lines, which the digest seam reads, and its judge is Evan Agee. Nothing has run there since the switch; its `data/` holds only `archive-2026-09-trial`. |
| AC6 | a scratch `FM_HOME` session start | The rehearsal command in step 4 reads only copies of the live `data/` and `config/`, keeps `projects/` empty so the fleet sync has nothing to reach, and sets `FM_API=0`. I did not run it, because it needs a `c/main` worktree at the shakedown SHA, so its state at base is unmeasured, as the spec says. The live `config/crew-dispatch.json` rules do carry `class`, which is the field the trial home's config lacks. |
| AC7 | git refs and a scratch clone, then the live home | Every assertion is a ref command: `git diff --quiet`, `git rev-parse` of the preserved ref, `git ls-remote origin`, and `gh run list --commit`, whose flag `gh run list --help` lists as `-c, --commit SHA`. The live step is judged by Evan Agee. |
| AC8 | git refs and a scratch clone, then the live home | The rehearsal asserts `git rev-parse main` against the recorded pre-swap SHA and a locked digest on the clone. The mutation deletes the preserved ref, which that assertion depends on. A live rollback is judged by Evan Agee. |

### Superseded blob spec

`git diff --stat 4d80f458 a5cdcbb8` shows `docs/specs/aos-offline-runtime-to-blob.md | 7 +` with no deletions.
The new header cites aos `84d4d59d8` and the 3.93 MiB bundled runtime, and names aos `docs/specs/2026-09-21-aos-function-docs-tracing-exclusion.md` as the current authority.
I read that file at `84d4d59d8` in `/Users/evanagee/Sites/firstmate/projects/aos`; its "Wrong-premise history" section says "The runtime therefore stays bundled."
