---
tags: [decision-hold, github-labels, captain-decisions]
date: 2026-09-23
issue: fm-decision-answer-closes-loop
walked: fca6bc4a0052867e900f5c6efd7f53445aa74e84
---

# Answering a decision closes the loop on its issue

Spec: [`docs/specs/fm-decision-answer-closes-loop.md`](../specs/fm-decision-answer-closes-loop.md).

## What I walked

I walked commit `fca6bc4a` on macOS with `gh` 2.92.0 and `tasks-axi` 0.2.5.
I ran the real `bin/fm-decision-hold.sh` against a throwaway firstmate home in the session scratchpad, with its own real `tasks-axi` backlog.
Every GitHub read went to the live `SuperDuperIT/aos` repository through the real `gh`.
A `gh` shim first on `PATH` passed every read through and recorded each `issue edit` instead of sending it, because the live aos issues are the captain's work, not scratch.
So the label edits below are the exact commands the script issued, and none of them reached GitHub.
`gh issue edit --help` on this machine lists both `--add-label` and `--remove-label`.
Below, `<walk>` stands for the scratch home.

### AC1: a new record stores its issue link, and a malformed link is refused

- `hold walk-3642 keep-deferred ... --issue SuperDuperIT/aos#3642` printed `walk-3642-decision-keep-deferred` and exited 0.
- `tasks-axi show` read `body: "Origin: walk-3642\nDecision key: keep-deferred\nState: awaiting captain decision.\nIssue: SuperDuperIT/aos#3642"`.
- `--issue 'SuperDuperIT/aos#3642 x'` printed `fm-decision-hold: --issue must be an owner/repo#N reference: SuperDuperIT/aos#3642 x`, exited 1, and left no `walk-3642-decision-bad-link` record.
- Test: `test_issue_link_is_recorded_and_validated` passes.
  It failed on the base commit because `hold` rejected `--issue` as a usage error.
  It failed again on a throwaway copy with the `Issue:` line removed from the new body, with "the new decision record did not store its issue link".

### AC2: answering the last waiting record moves the issue from needs-decision to agent-ready

- The live issue `SuperDuperIT/aos#3642` carried `needs-decision` at walk time.
- `answer walk-3642 keep-deferred --decision-file <walk>/answer.txt --ready` printed `answered: walk-3642-decision-keep-deferred` then `issue-synced: SuperDuperIT/aos#3642`, and exited 0.
- The shim log held exactly two calls: `gh issue view 3642 -R SuperDuperIT/aos --json labels --jq .labels[].name`, then `gh issue edit 3642 -R SuperDuperIT/aos --remove-label needs-decision --add-label agent-ready`.
- Test: `test_answer_syncs_the_linked_issue_labels` passes, and its unlinked origin made no `gh` call at all.
  It failed on the base commit because `hold` rejected `--issue`.
  It failed again on a throwaway copy with the sync call removed after the close, with "answer did not report the synced issue".

### AC3: the labels wait until every sibling record is answered

- Two records on origin `walk-3311` both linked to the live `SuperDuperIT/aos#3311`.
- Answering the first printed `answered: walk-3311-decision-lone` and `issue-kept: SuperDuperIT/aos#3311 (still waiting on walk-3311-decision-second)`.
  The shim log stayed empty, so the script made no GitHub call at all.
- Answering the second printed `issue-synced: SuperDuperIT/aos#3311` on its successful run (see AC5).
- Test: `test_issue_labels_wait_for_every_sibling_answer` passes.
  It failed on the base commit because `hold` rejected `--issue`.
  It failed again on a throwaway copy whose sibling check always reported none, with "the first answer did not keep the issue label".

### AC4: an answer closes a record deferred to a date

- `park walk-3642 keep-deferred --until 2099-12-31` printed `parked: walk-3642-decision-keep-deferred until 2099-12-31`.
- The AC2 answer then closed that deferred record.
  `tasks-axi show` read `state: done`, and the body opened `Resolution recorded by fm-decision-hold.` with `Resolution mode: answered` and `Issue: SuperDuperIT/aos#3642`.
- Test: `test_answer_closes_a_deferred_decision` passes for a parked record and for one deferred until 2099-12-31, and `verify` passes after both.
  It failed on the base commit with `fm-decision-hold: backlog item sample-deferred-review-decision-revisit-later is not held for the captain`.
  It failed again on a throwaway copy with the captain-only check restored on the close path, with the same refusal.
- `test_concurrent_park_and_answer_keep_one_decision` changed with this contract.
  It still proves the answer waits behind a paused park, and it now proves the waiting answer then closes the parked record with one resolution and no stale deferral.

### AC5: a failed label edit is loud, and the exact re-run retries it

- With the shim set to fail the next edit, answering `walk-3311 second` printed `answered: walk-3311-decision-second`, then `fm-decision-hold: captain hold walk-3311-decision-second is closed, but the labels on SuperDuperIT/aos#3311 were not changed (simulated: HTTP 502 Bad Gateway); re-run the same command to retry them`, and exited 1.
- `tasks-axi show` read `state: done`.
- The same command again printed `answered: walk-3311-decision-second` and `issue-synced: SuperDuperIT/aos#3311`, and exited 0.
- The shim log showed the label read and the edit twice, once failed and once recorded.
- Test: `test_failed_issue_sync_is_loud_and_retryable` passes.
  It failed on the base commit because `hold` rejected `--issue`.
  It failed again on a throwaway copy that ignored the edit's exit status, with "answer reported success although the issue labels were not changed".

### AC6: a close path syncs an issue named at close time

- `hold walk-legacy old` made a record with no link, as every record made before this change has.
- `answer walk-legacy old --decision-file <walk>/answer.txt --issue SuperDuperIT/aos#3642` printed `answered: walk-legacy-decision-old` and `issue-synced: SuperDuperIT/aos#3642`.
- The shim recorded `gh issue edit 3642 -R SuperDuperIT/aos --remove-label needs-decision`, with no `agent-ready` because the run had no `--ready`.
- Test: `test_every_close_path_syncs_a_named_issue` passes for `answer`, `decline` and `resolve`.
  It failed on the base commit because all three rejected `--issue`.
  It failed again on a throwaway copy with `--issue` dropped from `resolve`, with "resolve refused a named issue".

### AC7: stale names a needs-decision issue whose latest comment is the captain's answer

- `stale SuperDuperIT/aos` against the live repository printed `answered-on-issue: SuperDuperIT/aos#3642`.
- That matches the live state: #3642 carries `needs-decision`, and its latest comment opens `Captain decision, 2026-09-18: **keep deferred**.`
- It did not name #3311, the only other open `needs-decision` issue, whose latest comment is a firstmate progress note.
- Test: `test_stale_reports_an_answer_left_on_the_issue` passes.
  It failed on the base commit because `stale` did not exist.
  It failed again on a throwaway copy that read the first comment instead of the latest, with "stale missed an answer left on the issue".

### AC8: stale names a deferred record the captain spoke after

- I dated `walk-3642-decision-keep-deferred`'s deferral record `Deferred on: 2026-09-12` and left a control record, `walk-3642-decision-control`, deferred on 2026-09-23.
  Both link #3642, whose latest captain answer is dated 2026-09-18.
- The same `stale` run printed `held-after-captain-spoke: walk-3642-decision-keep-deferred SuperDuperIT/aos#3642` and did not name the control.
- It ended with `stale: answered-on-issue=1 held-after-captain-spoke=1 repo=SuperDuperIT/aos`.
- Test: `test_stale_reports_a_deferral_the_captain_overtook` passes.
  It failed on the base commit because `stale` did not exist.
  It failed again on a throwaway copy that compared against the record's creation date instead of its deferral date, with "stale missed a deferred record the captain spoke after".

### Checks run

- `bash tests/fm-decision-hold-lifecycle.test.sh`: all 40 cases pass, the 32 earlier ones included.
- `bin/fm-lint.sh`: ShellCheck 0.11.0, no findings.
- `bash tests/fm-agents-coverage.test.sh` and `bash tests/fm-documentation-audiences.test.sh` pass, and `bin/fm-doc-audience-check.sh` reports ok.
- `/Users/evanagee/.agents/skills/spec-lint/spec-lint` on the spec: `ok (8 acceptance criteria: AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8)`.
