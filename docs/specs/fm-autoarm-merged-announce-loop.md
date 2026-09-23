---
tags: [watcher, pr-autoarm, merge-poll]
date: 2026-09-23
---

# A merged PR's done line must not re-arm its merge poll

The captain approved this fix on 2026-09-23 in the firstmate fixes batch.

## Problem Statement

On 2026-09-09 firstmate woke every few minutes for a pull request that had already merged.
The task was platform-61-invite-only-staff-pools, whose PR 65 merged while its cleanup waited on a captain decision.
Its last status line was `done: PR <url> merged`.
Each wake said the same PR had merged, and nothing the captain or firstmate did stopped them until the watcher's announcement cursor was advanced by hand.

The mechanism, reproduced on 2026-09-23 against a fixture home with the real watcher, is:

1. The watcher hands every unread status line to `bin/fm-pr-autoarm.sh announce`, and it advances that task's announcement cursor only when announce exits 0.
2. announce passes the line's PR URL to `bin/fm-pr-check.sh --only-if-unarmed`.
   The task's metadata already records that exact PR, but its merge poll files are gone, because the watcher retires a poll once it reports the merge.
   `--only-if-unarmed` treats a recorded PR with missing poll files as damage and republishes the poll.
3. The republish makes forge calls, including the `agent-pr-watched` label edit.
   On a real network these outlast the watcher's announcement budget (`FM_PR_AUTOARM_ANNOUNCE_TIMEOUT`, 3 seconds by default), so the watcher kills announce after the poll files are already published.
   announce exits non-zero, so the cursor does not move.
4. The next slow check runs the new poll, which reports `merged`, queues a check wake, and retires the poll again.
   The next cycle reads the same unread line, and the loop repeats on the check cadence.

In the fixture, with the label edit held for 4 seconds, 30 seconds of watcher cycles armed the poll 4 times, queued 4 merged wakes, and never wrote the cursor.
With a fast label edit the cursor does advance, but the same line still re-arms a poll for a merged PR once and queues one extra merged wake.

## Seams

- The watcher cycle: `bin/fm-watch.sh` run against a fixture `FM_HOME`, calling the real `bin/fm-pr-autoarm.sh` and the real `bin/fm-pr-check.sh`, with only `gh` faked on `PATH`.
  This seam exists already; `tests/fm-pr-autoarm.test.sh` drives the watcher this way for its announcement cases.
  Nothing sits above it, because firstmate learns about a merge only from the wake queue this cycle writes.

## Acceptance Criteria

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | While a task's metadata records a PR and no merge poll files exist for that task, when the watcher reads a status line that announces that same PR, the watcher shall publish no merge poll for the task and make no forge call for it. | `tests/fm-pr-autoarm.test.sh` case `merged-announcement` seeds `different-task.meta` with `pr=https://github.com/acme/widget/pull/65` and no poll files, and writes `done: PR https://github.com/acme/widget/pull/65 merged` as its status file. A fake `gh` answers `MERGED` and holds `pr edit` for 3 seconds, and `FM_PR_AUTOARM_ANNOUNCE_TIMEOUT=1`. One foreground watcher run follows; assert no `different-task.check.sh` exists and the forge log is empty. **Delete announce's early return for a task whose metadata already records a PR, and AC1 goes red because the real re-arm path calls `gh pr view --json headRefOid`, and publishes `different-task.check.sh` when it gets that far inside the 1-second budget.** | After one watcher run on the fixture home, `ls state/` shows no `different-task.check.sh`, `different-task.pr-poll`, or `different-task.pr-poll-registration`, and the `gh` call log is empty. | `tests/fm-pr-autoarm.test.sh` |
| AC2 | While a task's metadata records a PR, when the watcher reads a status line that announces that same PR, the watcher shall write the task's announcement cursor at the status file's byte size in that same run. | Same fixture and run as AC1; assert `state/.pr-autoarm-status-different-task.cursor` exists and its offset field equals `wc -c` of `different-task.status`. **Change announce's early return for a recorded PR from exit 0 to exit 1, and AC2 goes red because the cursor file is never written, while AC1 stays green.** Run this case alone for that control, because an earlier case in the file calls announce directly and aborts first. | `cat state/.pr-autoarm-status-different-task.cursor` prints `<inode> 55` for the 55-byte status file after one watcher run. | `tests/fm-pr-autoarm.test.sh` |

## End-to-end verification

Run the real watcher in repeated cycles against a fixture home, the way firstmate re-arms it after each wake, and count merged wakes.
The fixture holds a task whose metadata records a merged PR, no poll files, and a `done: PR <url> merged` status line already marked seen.
The fake `gh` answers `MERGED` and holds `pr edit` for 4 seconds, which stands in for real network latency past the 3-second announcement budget.
Each cycle clears the wake queue first, as firstmate's acknowledgement does, and runs with `FM_CHECK_INTERVAL=0`, so every run reaches the slow checks.

```sh
root=$(git rev-parse --show-toplevel)  # run from inside a firstmate checkout
d=$(mktemp -d); mkdir -p "$d/home/state" "$d/wt" "$d/bin"
git -C "$d/wt" init -q && git -C "$d/wt" commit -q --allow-empty -m i
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$LOG"' \
  'case "$*" in *"--json state"*) echo MERGED ;; *headRefOid*) echo 0123456789abcdef0123456789abcdef01234567 ;; *"pr edit"*) sleep 4 ;; esac' \
  > "$d/bin/gh"; chmod +x "$d/bin/gh"; : > "$d/gh.log"
printf '%s\n' "worktree=$d/wt" kind=ship mode=no-mistakes 'pr=https://github.com/acme/widget/pull/65' > "$d/home/state/t1.meta"
chmod 600 "$d/home/state/t1.meta"
printf '%s\n' 'done: PR https://github.com/acme/widget/pull/65 merged' > "$d/home/state/t1.status"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_signal_sig "$2" > "$(fm_wake_signal_seen_path "$3" "$2")"' _ "$root" "$d/home/state/t1.status" "$d/home/state"
end=$((SECONDS + 30))
while [ "$SECONDS" -lt "$end" ]; do
  rm -rf "$d/home/state/.watch.lock" "$d/home/state/.watcher-down"
  cat "$d/home/state/.wake-queue" >> "$d/queue.all" 2>/dev/null; : > "$d/home/state/.wake-queue"
  LOG="$d/gh.log" FM_HOME="$d/home" FM_STATE_OVERRIDE="$d/home/state" FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    FM_GH_HEALTH_PROBE_CMD=true FM_SIGNAL_GRACE=0 FM_POLL=0.1 PATH="$d/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    perl -e 'alarm shift; exec @ARGV' 4 "$root/bin/fm-watch.sh" >/dev/null 2>&1
done
cat "$d/home/state/.wake-queue" >> "$d/queue.all" 2>/dev/null
echo "merged wakes: $(grep -c 't1.check.sh: merged' "$d/queue.all")"
echo "gh calls: $(wc -l < "$d/gh.log" | tr -d ' ')"
echo "cursor: $(cat "$d/home/state/.pr-autoarm-status-t1.cursor" 2>/dev/null || echo none)"
```

Expected after the fix: `merged wakes: 0`, `gh calls: 0`, and `cursor: <inode> 55`.
Failure looks like the pre-fix result: several merged wakes, several `gh` calls, and `cursor: none`.

## Non-goals

- The watcher's announcement cursor logic stays as it is.
  It already advances on exit 0 and retries on a non-zero exit, and announce now exits 0 for a recorded PR.
- `bin/fm-pr-check.sh --only-if-unarmed` keeps its same-PR repair for direct callers and for a publication interrupted before the metadata commit; only announce stops reaching it for a task that already records a PR.
- The announcement budget and the label edit's latency stay as they are; a first arm that outlasts the budget after it records the PR is retried once, and the retry now ends at the recorded PR.
- The branch sweep already skips a task that records a PR, so it needs no change.
- Task metadata gains no merged field.
  A recorded PR is enough to stop the re-arm, and the watcher's own poll already reports the merge.

## Open questions

None.
