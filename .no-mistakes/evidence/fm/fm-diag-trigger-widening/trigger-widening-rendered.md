# Evidence: diagnostic-reasoning trigger widening

## 1. What an agent loads: .agents/skills/diagnostic-reasoning/SKILL.md

```markdown
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
A worker status line is a wake event rather than current state, so verify it with `bin/fm-crew-state.sh`, which owns current-state reconciliation.
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

```

## 2. AGENTS.md section 7 (Task lifecycle) trigger

```
     1	Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
     2	A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
     3	Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.
     4	A runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary carries the same trigger, as does repeating any second-hand claim about a cause as established fact.
     5	
```

## 3. AGENTS.md section 13 (Agent-only reference skills) trigger

```
- `bootstrap-diagnostics` - load whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line (`MISSING:`, `MISSING_MANUAL:`, `BACKEND_INVALID:`, `NEEDS_GH_AUTH`, `TANGLE:`, `STARTUP_MEMORY_BUDGET:`, `CREW_DISPATCH: invalid`, `FLEET_SYNC:`, `NETWORK_CHECKS:`, `PR_CHECK_MIGRATION:`, `SECONDMATE_SYNC:`, `SECONDMATE_LIVENESS:`, `SECONDMATE_HANDOFF:`, `NUDGE_SECONDMATES:`, or `FMX:`); silence and `BOOTSTRAP_INFO:` need no load.
- `diagnostic-reasoning` - load before scoping a reported bug, before acting on a diagnostic report, runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary, and before repeating any second-hand claim about a cause as established fact.
- `ask-user-authority` - load before deciding any ask-user finding, regardless of the project's `yolo` posture.
```

## 4. Every widened-trigger mention in the repo (exactly 2 in AGENTS.md, both sections)

```
AGENTS.md:291:A runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary carries the same trigger, as does repeating any second-hand claim about a cause as established fact.
AGENTS.md:545:- `diagnostic-reasoning` - load before scoping a reported bug, before acting on a diagnostic report, runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary, and before repeating any second-hand claim about a cause as established fact.
.agents/skills/diagnostic-reasoning/SKILL.md:5:  Use before scoping a reported bug, before acting on a diagnostic report, runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary, and before repeating any second-hand claim about a cause as established fact.
.agents/skills/diagnostic-reasoning/SKILL.md:15:A runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary is a report of broken behavior and carries the same trigger; the arriving format does not change the procedure owed.
```

## 5. AGENTS.md carries no second-hand-claim procedure prose (skill owns it)

```
$ grep -n "second-hand\|assertion, not an observation\|Verify it against" AGENTS.md
291:A runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary carries the same trigger, as does repeating any second-hand claim about a cause as established fact.
545:- `diagnostic-reasoning` - load before scoping a reported bug, before acting on a diagnostic report, runtime alert, monitoring signal, outage report, failing scheduled check, or triage summary, and before repeating any second-hand claim about a cause as established fact.
```
