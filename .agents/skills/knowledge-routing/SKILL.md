---
name: knowledge-routing
description: >-
  Agent-only destinations for durable Firstmate knowledge that AGENTS.md section 6 summarizes.
  Use before recording a captain preference, a fleet fact, a task note, an investigation finding, or project knowledge anywhere durable.
user-invocable: false
metadata:
  internal: true
---

# knowledge-routing

`AGENTS.md` section 6 keeps the project-memory boundaries inline; this skill is the source of truth for destinations.
Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory.

Route durable knowledge to its most specific owner:

- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under the `secondmate-provisioning` contract.
- Fleet-local operational facts belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`.
- Knowledge general to every firstmate user belongs in this repo's shared tracked surface.

A crewmate creates or updates a project's `AGENTS.md` lazily through the project's selected delivery path, using `bin/fm-ensure-agents-md.sh` and preferring pointers to authoritative sources over copied detail.
