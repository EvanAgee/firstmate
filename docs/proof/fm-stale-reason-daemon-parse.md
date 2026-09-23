---
tags: [supervision, regression]
date: 2026-09-22
issue: fm-stale-reason-daemon-parse
walked: cefd56003b3f5f6e6d621058f9ce4f04b5a320dc
---

# Stale wake background output

## What I walked

I ran `bash -x tests/fm-daemon.test.sh test_background_output_stale_durable_wake_acknowledges` on commit `cefd5600`.
The test queued a stale record in scratch state with key `sess:fm-background-output` and a reason ending in `; background output: ... (769s old)`.
It also queued a check behind that record, then called the daemon's `handle_durable_wakes` path.
The trace showed `bin/fm-wake-drain.sh --ack-through 2 --recovery-generation ...`.
The queue was empty afterward, and the following check appeared once in the escalation buffer.

## Validation

Before the fix, the focused test failed with `not ok - background-output stale wake was not acknowledged`.
After the fix, the focused test and the full `tests/fm-daemon.test.sh` file passed.
`bin/fm-lint.sh bin/fm-supervise-daemon.sh tests/fm-daemon.test.sh` passed with ShellCheck 0.11.0.
