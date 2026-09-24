---
tags: [spec-lock, brief, proof]
date: 2026-09-24
issue: spec-lock-t1-brief-field
walked: 3b5dd51d1abeb435e14d39358ad57a1f62b909a0
spec: /Users/evanagee/Sites/firstmate/data/spec-lock-machine-wide/tickets/spec-lock-t1-brief-field.md
---

# Every ship brief requires the proof's spec field

Spec: `/Users/evanagee/Sites/firstmate/data/spec-lock-machine-wide/tickets/spec-lock-t1-brief-field.md`, the machine-wide spec lock cut to AC18.
That spec lives in the captain's private firstmate home, not in this repository, so the `spec:` field above names it as the brief wrote it.

## AC18

AC18: when a new worker brief is produced, it shall require the proof spec field before machine-wide activation.

Every ship brief from `bin/fm-brief.sh` now ends its Spec section with one line:

```
In the front matter of `docs/proof/<task-id>.md`, beside `tags`, `date`, `issue` and `walked`, add `spec: <value>`, because the landing check follows that field to the spec.
```

The value is the `--spec` argument as written, or `docs/specs/<task-id>.md` when the brief starts in the to-spec phase.
The line never starts with `Spec:`, so the spec gate and `bin/fm-spec-point.sh`, which both read the first line starting `Spec:`, see the same line as before.

### Where the test lives

The spec names `/Users/evanagee/Sites/spec-lock/test/spec-lock.test.mjs` as the AC18 test file.
For this ticket the test sits beside the code it tests, in this repository's colocated suites, because the brief scaffold is firstmate code and the spec-lock checkout does not own it:

- `tests/fm-brief.test.sh`, `test_ship_brief_requires_the_proof_spec_field`: generates a brief through the real `bin/fm-brief.sh` in an isolated home for each of `no-mistakes`, `direct-PR` and `local-only`, with `--spec docs/specs/lock.md` and without `--spec`, and asserts the exact field line with the right value.
  It also asserts the to-spec brief's first `Spec:` line is still `Spec: to-spec phase`.
- `tests/fm-control-relaunch.test.sh`, `test_relaunch_keeps_the_proof_spec_field_rule`: scaffolds a real ship brief, relaunches the task through `bin/fm-control.sh relaunch --note-file`, and asserts the replacement's brief still carries the field line beside the note.

A relaunch has no brief of its own.
`bin/fm-control.sh` reuses `data/<task-id>/brief.md` and appends the progress note to it, so the relaunch case pins that the rule survives that append.

### Red before the change

Both new tests ran against the unchanged scaffold first and failed on the missing line:

```
not ok - no-mistakes: a brief with --spec did not require the proof's spec field naming that spec
not ok - the relaunched brief lost the proof's spec field rule
```

### Green at the walked commit

At `3b5dd51d`, `bash tests/fm-brief.test.sh` printed 44 `ok` lines and no `not ok`, including:

```
ok - fm-brief.sh: every ship brief requires the proof's spec: front matter field
```

`bash tests/fm-spec-point.test.sh` printed 10 `ok` lines and no `not ok`.

`FM_ROUTE_HOME_OVERRIDE=<empty scratch dir> bash tests/fm-control-relaunch.test.sh` printed 52 `ok` lines and no `not ok` on the tree committed as `a263ecf1`, whose `bin/` and `tests/` match `3b5dd51d` byte for byte.
At `3b5dd51d` the same file stopped on an older case, `relaunch did not reach trace delivery`, which waits two seconds for a fake trace hook while this machine's load average sat near 50.
The new relaunch case run alone from a `git archive` copy of `3b5dd51d` printed:

```
ok - fm-control relaunch: the replacement reads the proof's spec field rule
```

### Controls

Each control ran on a `git archive` copy of HEAD, never in the worktree.

| Mutation in the copy's `bin/fm-brief.sh` | Result |
|---|---|
| Delete the field line (always-allow) | `not ok - no-mistakes: a brief with --spec did not require the proof's spec field naming that spec` |
| Name the `--spec` value in the to-spec phase too | `not ok - no-mistakes: a to-spec brief did not require the proof's spec field naming the spec it writes` |
| Delete the field line, relaunch case alone | `not ok - the relaunched brief lost the proof's spec field rule` |

The unmutated copy passed the relaunch case, so the relaunch control failed on the mutation and not on the copy.

## What I walked

I walked commit `3b5dd51d` on macOS 27.0 with GNU bash 5.3.15 and git 2.54.0, using the real `bin/fm-brief.sh` and `bin/fm-spec-point.sh` against a fresh scratch firstmate home.

1. Scaffolded six ship briefs, one per mode with `--spec docs/specs/lock.md` and one per mode without `--spec`, plus a `--matt-flow --spec docs/specs/matt.md` brief and a `--spec EvanAgee/firstmate#140` brief.
2. Every brief carried the field line after its Spec section.
   The `--spec` briefs said ``add `spec: docs/specs/lock.md` `` (and `docs/specs/matt.md` for the Matt-flow brief).
   The to-spec briefs said, for example, ``add `spec: docs/specs/walk-first-local-only.md` ``.
   The issue brief said ``add `spec: EvanAgee/firstmate#140` ``.
3. Every brief's first `Spec:` line was unchanged: `Spec: docs/specs/lock.md`, `Spec: docs/specs/matt.md`, `Spec: EvanAgee/firstmate#140`, or `Spec: to-spec phase`.
4. Built a scratch lane repository on `fm/walk` that added `docs/specs/walk-first-local-only.md` (the AC18 ticket spec, which lints clean), recorded its worktree in the task's meta, and ran `bin/fm-spec-point.sh walk-first-local-only`.
   It printed `pointed walk-first-local-only's brief at docs/specs/walk-first-local-only.md` and exited 0.
   A diff of the brief before and after showed exactly one changed line, `Spec: to-spec phase` to `Spec: docs/specs/walk-first-local-only.md`, and the field line was untouched.

I did not launch a real replacement agent for the relaunch path; the relaunch test drives `bin/fm-control.sh relaunch` end to end with a stubbed session provider, which is how this repository tests that verb.

## Follow-ups, not fixed here

- A `--spec` given as an issue reference yields `spec: EvanAgee/firstmate#140`, which is not a repository path, and the spec lock plans to resolve the field as a repository-relative Git path.
  This brief itself names an absolute path in the captain's private home, which the lock cannot read from a commit either.
  The lock ticket should decide how an issue or host-path spec reaches the proof field.
- `tests/fm-control-relaunch.test.sh` is not hermetic about routes: `bin/fm-route.sh` reads the checkout's `config/route-canonical-home` or the checkout itself, so on a machine whose claude route is exhausted the first case fails with `route 'claude' for claude/default is not currently eligible`.
  Setting `FM_ROUTE_HOME_OVERRIDE` in the test would isolate it.
- `test_relaunch_serializes_concurrent_durable_metadata_publication` waits a fixed two seconds for the trace hook and fails under heavy machine load.
