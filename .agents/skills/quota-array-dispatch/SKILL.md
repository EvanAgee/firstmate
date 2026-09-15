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
Read the resolver's recorded `dispatch_reason` to report whether a pin, round-robin, or the default selected the runtime.
Use ad hoc quota reads (`quota-axi`, `teamclaude status`, `teamcodex status`) only for a captain-facing health note; they never select, remove, rank, or break a tie between pool members.
Automatic provider-availability admission is a separate, narrower mechanism: [`docs/provider-availability-routing.md`](../../../docs/provider-availability-routing.md) owns it, `fm-spawn.sh` and `fm-control.sh relaunch` call it automatically, and it never needs a manual step at intake.
