---
name: review-loop-stop
description: >-
  Agent-only stop rule for repeated no-mistakes Review findings. Load after every Review gate returns findings and before another fix response.
user-invocable: false
metadata:
  internal: true
---

# Review loop stop

Use this after every no-mistakes Review gate that returns findings, including a gate resumed after firstmate answers an ask-user finding.
Run it before sending another `axi respond --action fix`.
The brief that loaded this skill gives the resolved absolute Firstmate code root.
Use that root for every helper call below, never the current project worktree.

## Define the clusters

A cluster is a stable identity for what the defect is, not the file it happens to live in.
Two different defects in one file are two clusters.
The same defect is one cluster even when its symptom moves to another file.
Derive the key from the finding's content, the broken behavior or invariant the review keeps flagging.
A file or module path may qualify the key but must never be the whole key.

- `defect:<short-stable-slug>` names the broken behavior, such as `defect:replay-identity-not-preserved`.
- `module:<directory>:<invariant>` names one broken invariant an owning module keeps violating across files.

Keep the key unchanged while later rounds patch another edge of the same defect or invariant.
A genuinely different defect is a new cluster and starts its own count, even in a file you have already touched.
Record every finding cluster the gate returned, at any severity and regardless of the action taken, so a recurring nonblocking defect is surfaced rather than silently dropped.

## Record the round

Run `"<firstmate-code-root>/bin/fm-review-loop-stop.sh" --help` for the exact commands, flags, exit codes, threshold, and state effects.
This skill owns only the judgment those flags need.

For each Review gate with findings, run the helper's `record` command once with:

- Every cluster the gate returned, one `--cluster` per cluster, keyed as above.
- The clusters this round's change tried to close, one `--targeted` per cluster.
  A cluster advances toward a stop only across rounds that both returned it and were aimed at it, so a defect that reappears while you were fixing a different one does not count against you.
  Name a cluster as targeted only when the reviewed change tried to close that defect.
- One `--changed` sentence saying what the reviewed code changed this round.
  Use the implementation commit for the first review and the preceding review-fix commit for later ones.
- The run ID from the gate output or `no-mistakes axi status`, and the reviewed commit (or `git rev-parse HEAD`) as `--head`.

When the helper stops the run, it has already written the report and surfaced the decision for firstmate.
Do not send another no-mistakes response and do not append a status event yourself.
End the turn so firstmate can choose one of the report's two paths.

## Resume only from firstmate's choice

When firstmate sends an exact decision, run the helper's `resolve` command with that decision before following the supplied no-mistakes response command.
The helper records the choice; it never chooses the gate action.
A root fix starts a fresh count for the surfaced clusters while keeping every other cluster's active streak.
A bank choice archives the stop so later gates can record new or still-open clusters.
Follow only the exact gate action firstmate authorized.
