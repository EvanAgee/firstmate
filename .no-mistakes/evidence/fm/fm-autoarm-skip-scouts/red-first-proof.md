# Red-first proof for tests/fm-pr-autoarm.test.sh

The new tests were run against the PRE-FIX script (base 87890f7) with the new
test file. To see every failure instead of stopping at the first one, `fail()`
was made non-fatal in a throwaway scratch copy of the repo. That is why a group's
`pass` line still prints right after its `not ok` line; only the `not ok` lines
matter.

Every `not ok` falls inside a group added or changed by this commit:

    not ok - a scout sweep reached the forge
    not ok - a scout sweep armed a PR
    not ok - a detached worktree should be silent: pr-autoarm: task=different-task has no resolvable branch
    not ok - a branch without an upstream should be silent: pr-autoarm: task=different-task branch actual-feature has no upstream
    not ok - a branch without an upstream did not reach the forge
    not ok - one open PR for a branch without an upstream should arm silently: pr-autoarm: task=different-task branch actual-feature has no upstream
    not ok - a branch without an upstream did not arm its exact open PR
    not ok - two open PRs for a branch without an upstream did not wake: pr-autoarm: task=different-task branch actual-feature has no upstream
    not ok - fail forge result for a branch without an upstream should be silent: pr-autoarm: task=different-task branch actual-feature has no upstream
    not ok - malformed forge result for a branch without an upstream should be silent: pr-autoarm: task=different-task branch actual-feature has no upstream
    not ok - a missing origin for a branch without an upstream should be silent: pr-autoarm: task=different-task branch actual-feature has no upstream

Pre-existing groups all stayed green against the old script, so the new tests
target only the new behavior and no old behavior regressed.

# Green after the fix

Unmodified suite via the project runner, on the target commit:

    $ bin/fm-test-run.sh tests/fm-pr-autoarm.test.sh
    FM_TEST_BEGIN 2026-09-09T17:36:23Z tests/fm-pr-autoarm.test.sh family=pr-forge expected_gate_skip=none
    ... 30 ok lines, including:
    ok - scout metadata is excluded from the branch sweep
    ok - a detached worktree waits for the next scan
    ok - zero open PRs for a branch without an upstream is a silent no-op
    ok - a branch without an upstream arms one exact open PR
    ok - multiple open PRs for a branch without an upstream still wake
    ok - forge failures stay silent for branches without upstreams
    ok - a branch without an upstream or origin stays silent
    ok - secondmate metadata is excluded from the branch sweep
    ok - secondmate announcements cannot attach a child PR to the parent
    ok - scout announcements keep existing handling
    FM_TEST_END 2026-09-09T17:39:35Z tests/fm-pr-autoarm.test.sh exit=0 duration_ms=192077
    FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=192568
