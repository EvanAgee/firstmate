# Provider-availability routing

`bin/fm-route.sh` is the single shared admission gate for automatic provider selection across every approved route, currently Claude, Codex, Pi/Grok, and Pi/Gateway-DeepSeek.
It owns eligibility evidence, service-level fairness, and the assignment ledger; it never picks a concrete model or effort within a route, and it is never the launch owner.
`bin/fm-dispatch-resolve.sh`'s own profile pick then additionally excludes one model within an admitted route whose own quota-axi model-scoped window is exhausted, even while the account-wide bound `fm-route.sh` reads stays healthy (see "Model-specific limits" below); the two checks are deliberately separate, since a route stays admitted at the service level while one of its models can still be individually unavailable.
This is the Firstmate half of the design in `data/fm-dynamic-subscription-routing/report.md`'s "Addendum: minimum assignment routing", which superseded an earlier predictive-budget design.
A native no-mistakes integration (a trusted global admission hook inside the daemon, selecting from named native profiles) is a separate, not-yet-landed piece; this document is the exact interface contract that integration must call against, so the two owners never duplicate policy.

## Canonical owner home

One `state/route.json`, guarded by `state/.route.lock`, is the shared eligibility and assignment record for every local worker and every validation caller.
`fm-route.sh` resolves its own repo root as the canonical home by default, which is already correct for every local worker of the same checkout (they resolve the same repo root).
A secondmate is a separate tracked-code checkout with its own repo root, so it needs an explicit pointer: `config/route-canonical-home` holds one absolute path to the primary's canonical home, inherited into secondmate homes the same way `config/backend` already is (primary-authoritative).
`FM_ROUTE_HOME_OVERRIDE` wins over both, for tests and for a deliberately isolated pool.
Resolution order: `FM_ROUTE_HOME_OVERRIDE` env var, then `config/route-canonical-home`'s pointer if the path it names exists, then this script's own repo root.

## Route ids

Route ids are derived from `config/crew-dispatch.json`'s approved profiles (`rules[].use`, `rules[].pin`, `rules[].defaultPin`, `.default`) at the canonical home, never hardcoded.
`fm-route.sh group-for --harness <h> --model <m>` maps one profile to a route id by billing surface: `harness=claude` groups to `claude`; `harness=codex` groups to `codex`; any harness whose model starts with `xai/` groups to `pi-grok`; any harness whose model starts with `vercel-ai-gateway/` groups to `pi-deepseek`.
A profile whose harness/model matches no known billing surface still gets a route id (its harness name), so it is never silently dropped from the catalog; `fm-route.sh routes` lists the full derived catalog for the canonical home.
Multiple Claude models never multiply the `claude` route's slots: they all group to the same route id.

## CLI protocol

`acquire` and `finish` take one bounded JSON object on stdin and print one JSON object to stdout: a request that fails validation returns `{"result":"error","error":"<message>"}` and exits nonzero rather than launching anything.
No field is ever evaluated as an executable string; every value is a plain string, a plain array of strings, or a plain object of the shapes shown below.
Every other subcommand (`refresh`, `status`, `routes`, `group-for`, `disable`, `enable`) keeps ordinary flags: they carry no untrusted caller-supplied identity to bound the same way, and their existing shape stays stable across the JSON protocol change on `acquire`/`finish`.

### `acquire`

```sh
echo '{
  "assignment_id": "aos-4213",
  "owner": {"identity": "aos-4213", "generation": "s1789485000.4213.9021"},
  "routes": ["codex", "claude", "pi-grok", "pi-deepseek"]
}' | fm-route.sh acquire
```

Request fields (all required):

- `assignment_id`: a caller-chosen stable id (a task id, in Firstmate's own callers).
  A repeat call with the same `assignment_id` and the same `owner.identity`, while the record is `pending`/`running`/`closed`, returns that existing record unchanged (idempotent); `closed` never authorizes another launch, it only echoes what already happened.
  A `deferred` record is re-evaluated fresh on the next call with the same id (retriable), never returned stale, so newer eligibility evidence can admit it.
  A different `owner.identity` reusing an existing `assignment_id` is refused with a JSON error object.
- `owner.identity`: the identity that owns this assignment.
- `owner.generation`: a freshness token the caller supplies; stored on the record and read back by `finish`/inspection, but not itself part of the idempotency key.
  When the caller is `fm-spawn.sh` this is its own `spawn_gen`-shaped token (`s<epoch>.<pid>.<random>`), which `acquire`'s abandoned-owner reconciliation (below) compares directly against `state/<owner>.meta`'s `spawn_gen=`; any other shape is treated as an opaque freshness marker only, with no meta counterpart to reconcile against.
- `routes`: array of the caller's own approved candidate route ids for this launch (a subset of `fm-route.sh routes`'s output, and for a class-based caller exactly `fm-route.sh routes --class <class>`'s output). `acquire` never invents a route id outside this list and never picks a profile within the chosen route; an id not in the canonical catalog is refused with a JSON error object before anything is written.

Response, exactly one of four `result` values: `selected`, `deferred`, `already-closed`, `error`.
**Only `selected` carries a `route_id`, and only `selected` authorizes a launch.**
Every caller, including the separate native no-mistakes hook (`nm-native-assignment-routing`), must key on `result` and must never launch from a `route_id` read off any other shape.

```json
{"result":"selected","route_id":"codex","reason":"fewest-pending","generation":5}
```

```json
{"result":"deferred","reason":"every candidate route is excluded (exhausted, outage, auth-failed, or manually disabled)","generation":5}
```

```json
{"result":"already-closed","assignment_id":"aos-4213","generation":5,"note":"already closed; not relaunched"}
```

```json
{"result":"error","error":"assignment aos-4213 is already owned by a different owner"}
```

A closed assignment record is history, not a reusable slot: `already-closed` deliberately omits `route_id` so no caller can relaunch from a spent record, and it is not an authorization any more than `deferred` is.
A genuinely new attempt needs a NEW `assignment_id`.
`bin/fm-control.sh`'s relaunch admission does exactly that: it acquires under `<task-id>-relaunch-<generation>`, never the bare task id the original spawn already closed, so every relaunch gets a freshly evaluated decision against its own requested route.
`error` responses also exit nonzero.

`generation` here is `state/route.json`'s own monotonic decision/observation generation (bumped by `refresh`), distinct from the request's `owner.generation`.

Selection rule: among `routes` candidates whose last-refreshed state is `eligible` and not manually disabled, and after dropping any candidate's `pending`/`running` assignment whose owner is abandoned (see "Abandoned-owner reconciliation" below) from its count, pick the route with the fewest remaining `pending`/`running` assignments.
A genuine tie rotates through a monotonic `tieCursor` stored on `state/route.json` and advanced by one on every tie-broken pick, so a burst of concurrent ties spreads across the tied routes instead of always landing on the first-scanned one (`tests/fm-spawn-route-admission.test.sh` proves a real 20-process concurrent split).
`unknown` (unrefreshed or inconclusive telemetry) is never selected and never counted as proven unavailable; when every candidate is either excluded or unknown, `deferred` names which case applied so a caller can distinguish "wait for a verified reset" from "wait for the next refresh".

#### Abandoned-owner reconciliation

Before counting a candidate route's `pending`/`running` assignments, `acquire` drops any assignment whose owner is abandoned: no live `state/<owner>.meta` in the canonical home at all, or a live meta whose `spawn_gen=` no longer matches that assignment's stored `owner.generation` (the owner was torn down or relaunched under a new attempt).
Elapsed time alone never triggers this; only actual process/task/run ownership evidence does.

### `finish`

```sh
echo '{
  "assignment_id": "aos-4213",
  "outcome": "success",
  "profile": {"adapter": "codex", "model": "gpt-5", "effort": "high"}
}' | fm-route.sh finish
```

Request fields:

- `assignment_id`: required, the id to close.
- `outcome`: required, one of `success`, `launch-failed`, `auth-failed`, `exhausted`, `outage`.
- `profile`: optional `{adapter, model, effort}`, the actual resolved, nonsecret profile identity the caller launched, recorded on the closed assignment for a future session-reuse qualifier (by adapter/provider/effective-model/billing-route/settings) to key on, without `fm-route.sh` owning that qualification logic itself.

Closes the assignment idempotently: a second `finish` on an already-closed assignment succeeds with no effect and no state change.
An `auth-failed`/`exhausted`/`outage` outcome is verified failure evidence against that assignment's route: `finish` writes the route's own state to that value IMMEDIATELY, at decision time, never waiting for `refresh`'s next probe tick; `refresh`'s later fresh probe corroborates or clears it, and only a newer verified `eligible` reading clears the exclusion (never elapsed time alone).
`finish` never blocks on network I/O and never holds `state/.route.lock` while waiting on anything external: every field it writes was already decided by the caller before the call.

Response:

```json
{"result":"closed","assignment_id":"aos-4213"}
```

### `refresh` and `status`

```
fm-route.sh refresh
fm-route.sh status [--route <id>]
```

`refresh` re-reads non-inference health/quota evidence for every route in the canonical catalog and atomically republishes `state/route.json`'s `routes` map; it never runs inside `acquire`, so a stalled refresh timer degrades to stale (`unknown`-treated) evidence, never a hang.
Each route's recorded state is one of `eligible`, `exhausted`, `outage`, `auth-failed`, `unknown`, each carrying a `reason` string and an `observedAt` timestamp attributed to the evidence source, never to `refresh`'s own collection time.
`status` prints the current recorded state for one or every route without mutating anything.

### `routes`, `group-for`, `disable`, `enable`

```
fm-route.sh routes
fm-route.sh routes --class <class>
fm-route.sh group-for --harness <h> --model <m>
fm-route.sh disable --route <id>
fm-route.sh enable --route <id>
```

`routes` lists the derived catalog (see "Route ids" above).
`routes --class <class>` narrows that list to only the route ids that one class's own approved pool covers, derived from exactly the pool `bin/fm-dispatch-resolve.sh` resolves from (`rules[].use` for a named class, `.default` when the class names no rule).
A class-based caller must pass THIS list as `acquire`'s candidates, never the full catalog: `acquire` selecting a route the class has no member for would turn every real pool member into an `--exclude-routes` entry and refuse an otherwise healthy launch.
`group-for` is the single owner of the harness/model-to-route mapping; every other script (`bin/fm-dispatch-resolve.sh`'s `--exclude-routes`, `bin/fm-control.sh`'s relaunch admission) calls out to it rather than re-deriving the mapping.
`disable`/`enable` write `config/route-disabled` at the canonical home: a manual disable always wins over `refresh`'s own recorded state and survives every subsequent refresh, and only an explicit `enable` clears it.

## Evidence sources

Claude, Codex, and Grok all read through `quota-axi --provider <p> --json` (schemaVersion 3, live-verified against the installed `quota-axi`): a route's eligibility comes from `providers[].quotaSemantics.effectiveAvailability[]` scoped to `all_models` (claude, codex) or `all_products` (grok), reading `.effectivePercentRemaining`, gated by `providers[].state.{status,stale,refreshedAt,authStatus,error}`.
`state.status` of `auth_required` maps to `auth-failed`; `rate_limited` maps to `outage`; `error`, a stale report, or an `authStatus` of `expired_refreshable` all map to `unknown` (a live but not-yet-confirmed condition, never a guessed failure); an absent `effectivePercentRemaining` for the scope maps to `unknown`.
Grok's `providers[].credits.remaining` field is PREPAID balance and is never read by the eligibility probe at all; live-verified evidence: `quota-axi --provider grok --json` can report `credits.remaining: 0` in the same response where `quotaSemantics.status` is merely `unknown` because the windows are stale, which is exactly the "zero prepaid credits is not subscription exhaustion" case, proven against the real tool rather than a fixture.
Gateway/DeepSeek reads through `omp usage --provider vercel-ai-gateway --json` (live-verified shape: `{generatedAt, reports[], accountsWithoutUsage[], disabledCredentials[], capacity{}}`, with `reports[].limits[].amount.{used,limit,remaining,usedFraction,remainingFraction,unit}` when an account has usage); an empty `reports:[]` (the observed live state at authoring time: the authorized Gateway trial account has not yet recorded usage) maps to `unknown`, never `exhausted` and never an invented balance.

## Timeout and error behavior

- A health probe that cannot reach its source, cannot parse a usable observation timestamp, or reports a value that does not clearly prove eligibility or exhaustion records `unknown` with a `reason` explaining why, never a guessed state.
- Zero prepaid credits on a provider whose eligibility is subscription-scoped (Grok) is explicitly never read as subscription exhaustion (see "Evidence sources" above for the live-verified proof).
- Every write (`refresh`, `acquire`, `finish`, `disable`, `enable`) takes `state/.route.lock` via `bin/fm-wake-lib.sh`'s `fm_lock_acquire_wait`/`fm_lock_release` before reading, and publishes with a tmp-file-plus-`mv -f` atomic replace, so concurrent callers never interleave a partial write; twenty concurrent `acquire` calls against a two-route eligible pool split the assignments evenly with no lost updates, including the rotating-tie case (see `tests/fm-spawn-route-admission.test.sh` for a live concurrency proof at the `fm-spawn.sh` integration layer).
- `acquire` never blocks on network I/O: all quota/health evidence it reads was already written by the most recent `refresh`, and it never holds `state/.route.lock` while probing a provider.
  A caller that needs fresher evidence runs `refresh` itself first.
- `finish` never blocks on network I/O either; a failure outcome it records is applied to route state immediately under the same lock acquisition that closes the assignment, never deferred to a background probe.

## Model-specific limits

`bin/fm-dispatch-resolve.sh`'s own `model_exhausted` check, separate from `fm-route.sh`'s account-wide route admission, excludes one claude or codex pool member whose quota-axi `model:<name>` scope reports `effectivePercentRemaining <= 0`, even while that same account's `all_models` scope stays healthy.
This mirrors quota-axi's own documented model-window semantics: a model-specific window is an additional bound on top of the account-wide one, never a replacement for it, so a route can stay admitted while one of its models is individually exhausted (`tests/fm-dispatch-resolve.test.sh`'s `test_model_specific_exhaustion_excludes_only_that_model` proves this with a fake quota-axi reader whose `all_models` scope is 64% remaining and whose `model:fable` scope is 0%).
Non-claude/codex harnesses (Pi/Grok, Gateway/DeepSeek) carry no named model-scoped quota-axi window today and are never excluded by this check.

## Callers today

`bin/fm-dispatch-resolve.sh --exclude-routes <r1,r2,...>` marks matching pool members `enabled=false` for that one resolution call, without touching `config/crew-dispatch.json`; `bin/fm-spawn.sh` computes the caller's candidate routes with `fm-route.sh routes --class <class>`, pipes an `acquire` request as shown above, translates the non-selected routes into `--exclude-routes`, and pipes a `finish` request from its existing abort-cleanup trap so a failed launch releases its assignment exactly once.
A captain-supplied explicit `--harness` bypasses this admission entirely, the same way it already bypasses the pool's own `enabled` filter.
`bin/fm-control.sh`'s `relaunch` verb runs the same `acquire`/`finish` JSON pair around an authorized relaunch's already-resolved profile, before `safe_checkpoint` and before anything is stopped, so a refusal never touches the live process; it stays inert when the resolved route is not part of the canonical catalog at all (no routing policy configured for that profile).
Neither caller runs `refresh`; both assume a periodic timer (`bin/fm-route-refresh-install.sh`, following `bin/fm-watcher-beat-alarm-install.sh`'s pattern) keeps `state/route.json` current independent of any LLM turn.

## For the native no-mistakes integration

The native admission hook (task `nm-native-assignment-routing`) should shell out to `fm-route.sh acquire`/`finish` exactly as documented above: build the request JSON, write it to the subprocess's stdin, and parse one JSON object from stdout.
Do not add a second protocol, a wrapper CLI, or a text-line variant: this stdin/stdout JSON shape is the one public contract, matching the original interface design (`acquire(assignment_id, owner identity/generation, allowed route IDs)` returning selected/deferred plus route id, reason, and generation; `finish(assignment_id, normalized outcome)` closing idempotently).
Canonical shared-owner selection: a native worker running from the same firstmate checkout as local workers needs no configuration (it inherits the same repo-root resolution); a native worker running from a separate checkout (its own clone, a daemon-owned working directory) must set `FM_ROUTE_HOME_OVERRIDE` to the primary firstmate checkout's absolute path before invoking `fm-route.sh`, exactly as a secondmate does via `config/route-canonical-home`, so every caller shares the one `state/route.json`.
Never point a native worker's own database or session store at a second, separate route ledger: `state/route.json` at the canonical home is the only source of truth for pending/running counts and route eligibility.
