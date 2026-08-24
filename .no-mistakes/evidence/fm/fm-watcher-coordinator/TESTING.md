# Claude watcher coordinator — local test evidence

## What was exercised

Real `bin/fm-claude-watch-coordinator.sh` driving real `bin/fm-watch-arm.sh` /
`bin/fm-watch.sh` against a temp primary home, plus the parked notifier, the
turn-end guard, and Cursor host stand-down.

## Core fix (operator-visible)

A handling turn of **10s** with **`FM_GUARD_GRACE=6`** kept one live watcher
(`pid 5023`) owning `state/.watch.lock`. Beacon age stayed **0–2s** (always
under grace). `bin/fm-guard.sh` under Claude/autoarm printed **no**
`WATCHER DOWN` banner at t=0s or t=10s.

The ready-to-notify record named that same successor pid **before** the long
turn was sampled:

```
ready_seq=0
successor_watch_pid=5023
coordinator_generation=coord-3443-4167
session_owner=3443
```

See `long-turn-beacon-timeline.log`.

## Automated suites

- `tests/fm-claude-watch-coordinator.test.sh` — all 9 cases, including
  successor-before-ready, long-turn beacon, re-arm + higher high-water mark,
  notifier exit-2 once, duplicate-row one wake, single coordinator owner,
  coordinator lock does not satisfy the guard, handover stand-down,
  successor-timeout stand-down.
- `tests/fm-claude-watch-notifier.test.sh` — retained gates, park-and-notify,
  foreign-host stand-down, coordinator-absent typed failure, notify-once,
  positive recovery, parent-TERM interrupted epoch.
- `tests/fm-cursor-primary.test.sh` — both Claude Stop hooks stay inert on a
  Cursor payload.
- `tests/fm-session-lock-ancestry.test.sh`, `tests/fm-turnend-guard.test.sh`,
  `tests/fm-supervision-instructions.test.sh`.
- `tests/fm-claude-watch-coordinator-live-e2e.test.sh` — skip without
  `FM_CLAUDE_LIVE_E2E=1`. Enabling it failed: installed `claude` is at the
  Fable 5 usage limit (`You've reached your Fable 5 limit`).

Default `FM_GUARD_GRACE` remains 300. This change does not raise it.
