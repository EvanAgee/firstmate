---
name: diagnostic-reasoning
description: >-
  Agent-only procedure for diagnosing reports of broken behavior.
  Use before scoping a reported bug, before acting on a diagnostic report, runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary, and before repeating any second-hand claim about a cause as established fact.
  Owns end-user-aligned reproduction, causal separation, divergent-path and history inspection, counterfactual testing, disconfirming evidence, and the second-hand claim rule.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug and before acting on a diagnostic report.
A runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary is a report of broken behavior and carries the same trigger; the arriving format does not change the procedure owed.
This skill is the single owner of Firstmate's bug-diagnosis reasoning procedure.
Firstmate applies it when briefing delegated investigation and evaluating the resulting evidence, without taking over project-specific investigation itself.

## Never repeat a second-hand claim as fact

A claim written by a triage post, an alert body, an issue comment, a worker status line, a report, or a prior session is an assertion, not an observation.
Verify it against the live system, the run history, or the code before repeating it to the captain, carrying it into an issue, or reasoning from it.
This applies to any factual claim, including one you wrote yourself in an earlier turn.

Three checks, each cheap, each earned by a real failure:

- **Is it current?**
  A closed issue may be shipped rather than abandoned; check the merge and the code before calling the work missing.
- **Is it a pattern or a single event?**
  "Fifth time this month" needs the actual run history, not a sentence asserting it.
- **Is the evidence real or absent?**
  An empty field is a missing observation, never proof of an empty result; read the producing code before treating any value as evidence.

One observation is not a pattern, and a transient failure can heal itself between the alert and the investigation.
Re-observe before declaring any failure permanent, and before recommending an action a person cannot undo.
When a claim cannot be verified, say it is unverified in the same sentence that carries it, never in a later qualification.

## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Test the causal explanation

Inspect the failing path and a proven path where the intended behavior is known to work.
Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.

## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.
