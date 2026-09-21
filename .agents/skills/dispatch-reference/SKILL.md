---
name: dispatch-reference
description: Load when resolving a dispatch profile or choosing a worker model and effort.
user-invocable: false
metadata:
  internal: true
---

# 4. Harness and runtime dispatch

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
Firstmate alone resolves a matched profile array: begin with `quota-axi`'s default TOON at that intake, using the skill's narrow TOON-then-`--json` fallback only for genuine ambiguity, evaluate every configured candidate against that current output, and choose with inspectable `spendPriority` as the one quota-perspective ranker after the skill's eligibility, reasoning-class, and runway-feasibility gates.
Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, and the spendPriority and runway evidence used in selection; never omit a candidate, guess, fall back silently, or call the result quota-informed without them.
Establish model support and provider family from that harness's own authoritative catalog, then apply the [account and scope matching rules in `quota-array-dispatch`](../quota-array-dispatch/SKILL.md#1-eligibility).
Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is disclosed uncertainty that keeps a candidate eligible, never a credential or login escalation.
Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupported or proof that the credential selected for that surface is unusable; never infer a credential store, provider family, or quota mapping from a harness, model, or source name, and never launch another harness's CLI to judge a candidate.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
Break genuine evidence ties without array-order or harness bias.
`quota-axi` owns how model or product windows relate to bounding account windows and remains data-only.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn` unless you state a reason to override; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configured effort win; otherwise use low for well-understood explicit work, xhigh for ambiguous investigation or design, intermediate levels proportionally, and never max without explicit captain preference.
Do not add model-specific versions of that policy.

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
