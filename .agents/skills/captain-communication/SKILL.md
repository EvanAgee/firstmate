---
name: captain-communication
description: >-
  Agent-only rewrites and reply habits for captain-facing chat that AGENTS.md section 9 summarizes.
  Use before writing any captain-facing message that reports worker, validation, supervision, or fleet state.
user-invocable: false
metadata:
  internal: true
---

# captain-communication

`AGENTS.md` section 9 keeps the outcome-first rule, the internal-term list, the escalation rules, and the reach-the-captain list inline; this skill holds the rewrites and habits moved out of it word for word.

Use the captain's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
When evidence uses an internal label, rewrite it before sending:

- worktree, checkout, primary checkout, or local-main -> local copy, isolated copy, or local branch, only if the location matters.
- teardown -> cleanup.
- wake, watcher, heartbeat, stale, signal, or check -> notification, monitoring, waiting too long, or stopped responding.
- hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision, wait, approval, blocker, or external delay.
- done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, review finding, passing checks, failed check, or stopped validation.
- brief -> instructions.
- crewmate -> worker, only when naming the helper matters.
- harness, backend, runtime, or adapter -> worker runtime or tool, only when the tool choice itself blocks work.
- status file, metadata, state, task id, or raw path -> durable record, local record, or omit it unless the captain needs the file path to act.
- fail-closed, fails closed, fail loudly, or refuses loudly -> stops safely when something goes wrong, refuses rather than proceeding, or reports the concrete missing requirement.
- fail-open, fails open, passive fail-open, or degraded-open -> steps aside and lets work continue when the check cannot complete, or continues without that optional protection.

Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms when they are useful, but the captain-facing chat summary that points to the report still follows this translation rule.
Use the same evidence-first form for objections or clarifying challenges rather than unsupported deference.

## After a restart

Surface only captain-relevant decisions, review-ready PRs, failures, and credential needs; otherwise resume the emitted supervision protocol silently.

## PR mentions and routine replies

Tell the captain the PR's full URL, always the complete `https://...` link rather than a bare `#number`, a concise outcome summary, and the no-mistakes risk level when applicable.
Whenever a PR is mentioned, include its full `https://...` URL before any shorthand reference.
Batch non-urgent updates into the next natural reply.
Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
Mention cost as a courtesy when unusually much work is running, but never block on it.
