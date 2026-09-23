---
tags: [captain-queue, fm-captain-queue, backlog, parked]
date: 2026-09-23
issue: fm-card-backlog-park-desync
walked: 8e59f0e4b8ad4d1abebdce76503cdefc44a6b08f
---

# A parked backlog item parks its captain card

Spec: [`docs/specs/fm-card-backlog-park-desync.md`](../specs/fm-card-backlog-park-desync.md).

## What I walked

I walked commit `8e59f0e4` on macOS with tasks-axi 0.2.5, after rebasing onto `a1f8452a`.
Each walk built a scratch firstmate home in the session scratchpad, wrote its backlog with the real `tasks-axi`, ran the real `bin/fm-captain-queue.sh`, and read the board through the real `bin/fm-api-server.mjs` with `curl`.
Below, the card and backlog item share the id `sample-origin-decision-ship-gate`, and each GET result is shown as the ids in `items` and in `parked`.

### AC1: reconcile parks a backed card whose backlog item is parked

- `tasks-axi add sample-origin-decision-ship-gate --kind captain`, then `fm-captain-queue.sh add` for the same id, printed `added: sample-origin-decision-ship-gate`.
- `GET /captain-queue` returned `{"items":["sample-origin-decision-ship-gate"],"parked":[]}`.
- `tasks-axi hold sample-origin-decision-ship-gate --kind parked` printed `ok: hold sample-origin-decision-ship-gate -> held (parked)`.
- `fm-captain-queue.sh reconcile` printed `parked: [id=sample-origin-decision-ship-gate] backlog-parked` and exited 0.
- `GET /captain-queue` then returned `{"items":[],"parked":[{"id":"sample-origin-decision-ship-gate","parkedReason":"backlog-parked","parkedNote":"Parked because its backlog item is parked"}]}`.
- A second `reconcile` exited 0 with empty output.
- `fm-captain-queue.sh park --id` on the card now prints `parked: [id=sample-origin-decision-ship-gate] already-parked`.
- The same walk against a `git archive` copy of the pre-fix commit `4d80f458`, whose `bin/` matches the new base `a1f8452a`, reproduced the recorded bug.
  There, `reconcile` exited 0 with no output, the second GET still returned `{"items":["sample-origin-decision-ship-gate"],"parked":[]}`, and `park --id` failed with `manual park requires an unbacked or legacy card: sample-origin-decision-ship-gate`.
- Test: `test_parked_backlog_item_parks_its_card` in `tests/fm-captain-queue.test.sh` passes, and the whole file passes, 58 `ok` lines.
  Before the fix it failed with `not ok - reconcile should park only the card whose item is parked, got: ` and empty output.
  On a throwaway copy of `bin/` and `tests/`, replacing the parked branch with `elif false` turned it red with the same message.
  On another copy, replacing the `held: yes` check with `true` turned it red because reconcile also printed `parked: [id=sample-origin-decision-old-freeze] backlog-parked` for the lapsed `--until 2026-01-01` hold.
  The unmutated copy passed, which shows the copy method runs the real code.

### The paths beside it

- Arriving from a hold that is not a parked one: in a second scratch home, `sample-origin-decision-deploy-window` held with `--kind captain` stayed on the board.
  After `reconcile`, `GET /captain-queue` returned `deploy-window` in `items` and only `ship-gate` in `parked`.
- Leaving through a board answer: `POST /captain-queue/reply` with `{"id":"sample-origin-decision-ship-gate","generation":1,"answer":"Not yet"}` and the bearer token returned `{"ok":true}`.
  The next `reconcile` printed `handled: [id=sample-origin-decision-ship-gate] Not yet`.
  `GET /captain-queue` then returned `{"items":["sample-origin-decision-deploy-window"],"parked":[]}`, and the stored record read `{"state":"resolved","answer":"Not yet","parked_reason":"backlog-parked"}`.

### Checks

- `/Users/evanagee/.agents/skills/spec-lint/spec-lint docs/specs/fm-card-backlog-park-desync.md` printed `spec-lint: ok (1 acceptance criteria: AC1)`.
- `bin/fm-lint.sh bin/fm-captain-queue.sh tests/fm-captain-queue.test.sh` passed on ShellCheck 0.11.0.
- `bin/fm-doc-audience-check.sh` passed.
