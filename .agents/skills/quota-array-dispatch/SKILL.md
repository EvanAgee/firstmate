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

Name the task's dispatch class at intake.
Pass that class to `fm-spawn.sh` with `--class`.
`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
Routing precedence is an explicit captain per-task override recorded by `fm-spawn`, else the class pin, else round-robin by `fm-dispatch-resolve.sh` over whichever pool members provider-availability admission did not automatically exclude, else the configured default.
Each rule's `use` array is a pool: every member holds that category's quality floor and is good enough for the work, so new tasks spread evenly across the pool rather than piling onto whichever member comes first.
Read the resolver's recorded `dispatch_reason` to report whether a pin, round-robin, or the default selected the runtime.
Use ad hoc quota reads (`quota-axi`, `teamclaude status`, `teamcodex status`) only for a captain-facing health note; they never rank or break a tie between pool members.
The resolver's own `model_exhausted` check does read `quota-axi` automatically to drop one individually exhausted claude or codex model from a pool, which needs no manual step at intake.
Automatic provider-availability admission is a separate, narrower mechanism: [`docs/provider-availability-routing.md`](../../../docs/provider-availability-routing.md) owns it, `fm-spawn.sh` and an authorized `fm-control.sh relaunch` call it automatically unless an explicit `--harness` is passed, and it never needs a manual step at intake.
