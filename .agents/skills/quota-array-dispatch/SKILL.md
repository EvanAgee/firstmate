---
name: quota-array-dispatch
description: >-
  Agent-only intake procedure for naming a crewmate or scout dispatch class and
  handing deterministic runtime selection to fm-spawn.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

## Moved from AGENTS.md

`AGENTS.md` section 13 used to list this skill's load trigger, kept here word for word; `AGENTS.md` now triggers it from the operating section that uses it.

- `quota-array-dispatch` - load before naming a crewmate or scout dispatch class at intake.

These `AGENTS.md` sentences moved here word for word:

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, `docs/provider-availability-routing.md` owns automatic provider-availability admission, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
Routing precedence is an explicit captain per-task override recorded by `fm-spawn`, else the class pin, else round-robin by `fm-dispatch-resolve.sh` over whichever pool members provider-availability admission did not automatically exclude, else the configured default.
`fm-control.sh relaunch` runs the same automatic admission around an authorized relaunch's resolved profile before stopping the live agent, unless an explicit `--harness` is passed.
Each rule's `use` array is a pool: every member holds that category's quality floor and is good enough for the work, so new tasks spread evenly across the pool rather than piling onto whichever member comes first.

Name the task's dispatch class at intake.
Pass that class to `fm-spawn.sh` with `--class`.
Read the resolver's recorded `dispatch_reason` to report whether a pin, round-robin, or the default selected the runtime.
Use ad hoc quota reads (`quota-axi`, `teamclaude status`, `teamcodex status`) only for a captain-facing health note; they never rank or break a tie between pool members.
The resolver's own `model_exhausted` check does read `quota-axi` automatically to drop one individually exhausted claude or codex model from a pool, which needs no manual step at intake.
Automatic provider-availability admission is a separate, narrower mechanism: [`docs/provider-availability-routing.md`](../../../docs/provider-availability-routing.md) owns it, `fm-spawn.sh` and `fm-control.sh relaunch` call it automatically, and it never needs a manual step at intake.
