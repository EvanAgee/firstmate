---
tags: [decision-hold, github-labels, captain-decisions]
date: 2026-09-23
---

# Answering a decision closes the loop on its issue

The captain approved dispatching this on 2026-09-23 in the firstmate fixes batch.

## Problem Statement

Firstmate asks the captain a decision in two places at once.
The GitHub issue gets a `needs-decision` label, and the backlog gets a captain decision record written by `bin/fm-decision-hold.sh hold`.
When the captain answers on the issue, neither surface changes.
The label stays, the backlog record stays open, and a record deferred with `park --until` keeps its old revisit date.
Every sweep that reads labels or records then reports the captain as blocking work he already unblocked.

Measured on 2026-09-20.
The captain answered all four #3329 supervised-drive keys on 2026-09-18, each comment ending "Unblocked for implementation."
Firstmate reported them as waiting on him twice over the next two days, until he said "I have already answered this multiple times".
The same sweep found nine more records under #194, #402 and #574, all taken out of deferral on 2026-09-18, still deferred until 2026-10-01.
Three tickets were buildable the whole time.
The aos factory poll picked all three up within a minute of the label coming off, so the label alone was the block.

Three gaps in `bin/fm-decision-hold.sh` cause this:

- No close path touches the issue, and a hold does not record which issue it was asked on.
- `answer`, `decline` and `resolve` refuse a record the captain earlier parked or deferred (`backlog item ... is not held for the captain`), so his later answer cannot close it.
- Nothing notices when the issue and the backlog disagree.

## Solution

A decision record can carry the issue it was asked on, and every close path uses that link.

- `hold ... --issue <owner/repo#N>` records the issue in the new record.
- `answer`, `decline` and `resolve` accept `--issue <owner/repo#N>` for a record created without one, and `--ready` when the answered work is buildable.
- After a close path closes a record that links an issue, it checks the origin's other decision records.
  If none of them still waits on the captain, it removes `needs-decision` from the issue, and with `--ready` it also adds `agent-ready`.
  If a sibling still waits, it leaves the labels alone and names that sibling.
- The three close paths also close a parked or future-deferred record, because the captain's answer replaces his earlier deferral.
- A new read-only `stale <owner/repo>` command reports both inconsistent states the brief names.
  It changes nothing.

## Seams

- `bin/fm-decision-hold.sh` command line, existing.
  Arguments, a real `tasks-axi` backlog in a throwaway firstmate home, and `gh` on `PATH` go in.
  Stdout lines, stderr, the exit code, backlog records, and the `gh` calls made come out.
  This is the existing seam of `tests/fm-decision-hold-lifecycle.test.sh`, which already runs the real script against a real `tasks-axi` backlog in a temp home.
  The new cases put a recording fake `gh` first on `PATH` that answers label and comment reads from fixture files.
  No higher seam exists, because this script is the single owner of the decision-record lifecycle and every answer channel reaches it.

## Acceptance Criteria

A "captain answer marker" is a comment whose first non-blank line, after any leading `#`, `>`, `*`, `_` and spaces, begins with `Captain decision`, `Captain direction` or `Decision recorded (captain`, ignoring case.
Those are the openings the captain's real answers used on #3329, #194, #402 and #574.

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | When `hold` creates a decision record with `--issue owner/repo#N`, fm-decision-hold.sh shall store the line `Issue: owner/repo#N` in the record body, and if the value is not an `owner/repo#N` reference it shall refuse and create no record. | `test_issue_link_is_recorded_and_validated`; fixture: origin `sample-link-review`, key `link-choice`, `--issue acme/widgets#7`, then `--issue 'acme/widgets#7 x'`. Assert the body line and that the bad value leaves no record. The base script refuses `--issue` as a usage error with exit 2. **Remove the `Issue:` line from the new body and prove AC1 goes red.** | In a throwaway home, `tasks-axi show <hold> --full` shows `Issue: acme/widgets#7` in the body. | tests/fm-decision-hold-lifecycle.test.sh |
| AC2 | When `answer --ready` closes the last decision record of an origin still waiting on the captain, and that record links an issue carrying `needs-decision`, fm-decision-hold.sh shall remove `needs-decision` and add `agent-ready` on that issue in the same run and print `issue-synced: owner/repo#N`. | `test_answer_syncs_the_linked_issue_labels`; fixture: one record linked to `acme/widgets#7`, whose fake labels are `needs-decision,type:feature`. Assert the fake `gh` log holds `issue edit 7 -R acme/widgets --remove-label needs-decision --add-label agent-ready`. A second origin with no link must make no `gh` call. **Skip the issue sync after the close and prove AC2 goes red.** | The throwaway-home walk against a live aos issue that carries `needs-decision` prints `answered: <hold>` then `issue-synced: SuperDuperIT/aos#<n>`, and the `gh` shim log shows the one edit. | tests/fm-decision-hold-lifecycle.test.sh |
| AC3 | While another decision record of the same origin still waits on the captain, when `answer` closes one linked record, fm-decision-hold.sh shall leave the issue's labels unchanged and print `issue-kept: owner/repo#N` naming the record still waiting. | `test_issue_labels_wait_for_every_sibling_answer`; fixture: two records `first-choice` and `second-choice` on origin `sample-sibling-review`, both linked to `acme/widgets#9`. Answer the first and assert no `issue edit` call and an `issue-kept:` line naming `sample-sibling-review-decision-second-choice`; answer the second and assert the edit. **Make the sibling check always report none and prove AC3 goes red.** | In the walk, the first of two sibling answers prints `issue-kept: SuperDuperIT/aos#<n>` naming the second record, and only the second prints `issue-synced:`. | tests/fm-decision-hold-lifecycle.test.sh |
| AC4 | When `answer` is run on a decision record that `park` deferred, with or without `--until`, fm-decision-hold.sh shall close it with the same resolution record an active record gets, and `verify` shall pass for its origin. | `test_answer_closes_a_deferred_decision`; fixture: record `revisit-later` parked, record `revisit-on-date` parked `--until 2099-12-31`. Assert both close as `Resolution mode: answered`. The base script refuses with `backlog item ... is not held for the captain`. **Restore the captain-only hold-kind check on the close path and prove AC4 goes red.** | In the walk, `answer` on a record parked until 2099-12-31 prints `answered: <hold>`, and `tasks-axi show` reads `state: done`. | tests/fm-decision-hold-lifecycle.test.sh |
| AC5 | If the label edit fails after a close path closed its record, then fm-decision-hold.sh shall exit nonzero with a message naming the issue and saying the record is closed, and an exact re-run shall retry only the label edit. | `test_failed_issue_sync_is_loud_and_retryable`; fixture: a fake `gh` whose `issue edit` exits 1 once. Assert exit nonzero, stderr names `acme/widgets#11`, the record is `state: done`, and a re-run with the same decision file exits 0 and logs a second edit. **Ignore the edit's exit status and prove AC5 goes red.** | In the walk, the failing shim run prints the refusal naming the issue, and the re-run prints `issue-synced:`. | tests/fm-decision-hold-lifecycle.test.sh |
| AC6 | When `answer`, `decline` or `resolve` is given `--issue owner/repo#N` for a record created without a link, fm-decision-hold.sh shall sync that issue as if the record had carried the link. | `test_every_close_path_syncs_a_named_issue`; fixture: three origins with one unlinked record each, closed by `answer --issue acme/widgets#21`, `decline --issue acme/widgets#22`, and `resolve --routed-to <task> --issue acme/widgets#23`. Assert one `--remove-label needs-decision` edit per issue. The base script refuses `--issue` on all three with exit 2. **Drop the `--issue` flag from the resolve path and prove AC6 goes red.** | In the walk, `answer --issue` on an unlinked record prints `issue-synced:` for the named issue. | tests/fm-decision-hold-lifecycle.test.sh |
| AC7 | When `stale owner/repo` runs, fm-decision-hold.sh shall print `answered-on-issue: owner/repo#N` for each open issue labeled `needs-decision` whose latest comment opens with a captain answer marker, and for no other issue. | `test_stale_reports_an_answer_left_on_the_issue`; fixture: fake open `needs-decision` issues 31, whose last comment opens `Captain decision, 2026-09-18:`, 32, whose last comment is a firstmate note, and 33, whose captain answer is followed by a later note. Assert only `answered-on-issue: acme/widgets#31`. The base script rejects `stale` with exit 2. **Read the first comment instead of the latest and prove AC7 goes red.** | `bin/fm-decision-hold.sh stale SuperDuperIT/aos` against the live repo prints one line for each open `needs-decision` issue whose latest comment is a captain answer. | tests/fm-decision-hold-lifecycle.test.sh |
| AC8 | When `stale owner/repo` runs, fm-decision-hold.sh shall print `held-after-captain-spoke: <hold-id> owner/repo#N` for each deferred decision record in the active home linked to an issue in that repository that carries a captain answer marker comment dated after the record's latest deferral date, and for no other record. | `test_stale_reports_a_deferral_the_captain_overtook`; fixture: two records created today, each deferred `--until 2099-12-31` by a deferral record that reads `Deferred on: 2026-09-12`, linked to `acme/widgets#41` and `acme/widgets#42`. Issue 41 has a `Captain direction` comment dated 2026-09-18, and issue 42 has one dated 2026-09-10. Assert only the #41 record is reported. **Compare against the record's creation date instead of the deferral date and prove AC8 goes red.** | In the walk, a record deferred on 2026-09-12 and linked to live aos issue #3642, whose latest comment is the captain's 2026-09-18 answer, is reported. | tests/fm-decision-hold-lifecycle.test.sh |

## End-to-end verification

Run the real script against a throwaway firstmate home in the session scratchpad, with the real `tasks-axi` backlog, and with the real `gh` for every read.

```
FM_HOME=<scratch home> bin/fm-decision-hold.sh hold <origin> <key> --title ... --reason ... --repo aos --issue SuperDuperIT/aos#<n>
FM_HOME=<scratch home> bin/fm-decision-hold.sh park <origin> <key> --decision-file <deferral> --until 2099-12-31
FM_HOME=<scratch home> bin/fm-decision-hold.sh stale SuperDuperIT/aos
FM_HOME=<scratch home> bin/fm-decision-hold.sh answer <origin> <key> --decision-file <answer> --ready
```

The run uses a `gh` shim that passes every read to the real `gh` and records `issue edit` instead of sending it, because the live repositories are the captain's work and are not scratch.
Expected: `stale` reports the live aos issues whose latest comment is a captain answer, and the scratch record linked to one of them.
`answer` prints `answered:` and then `issue-synced:`, the shim records exactly one `issue edit` with `--remove-label needs-decision` when the live issue carries that label, and the backlog shows the record Done.
A failure looks like `stale` printing nothing for an issue the captain answered, `answer` refusing a deferred record, or a missing `issue edit`.
The proof at `docs/proof/fm-decision-answer-closes-loop.md` records what this walk showed.

## Non-goals

- Reading the captain's prose to decide what he answered, or closing a record from `stale`'s findings.
  `stale` only reports, and a person or agent still records the answer through a close path.
- Watching GitHub for new comments.
  `stale` runs when firstmate is about to tell the captain a decision still waits on him.
- Changing labels from `park`.
  A deferral changes what the backlog asks, not whether the issue is buildable.
- Reactivating a deferred record without an answer.
  `tasks-axi hold <id> --kind captain` already does that by hand, and `stale` points at the record that needs it.
- Linking existing records to their issues in bulk.
  A close path's `--issue` covers every record created before this change.
- Removing or adding any label other than `needs-decision` and `agent-ready`.
- Teaching `bin/fm-send.sh --resolve-key` to reach a deferred record.
  Chat answers still reach only active records.

## Open questions

None.
