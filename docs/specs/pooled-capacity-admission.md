# Pooled capacity in route admission

Route admission asks one account whether a service has room. Two of the services are local proxy
pools holding several accounts each. One blocked account speaks for the whole pool, so admission
excludes a service that still has usable capacity.

Captain authorized the spec on 2026-09-18.

## Evidence

Measured in this checkout on 2026-09-18, not from memory.

`bin/fm-route.sh status` reports:

```
route=codex state=exhausted reason="codex effective remaining at 0% for scope all_models"
```

`teamcodex status --json` for the same moment reports five accounts:

```
evan@superduperit.com        disabled=false  unavailable=quota
evanagee@gmail.com           disabled=true   unavailable=disabled
the.tarman2@gmail.com        disabled=false  unavailable=quota
aos.tester@superduperit.com  disabled=false  unavailable=quota
technomadevan@gmail.com      disabled=false  unavailable=none
```

One account is usable and admission calls the service exhausted. `teamclaude status --json` has the
same per-account shape and currently shows three of five usable while admission reads a single
credential at 49%.

Earlier cost, from `data/learnings.md` 2026-09-17: admission read Codex at 0% while a pooled account
sat at 64% used, so work went to an open-weight relief route that then died twice in one hour. Two
lanes needed hand-built relaunch notes.

## Root cause

`bin/fm-route.sh:272` defines `fm_route_probe_quota_axi`, shared by three routes. It shells out to
`quota-axi --provider <p> --json`, which reads one OAuth credential. `quota-axi` has no concept of a
pool. Line 405-407 route `claude`, `codex`, and `pi-grok` through it.

The proxies are local services with their own JSON. Nothing reads them.

## Scope

Change `claude` and `codex` only. Both sit behind a pool.

`pi-grok` stays on `quota-axi`. Grok has no pool. Its current `unknown` reading is an expired local
token with a known self-serve fix already recorded in `data/learnings.md`, a separate problem.

Out of scope: the `pi` route reading `launch-failed` since 2026-09-17, and per-model windows inside
an account (the untouched `GPT-5.3-Codex-Spark` and `gpt-reserve` lines). Both are real and neither
is this bug. File follow-ups if they still stand after this lands.

## The change

Add one probe that reads a pool's JSON and answers whether any account is usable. Point the two
pooled routes at it. Keep everything else.

Usable means `disabled == false` and `unavailable` is absent or `none`. Both fields are already in
the JSON, so no percentage math and no threshold to tune.

- Any account usable, service is `eligible`.
- All accounts present but none usable, service is `exhausted`.
- Pool command missing, non-zero, unparseable, or reporting zero accounts, fall back to the existing
  `fm_route_probe_quota_axi` call for that provider, unchanged.

That fallback is the safety property. A broken pool reader must never be worse than today. It also
keeps the probe working on a machine with no proxy installed.

Follow the existing pattern at `bin/fm-route.sh:265`: make the pool command names overridable
(`FM_ROUTE_TEAMCODEX_BIN`, `FM_ROUTE_TEAMCLAUDE_BIN`) so tests substitute fake readers on PATH, the
way `FM_ROUTE_QUOTA_AXI_BIN` already works.

Emit `observed_at` from the pool's own reading, not wall clock. The header at
`bin/fm-route.sh:250` requires this. `probe.lastRunFinishedAt` is the pool's timestamp and is epoch
milliseconds, so convert it. `bin/fm-route.sh:386` already documents the same millisecond handling
for omp, so reuse that approach rather than inventing one.

Accounts live at `.accounts` or `.probe.accounts` depending on the reader. Handle both, as the
evidence commands above do.

## Reason strings

A reason must say which pool and how many accounts were usable, because the whole point is making
the invisible visible. Shape:

```
eligible   teamcodex pool: 1 of 5 accounts usable
exhausted  teamcodex pool: 0 of 5 accounts usable
```

On fallback, say so plainly, for example `teamcodex unreadable, fell back to quota-axi: <its
reason>`. A silent fallback recreates the same blindness one level up.

## Acceptance criteria

1. With the live pool in its current state, `bin/fm-route.sh refresh && bin/fm-route.sh status`
   reports `route=codex state=eligible` naming the usable account count.
2. A fake reader with every account blocked yields `exhausted`.
3. A fake reader with one account usable and four blocked yields `eligible`. This is the bug.
4. A missing pool command falls back to `quota-axi` and reports the fallback in the reason.
5. A pool command returning malformed JSON, exit non-zero, or zero accounts also falls back. No
   crash, no silent `unknown`.
6. `pi-grok`, `pi-deepseek`, and the no-probe path are byte-identical in behavior. Prove it by
   running the existing `tests/fm-route.test.sh` and
   `tests/fm-spawn-route-admission.test.sh` unchanged.
7. `observed_at` for a pooled probe comes from the pool's own timestamp, not the collection time.
8. `shellcheck` clean.

Tests go in the existing `tests/fm-route.test.sh` next to the current probe tests, using the
established fake-binary-on-PATH pattern. No new framework.

## Walked-path proof

Required under `## What I walked` in the final commit body:

- `bin/fm-route.sh status` before the change, showing `codex` exhausted.
- The live `teamcodex status --json` per-account table for the same moment.
- `bin/fm-route.sh status` after, showing `codex` eligible with the account count.
- Each fallback path exercised once, with its exact reason string.
- Names and results of the existing route tests, proving the unpooled routes did not move.

## Constraints

- firstmate shared tracked material, so load `firstmate-coding-guidelines` before editing.
- `bin/fm-route.sh` gates every dispatch. Additive only. Do not restructure the probe dispatch
  beyond pointing the two pooled routes at the new function.
- Do not read account emails, tokens, or credentials into any log, reason string, or status output.
  Counts only. The reason line is captain-facing and lands in durable state.
- No new dependency. `jq` is already used throughout this file.
- One sentence per line in docs. Plain dash, never an em-dash. No agent co-author trailer.
- Commits authored as evanagee@gmail.com.

## Open question for the captain

Not blocking, decide before or during the lane.

When a pool has one account at 98% used and one at 30%, this spec calls the service eligible,
because the proxy routes to the account with room and its own switch threshold is 98%. The
alternative is requiring some headroom margin before calling a pool healthy.

Eligible-if-any, as specced: matches what the proxy actually does, no threshold to tune, uses paid
capacity. Risk is admitting a pool whose last usable account is nearly full, so a long lane could
exhaust it mid-run.

Margin rule: leaves a buffer for lanes already running. Cost is a number nobody can derive, it would
need tuning by hand, and it would idle capacity you already pay for.

Recommendation: ship eligible-if-any. The proxy already owns switching, and duplicating that
judgment in admission is the kind of second opinion that drifts out of sync.
