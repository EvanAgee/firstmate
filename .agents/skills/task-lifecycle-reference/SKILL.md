---
name: task-lifecycle-reference
description: >-
  Agent-only task lifecycle procedures that AGENTS.md section 7 summarizes.
  Use at task intake and before steering a worker, handling a validation run, reporting a ready PR, landing, teardown, or promoting a scout.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle-reference

`AGENTS.md` section 7 keeps every authority boundary, safety rule, and skill trigger inline; this skill holds the procedures it summarizes.
Section numbers below refer to `AGENTS.md`, and referenced scripts own exact commands, flags, and data mechanics.

## Intake and authority

An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

Before commissioning an investigation, consult existing reports and established evidence.
Once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
A scout is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.
If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
A separately requested review or audit with one named question remains scoped to that question.

On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
Record the resulting mode, yolo, and the one-line reason for any deviation in the backlog item note.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.

`bin/fm-flow.sh <project> fast|full|status` owns a project's flow flip between the full PR flow and the fast local-only flow, including its GitHub rulesets and the push-authority line in `data/captain.md`.

## Dispatch and steering

After spawning, confirm the worker is processing the brief, handle any trust dialog through `harness-adapters`, and record ship or scout work as under way.
Steer a worker with short single-line messages through fail-closed `fm-send`; put long instructions in a file.
`fm-send --resolve-key` closes a keyed decision identically for local and remote workers; `bin/fm-send.sh`'s header owns that contract, and `bin/fm-control.sh` owns the per-runtime lifecycle mechanics.
A persistent secondmate is recorded in the secondmate registry and runtime state.
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.

## Validate

For a no-mistakes ship, the ship brief has the worker start validation itself on the same worker after its implementation commit; do not send a separate validation trigger.
If a worker stalls after its implementation commit instead of starting validation, steer it into the run with the harness invocation owned by `harness-adapters`.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

### Supersession sequence

When a current, explicit captain instruction completely invalidates the work being validated, the same worker keeps the task instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
`AGENTS.md` section 7 owns the rule against any other hand-edit, commit, restart, or second run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

### Decisions and run state

Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## PR ready, landing, and teardown

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
`bin/fm-pr-autoarm.sh` automatically arms the merge poll when that status line contains one canonical GitHub pull request or GitLab merge request URL, and its delayed exact-branch scan recovers missed announcements through `bin/fm-pr-check.sh`.
Successful links stay silent.
Run `bin/fm-pr-check.sh <id> <PR url>` directly only when that PR is confirmed for the task and its watch is missing.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
The ship brief owns the post-done duty of the worker that opened a PR.
After successful teardown, retain only the configured recent Done history.

## Scout promotion

The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
