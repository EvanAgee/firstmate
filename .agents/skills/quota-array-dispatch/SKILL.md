---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for picking one runner from a crew-dispatch pool
  by round-robin: the enabled, healthy member carrying the fewest live workers of
  that pool in this home, tie-broken by quota headroom, then list order.
  Load when a dispatch rule or default resolves to a pool with more than one member.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

## A pin short-circuits selection

A matched rule's `pin` selects its exact harness, model, and effort tuple for every new crewmate or scout dispatch in that class.
The top-level `defaultPin` does the same when intake reaches the `default` pool.
Round-robin applies only when that pool has no pin.
If the pinned member is switched off, absent from the pool, or proven unusable under the health rules below, stop and ask the captain instead of falling through to round-robin or another member.

This skill is the single owner of the round-robin pool selection procedure.
The name is kept for stability: `AGENTS.md`, `docs/configuration.md`, and the tests all reference it, so renaming it would break those triggers for no behavior gain.
Selection is round-robin now, not quota-optimizing; quota is only a health filter and a tie-break.

`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-member accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only, reports whatever granularity the vendor supplies, and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
Deterministic shell owns schema, configuration, and version validation plus concrete spawn safeguards.
Every model-to-provider, provider-to-credential, and quota-applicability relation is yours to establish transparently and to show your evidence for.

## The goal is even spread

Each rule's `use` array is a pool of runners, all good enough for that category of work.
The point is to spread new tasks evenly across the pool so no single runner piles up while the others sit idle.
Quota no longer chooses the runner; it only removes an unusable one and breaks a tie.

## Drop switched-off members first

A member carrying `"enabled": false` in `config/crew-dispatch.json` is switched off by the captain.
Remove every such member from the pool before you count live workers or collect a single quota fact.
A member with no `enabled` key is on, which is what every existing configuration means.

This filter is a hard lock in one direction only.
You may drop a member further on health evidence, but you may never re-enable a switched-off member, however tight the remaining pool is.
A switched-off member is not a tie-break candidate, not a fallback, and not eligible under the strongest-reasoning-class rule.
Do not report it as an accounted member either; it left the pool before selection began.

If the filter empties a pool, stop and ask the captain.
Never fall through to `config/crew-harness`, to a pay-per-token surface, or to any member the file does not list, exactly as the floor rule requires.

A switch takes effect on the next dispatch only.
A worker already running finishes on the runtime it launched with; never switch a live worker mid-task.

## Filter the pool to healthy members

Quota's job here is a health gate, not a ranking.
Run `quota-axi --json` once per intake and reuse that snapshot for every member.
Read `quota-axi auth --json` when a member's credential surface is in question.
Drop a member only when concrete evidence shows it cannot do the work:

- the authoritative catalog proves the model unsupported, or
- the credential the member actually selects is proven unusable, or
- the member is genuinely quota-tight for this task under the horizon evidence below.

Everything short of that keeps the member in the pool.
Missing model-level quota, a missing authentication source, unmeasurable headroom, an absent `state.authStatus`, an unknown scope, or a surface quota-axi does not model at all is disclosed uncertainty, not a reason to drop the member.
An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.

### Establish the provider relation before reading quota

Deterministic shell must never map a model to a provider, a provider to a credential store, or a name prefix to a family.
You establish those relations yourself, in the open, from the member's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.
Name the evidence for each relation you assert so the conclusion is inspectable.

1. Confirm the catalog lists the member's model and record the provider family it reports.
   A model the authoritative catalog does not list is concrete contradictory evidence: drop that member and quote the catalog result.
2. Apply quota at the granularity the vendor actually supplies.
   A provider-level or `all_models`/`all_products` scope bounds every model you established in that family, including one with no window of its own.
   A named-model or named-product scope is an additional bound for that model alone and is irrelevant to every other model in the family.
   Read `quotaSemantics.description`, which states the vendor's own bounding rule.
3. Record what remains unknown instead of converting it into a verdict.

### Authentication is scoped to the selected surface

A member authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the member actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the member's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the member.
Reserve login wording for the proven-unusable case, and name the harness, model, surface, and evidence.

When a credential's local classification is the only thing standing between a member and a drop, get ground truth before dropping.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the member does not use.

### What "genuinely quota-tight" means

Drop a member for quota only when known evidence shows it cannot carry this task to completion.
For each member preserve the horizon facts so the drop, or the decision to keep it, is inspectable:

- applicable effective headroom (`effectivePercentRemaining`) from the established provider/model scope
- usable runway status, `usableRunwaySeconds`, `projectedExhaustedAt`, `limitingWindowId`, `projectionConfidence`, and `projectionBasis`
- the task-completion horizon and the evidence and confidence used to estimate it
- effective pace and signed reserve per window (`reservePercentPoints = percentRemaining - timeRemainingPercent`; negative means usage is ahead of reset pace) for the tie-break below
- schema notes when runway or pace fields are absent

Stale raw windows are diagnostic, never headroom or fabricated runway.
Grok's `credits.remaining` is a prepaid balance unrelated to `percentRemaining`; never read it as exhaustion.
Read all windows named by `boundedBy`, `limitingWindowIds`, `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, `unknownWindowIds`, and `unmeasurableWindowIds`.
`unknown` is valid explicit uncertainty from quota-axi, not parser failure or permission to assume health.
Known runway that does not reach the likely-completion horizon is the signal that a member is quota-tight for this task; absent, `unknown`, or unmeasurable runway is not, and keeps the member in the pool.

When the whole pool is quota-tight, preserve the captain's strongest-reasoning class rather than silently downgrading it to conserve quota.
Dispatch inside that class when a member can proceed, or report that its strongest-class choice cannot proceed rather than downgrading it.

## Selection order

Apply this only to the healthy members left after the switch-off filter and the health filter.
Apply only among members satisfying required fit and strongest reasoning class; never use live-worker count, headroom, or reserve to silently replace that reasoning class.

1. Count the live workers each remaining member is currently carrying from this pool in this home.
   Match each in-flight worker to a pool member by the launched harness/model/effort tuple in spawn task metadata, and count only workers dispatched from this same pool.
   Two members on the same harness, such as claude/opus and claude/sonnet, are counted separately.
   Choose the member carrying the fewest.
2. If two or more members are tied on the fewest live workers, prefer the one with the most applicable effective headroom.
   Compare only on comparable known evidence, and never treat absent, `unknown`, or unmeasurable headroom as zero or as a healthy value.
   Use pace and signed reserve only as a later diagnostic tie-break among members still tied after headroom.
3. If members are still tied, choose by list order in the `use` array.
4. Malformed configuration or concrete contradictory evidence: stop and report the tuple and that evidence rather than selecting around it.
   Report duplicate concrete profiles as a configuration error.

Account for every member visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, live-worker count, and the headroom or reserve evidence used in any tie-break.
A dropped-credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label; the runner was chosen for even spread, not for maximum quota.
