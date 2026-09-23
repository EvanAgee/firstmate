---
tags: [captain-queue, fm-captain-queue, backlog, parked]
date: 2026-09-23
---

# A parked backlog item parks its captain card

The captain approved this fix on 2026-09-23 in the firstmate fixes batch.

## Problem Statement

The fleet board is the captain's only view of open decisions, and `GET /captain-queue` serves it from `data/captain-queue.json`.
When firstmate parks the backlog item behind a card, with `tasks-axi hold <id> --kind parked` or `bin/fm-decision-hold.sh park`, the backlog treats the question as settled.
The card does not follow.
It stays at `state: open`, and `GET /captain-queue` keeps serving it in `items`, so the board asks a question the backlog has already shelved.
Measured on 2026-09-19 with `aos-3956-nightly-qb-alert`: `bin/fm-captain-queue.sh reconcile` exited 0 and changed nothing.
`bin/fm-captain-queue.sh park --id` refused the card with "manual park requires an unbacked or legacy card", so no supported path retires a backed card when its backlog item is parked.

## Solution

`reconcile` already retires each open backed card whose backlog item is done.
It will now also move each open backed card whose backlog item is under an active parked hold to the card's `parked` state.
The heartbeat sweep and the captain-reply wake both run `reconcile`, so the board converges without a manual step.
`park --id` keeps refusing backed cards.

## Seams

- `bin/fm-captain-queue.sh reconcile` - existing - the command the heartbeat and the captain-reply wake already run, and the one that already follows the backlog item to done.
  Tested through `tests/fm-captain-queue.test.sh`, which builds a scratch home, writes a real backlog with `tasks-axi`, and runs the real script.
  Nothing higher owns the card state: `GET /captain-queue` only reads what this script wrote.

## Further Notes

The recorded problem allowed either `reconcile` or `park` to carry the fix; these are the implementation choices made within it.

- The fix lives in `reconcile`, not in `park`: the backlog item is the source of truth, and the board should follow it without anyone remembering a second command.
- An active parked hold means `tasks-axi show <id>` reports both `held: yes` and `hold_kind: parked`.
  A parked hold whose `--until` date has passed reports `held: no` and does not count.
  A `captain`, `external`, `load`, or `future` hold does not count.
- Only cards recorded as backed at add time follow the hold, the same guard the done-item sweep uses, so a same-id item filed later cannot move an unbacked card.
- A done item still resolves its card with `backlog-done`; the parked check runs only for an item that is not done.
- The parked card keeps its full content and gets `parked_reason: backlog-parked` and a fixed note, the same shape the seven-day expiry writes.
- The parked check asks `tasks-axi`; if `tasks-axi` is missing or fails, the card stays open, which is the behavior before this change.
- Prior art for the test: `test_done_backlog_item_clears_card_without_a_reply` in `tests/fm-captain-queue.test.sh`.

## Acceptance Criteria

| AC | Requirement (EARS) | Red test, fixture, and the mutation that proves it red | Observable on the real surface | Judge |
|---|---|---|---|---|
| AC1 | When `fm-captain-queue.sh reconcile` runs, the script shall move each open backed card whose backlog item shows `held: yes` and `hold_kind: parked` to `state: parked` with `parked_reason: backlog-parked`, print one `parked: [id=<id>] backlog-parked` line for it, leave every other open card open, and print nothing on the next reconcile. | `test_parked_backlog_item_parks_its_card` in `tests/fm-captain-queue.test.sh`; fixture: a backlog with three captain items and a backed card for each: `sample-origin-decision-ship-gate` held with `--kind parked`, `sample-origin-decision-deploy-window` held with `--kind captain`, and `sample-origin-decision-old-freeze` held with `--kind parked --until 2026-01-01`, a lapsed gate. The base commit fails it: reconcile prints nothing and `ship-gate` stays open. **Delete the parked branch from the reconcile sweep and prove AC1 goes red; drop the `held: yes` check and prove AC1 goes red because `old-freeze` parks.** | In a scratch home served by `bin/fm-api-server.mjs`, `curl http://127.0.0.1:<port>/captain-queue` lists the card in `items` before the hold; after `tasks-axi hold --kind parked` and `bin/fm-captain-queue.sh reconcile`, which prints `parked: [id=<id>] backlog-parked`, the same GET lists it in `parked` with `parkedReason` `backlog-parked` and not in `items`. | `tests/fm-captain-queue.test.sh` |

## End-to-end verification

```
H=$(mktemp -d); mkdir -p "$H/data" "$H/state"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
tasks-axi add sample-origin-decision-ship-gate "Ship on merge?" --kind captain --repo sample --file "$H/data/backlog.md"
FM_HOME="$H" bin/fm-captain-queue.sh add --id sample-origin-decision-ship-gate --question "Ship on merge?" --option "Go ahead (recommended)" --option "Not yet"
node bin/fm-api-server.mjs --home "$H" --port 47931 &
curl -s http://127.0.0.1:47931/captain-queue
tasks-axi hold sample-origin-decision-ship-gate --reason "captain parked it" --kind parked --file "$H/data/backlog.md"
FM_HOME="$H" bin/fm-captain-queue.sh reconcile
curl -s http://127.0.0.1:47931/captain-queue
FM_HOME="$H" bin/fm-captain-queue.sh reconcile
kill %1
```

Expected: the first GET lists the card in `items`.
The first reconcile prints `parked: [id=sample-origin-decision-ship-gate] backlog-parked`.
The second GET lists the card in `parked` with `parkedReason` `backlog-parked`, and `items` is empty.
The second reconcile prints nothing.
Failure looks like the second GET still listing the card in `items`, which is the bug as recorded.
The proof at `docs/proof/fm-card-backlog-park-desync.md` records what this walk showed.

## Non-goals

- Reopening a card when its backlog item is unheld: `add` refuses a parked card today, and bringing a shelved question back is a separate decision about the board.
- Following `future` holds: a dated deferral comes back on its own, and parking its card would strand it for the same reason.
- Letting `park --id` accept backed cards: one path is enough, and the automatic one needs no one to remember it.
- Reading the parked hold from `data/backlog.md` directly when `tasks-axi` fails: the card then stays open, as it does today.
- Updating the board the moment a hold lands: the next heartbeat or captain-reply reconcile is soon enough.

## Open questions

None.
