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
Use quota only for a captain-facing health note.
Quota never selects, removes, ranks, or breaks a tie between pool members.
