---
tags: [watcher, pr-autoarm, merge-poll]
date: 2026-09-23
issue: fm-autoarm-merged-announce-loop
walked: a2b672c44d44b7c941fb421880bd174f55c805fe
---

# A merged PR's done line no longer re-arms its merge poll

Spec: [`docs/specs/fm-autoarm-merged-announce-loop.md`](../specs/fm-autoarm-merged-announce-loop.md).

## What I walked

I walked commit `a2b672c4` on macOS 27.0 with GNU bash 5.3.15.
I extracted exact `git archive` copies of the fixed commit `a2b672c4` and of its pre-fix parent `9070d912` into the session scratchpad.
Every run below used the real `bin/fm-watch.sh`, `bin/fm-pr-autoarm.sh`, and `bin/fm-pr-check.sh` from one of those copies against a fresh temporary firstmate home.
Each run started with the wake queue emptied, the way firstmate's acknowledgement leaves it.

### AC1: a recorded PR's done line arms no poll and calls no forge

- Fixture: task `t1` whose metadata records `pr=https://github.com/EvanAgee/firstmate/pull/136`, a real PR that `gh pr list --state merged` reported as `MERGED`.
  The task had no poll files, and its status file held `done: PR https://github.com/EvanAgee/firstmate/pull/136 merged`.
- `gh` on `PATH` was a wrapper that logged its arguments and then ran the real `/opt/homebrew/bin/gh`.
- The first watcher run woke on the new status line.
  Afterward `ls` showed no `t1.check.sh`, `t1.pr-poll`, or `t1.pr-poll-registration`, and the `gh` log was empty.
- Three more watcher runs followed with `FM_CHECK_INTERVAL=0`, so every slow check and the branch sweep were due each time.
  Still no poll files existed, the `gh` log stayed empty, and the queue held no merged wake.
- Test: `a merged PR's done line never re-arms its retired poll` in `tests/fm-pr-autoarm.test.sh` passes.
  Against the pre-fix code it failed with `a done line for an already-recorded PR reached the forge: pr view https://github.com/acme/widget/pull/65 --json headRefOid -q .headRefOid;`.
  On a throwaway copy with the new early return deleted, it failed with `a done line for an already-recorded PR re-armed its retired merge poll`.

### AC2: the announcement cursor passes the recorded PR's done line

- Same path 1 fixture and runs as AC1.
- After the first watcher run, `state/.pr-autoarm-status-t1.cursor` read `964682591 63`, and the status file was 63 bytes.
  The later runs left it unchanged.
- Test: `an already-recorded PR's done line advances the announcement cursor` passes.
  I ran the pre-fix code with the AC1 assertions made non-fatal on a throwaway copy, and it failed with `the announcement cursor did not pass an already-recorded PR's done line: offset=none`.
  On a copy of only this case, with the early return changed to exit 1, AC1 passed and AC2 failed with the same `offset=none` message.

### End-to-end: the spec's loop

I ran the spec's end-to-end block unchanged except for `root`, which pointed at each archive.
It runs 30 seconds of watcher cycles with a `gh` that answers `MERGED` and holds the label edit for 4 seconds.

- Pre-fix `9070d912`: `merged wakes: 3`, `gh calls: 11`, `cursor: none`.
- Fixed `a2b672c4`: `merged wakes: 0`, `gh calls: 0`, `cursor: 964612795 55`.

### The paths beside it

- Path 2: a task with no recorded PR announced `https://github.com/acme/widget/pull/88` as green, with a fake `gh` reporting it open.
  One watcher run published `t1.check.sh`, `t1.pr-poll`, and `t1.pr-poll-registration`, and recorded one `pr=` line.
  It made the `headRefOid` and label calls, and it wrote the cursor at the 61-byte end of the status file.
  An announcement for an unrecorded PR still arms as before.
- Path 3: a task with no recorded PR announced `https://github.com/acme/widget/pull/89` as merged, with a fake `gh` reporting `MERGED`.
  One signal run armed the poll, and four runs with every slow check due followed.
  The queue held exactly one `check: t1.check.sh: merged` wake, the poll files were retired, and the cursor sat at the 55-byte end.
  A first-time announcement of a merged PR still produces its one merged wake and then stops.

### Checks

- `bin/fm-test-run.sh tests/fm-pr-autoarm.test.sh` passed all 35 cases, `exit=0`.
- `bin/fm-lint.sh` exited 0 under ShellCheck 0.11.0.
- `/Users/evanagee/.agents/skills/spec-lint/spec-lint` on the spec printed `spec-lint: ok (2 acceptance criteria: AC1, AC2)`.
- `bin/fm-doc-audience-check.sh` printed `ok`.
