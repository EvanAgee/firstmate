# Availability decides the pool

Captain, 2026-09-18: "if we have availability of a harness it should be in the pool, otherwise it
shouldn't", and "we definitely need to be able to disable a model in case we want to preserve
subscription, etc."

Today one hand-set `enabled` flag carries three unrelated meanings, so a rung that is out for one
reason looks identical to a rung that is out for another, and none of them notice when the
underlying fact changes. This splits them.

## The problem, measured 2026-09-18

After `9c4fbbbb` landed, route admission reads the account pools honestly:

```
route=codex   eligible  "teamcodex pool: 1 of 5 accounts usable"
route=claude  eligible  "teamclaude pool: 3 of 5 accounts usable"
```

Both are still absent from every dispatch pool, because `config/crew-dispatch.json` carries
`enabled: false` on those entries from 2026-09-15. The flag outranks the live reading and never
expires.

Fifteen entries are currently disabled. Their own notes show three different reasons mixed into one
field:

| Reason | Entries | Example note |
| --- | --- | --- |
| Capacity, a window was burned | codex/gpt-5.6-sol (builder, tester, designer), codex/gpt-6-astra | "disabled while the Codex weekly window is exhausted (aos.tester 100%, reset ~2026-09-19)" |
| Preference, the captain chose something else for now | claude/opus, claude/sonnet, claude/fable, codex (researcher), pi/xai/grok-4.6 (researcher), pi glm-5.3-flash (builder) | "lean heavily on OMP Phala GLM 5.3 Flash and Kimi K3 for a while to relieve subscription pressure" |
| Broken, it fails under real load | pi/phala/z-ai/glm-5.3 | "second 429 storm on a builder first turn (13 x 429, retry exhausted) minutes after a clean probe" |

Only the first kind should be decided by a live reading. The second is the captain's standing
choice. The third is a defect and must not come back just because a probe looks clean.

## The change

Replace the single `enabled` boolean with availability plus two explicit, human-set fields.

**Availability is computed, never stored.** A rung is in the pool when its route reads eligible
through `bin/fm-route.sh`, which after `9c4fbbbb` reads the account pool for claude and codex. No
capacity fact is written into the config by hand, and nothing has to be remembered and reverted when
a window resets.

**`paused`** is the captain's preference switch, the thing he asked to keep. It takes a reason and
an optional `until` date. A paused rung stays out however much capacity it has. This is how
"preserve my Claude subscription this week" is expressed, and it is the only field firstmate sets on
the captain's word.

**`quarantined`** is for a rung proven to fail under real work, not a preference. It takes the
evidence and the exact condition for release. GLM 5.3 plain is the standing example: it probes clean
in 20 seconds and then dies with 13 rate-limit errors on a real brief, so a probe alone must never
readmit it. Its own note already states the release condition, "a probe that sends a real 20k-token
brief."

A rung dispatches only when it is available, not paused, and not quarantined.

## Migration of the fifteen

Do not carry the flags over mechanically. Sort each by the table above:

- Capacity-only entries lose their flag entirely and are governed by availability.
- Preference entries become `paused` with the captain's own words and date from the existing note.
- `pi/phala/z-ai/glm-5.3` becomes `quarantined`, carrying its 429 history and its release condition.

Preserve every existing note verbatim in a `history` field. Those notes are the evidence for why a
rung was ever excluded and several record real incidents. Losing them would repeat the incidents.

One judgment call, state it in the commit: `pi/phala/z-ai/glm-5.3-flash` is disabled on pi but
enabled on omp, and the note reads as preference ("one GLM entry stays as relief"). Treat it as
paused unless its history shows a defect, in which case quarantine it and say so.

## Acceptance criteria

1. With the live pool as it stands, `bin/fm-dispatch-resolve.sh --class builder
   --list-candidate-routes` includes codex and claude, because both read eligible and neither is
   paused or quarantined.
2. A paused rung never dispatches, at any capacity level, and the pause reason is visible in the
   resolver's output.
3. A quarantined rung never dispatches, and a passing probe does not readmit it.
4. A rung whose route reads exhausted does not dispatch, with no config edit required.
5. When that route's capacity returns, the rung dispatches again, with no config edit required.
   This is the whole point: capacity facts stop being written by hand.
6. An `until` date that has passed ends the pause on its own.
7. `pi/phala/z-ai/glm-5.3` is quarantined after migration and does not dispatch.
8. Every one of the fifteen entries keeps its original note under `history`.
9. A malformed or unreadable `config/crew-dispatch.json` refuses the spawn rather than silently
   dispatching everything. The current file already refuses spawns when invalid; keep that.
10. `shellcheck` clean, and the existing `tests/fm-dispatch-resolve*.test.sh` and
    `tests/fm-spawn-route-admission.test.sh` pass unchanged.

## Walked-path proof

Under `## What I walked` in the final commit body:

- The resolver's builder and researcher candidate lists before and after, showing codex and claude
  entering the pool.
- A paused rung proven not to dispatch while its route reads eligible.
- The quarantined GLM rung proven not to dispatch, including after a clean probe.
- An expired `until` proven to end a pause by itself.
- Names and results of the existing resolver and admission suites.

## Constraints

- firstmate shared tracked material, so load `firstmate-coding-guidelines` before editing.
- `bin/fm-dispatch-resolve.sh` and `config/crew-dispatch.json` gate every dispatch in the fleet,
  including the lane doing this work. A broken change here stops the fleet spawning anything, so
  keep the refuse-on-invalid behavior and prove it.
- `config/crew-dispatch.json` is gitignored local configuration. Migrate the live file in place and
  back it up first. Update `docs/examples/crew-dispatch.json` and `docs/configuration.md` to match
  the new schema.
- Do not touch the live pool readings themselves. `9c4fbbbb` owns those.
- One sentence per line in docs. Plain dash, never an em-dash. No agent co-author trailer.
- Commits authored as evanagee@gmail.com.

## Which rungs end up paused, decided 2026-09-18

The captain approved the spec together with firstmate's recommendation, so the migration lands in
this exact state:

- **Codex rungs are NOT paused.** Their exclusion was a burned weekly window, which is a capacity
  fact, and the pool now reports one usable account. Availability governs them from here: if the
  window is dry they stay out on their own, and when it resets they return on their own.
- **Claude rungs are NOT paused either.** CORRECTED 2026-09-18 after the captain pointed out that
  Claude has plenty of usage left. Firstmate had misread the pool percentages as remaining when they
  are USED, the exact confusion already recorded in `data/learnings.md` on 2026-09-14. The live
  reading is three usable accounts with Opus available, weekly used at 79%, 51% and 34%, one
  further account at 54% used but in an error state, and only `evan@superduperit.com` blocked at 98%.
  The 2026-09-15 pause was written to relieve subscription pressure that the numbers do not show, so
  it is a stale capacity guess rather than a standing preference. Claude is governed by availability
  from here.
- **`pi/phala/z-ai/glm-5.3` is quarantined**, per the table above.
- Every other preference entry becomes `paused` with its existing note and date.

If the migration would put a Claude rung back into a pool, that is a bug in the migration, not a
capacity decision.

## Note on scope

This does not permanently settle which rungs the captain wants paused. It makes the pause deliberate
and separate from capacity. After it lands, turning Claude back on is a one-line pause removal
rather than an edit to data that pretends to be a capacity fact.
