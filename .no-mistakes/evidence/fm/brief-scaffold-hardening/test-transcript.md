# Test evidence: ship-brief scaffold hardening + OMP docs classification

## 1. Freshly generated ship brief carries both new captain rules
Command: `FM_HOME=<tmp-home> bin/fm-brief.sh test-ship demo-proj --mode no-mistakes`
Rules section of the generated brief (data/test-ship/brief.md):

    8. After CI is green and before reporting any PR done, check its review comments and resolve every actionable review-bot finding (including CodeRabbit and Copilot) and human review thread by fixing it or replying with a concrete reason it is not valid.
    9. Before reporting done for any PR with user-visible UI changes, use the exact upload command supplied by the project brief to upload viewport screenshots and embed them in the PR body; local paths do not count.

Full brief saved as `generated-ship-brief.md`.

## 2. Scout brief is unaffected
Command: `FM_HOME=<tmp-home> bin/fm-brief.sh test-scout demo-proj --scout`
`grep -c "After CI is green|viewport screenshots"` on the scout brief: **0 matches**.
Full brief saved as `generated-scout-brief.md`.

## 3. No Herdr lifecycle commands added
The generated ship brief still carries the "Herdr lifecycle declaration - NOT ENABLED" block; the diff adds no Herdr commands.

## 4. Scaffold tests pass (all 20, including the 2 new assertions across all three ship modes)
    $ bash tests/fm-brief.test.sh
    ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
    ... (20/20 ok)

## 5. fm-lint passes
    $ bash bin/fm-lint.sh
    fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
    exit: 0

## 6. Docs gate: fails before the classification fix, passes after
With the base-commit (d600bd6) audiences JSON:

    $ bash bin/fm-doc-audience-check.sh
    fm-doc-audience-check: unclassified: docs/omp-adapter-verification.md, docs/supervision-protocols/omp.md
    exit: 1

With this change's JSON:

    $ bash bin/fm-doc-audience-check.sh
    fm-doc-audience-check: ok surfaces=71 local_links=251
    exit: 0

Docs audience test suite (`tests/fm-documentation-audiences.test.sh`): all 4 checks ok.
