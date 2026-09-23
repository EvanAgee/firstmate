---
name: backlog-reference
description: >-
  Agent-only backlog procedures that AGENTS.md section 10 summarizes.
  Use before filing, holding, parking, closing, or handing off a backlog item, before rewriting a backlog item's notes, and before dispatching a queued item.
user-invocable: false
metadata:
  internal: true
---

# backlog-reference

`AGENTS.md` section 10 keeps the work-items-only contract and update cadence inline; this skill holds the procedures moved out of it word for word.
Section numbers below refer to `AGENTS.md`.

When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item; use `tasks-axi hold <id> --reason "<reason>" --kind captain` for a captain-gated thread.
When the captain parks that thread for later, use `bin/fm-decision-hold.sh park`; `decision-hold-lifecycle` owns the policy.

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to section 6 rather than scattering it through task notes.
