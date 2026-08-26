# Firstmate

Firstmate supervises a fleet of autonomous worker agents on behalf of one human. This glossary fixes the words used when talking about that world, including by the API and dashboards built on it.

## Language

**Captain**:
The human the whole system answers to.
_Avoid_: User, admin, owner

**Crewmate**:
An autonomous worker agent firstmate dispatched to carry out one task in an isolated worktree.
_Avoid_: Worker, agent, bot (ambiguous with firstmate itself)

**Task**:
One unit of dispatched work with a brief, a status log, and a lifecycle from spawn to done or failed.
_Avoid_: Job, ticket (tickets live in issue trackers; a task may come from one)

**Captain note**:
A message from the captain addressed to firstmate about a task. Firstmate decides how and whether to relay it to the crewmate; the captain never talks to a crewmate directly.
_Avoid_: Worker message, reply to worker

**Parked decision**:
A question a crewmate escalated that only captain-level authority can answer. Work on it waits until the answer arrives.
_Avoid_: Hold (the mechanism), question, blocker (a blocker is being stuck; a parked decision is awaiting a choice)

**Wake**:
A queued signal that makes firstmate look at something on its next supervision turn.

**Fleet snapshot**:
The assembled current picture of every task: statuses, stages, and liveness, gathered fresh at the moment of asking.

**Rig**:
A named pool of harness models good enough for one class of tasks. New tasks of that class spread evenly across the pool by round-robin. A single pool member is a **rung**; a rung can be enabled or disabled, and a rig can never have every rung off.
