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

A cluster is the smallest stable owner of the repeated problem.
Use the exact file as the default key, such as `file:src/lib/serve/exec-bridge.ts`.
Use `module:<directory>:<invariant>` when findings cross files but describe one broken invariant owned by that module.

Keep the key unchanged while later rounds patch another edge of the same owner or invariant.
A different exact file, module owner, or invariant is a new cluster and starts its own count.
Record every blocking cluster in the returned gate, not only the first finding.

## Record the round

For each Review gate with findings:

1. Get the no-mistakes run ID from the gate output or `no-mistakes axi status`.
2. Use the reviewed commit from the gate, or the current `git rev-parse HEAD`, as `--head`.
3. Write one sentence for `--changed` that says what the code reviewed in this round changed.
   For the first review, summarize the implementation commit.
   For later reviews, summarize the preceding no-mistakes review-fix commit.
4. Run the Firstmate code root's helper once with every cluster:

```sh
"<firstmate-code-root>/bin/fm-review-loop-stop.sh" record <task-id> \
  --run <run-id> \
  --head <reviewed-head> \
  --changed '<what this round changed>' \
  --cluster '<stable-cluster-key>'
```

Repeat `--cluster` when the gate has more than one cluster.
Pass `--threshold <rounds>` on the first record when this task needs a value other than three.
`FM_REVIEW_LOOP_THRESHOLD` provides the same per-run override.

Exit 0 means no cluster has reached the threshold.
Continue through the existing authority and gate-response rules.

Exit 20 means stop.
The helper has written a report and appended one keyed `needs-decision` event for firstmate.
Do not send another no-mistakes response and do not append a second status event.
End the turn so firstmate can choose one of the report's two paths.

## Resume only from firstmate's choice

When firstmate sends an exact decision, record it before following the supplied no-mistakes response command:

```sh
"<firstmate-code-root>/bin/fm-review-loop-stop.sh" resolve <task-id> --run <run-id> --decision root
```

Use `--decision bank` for an explicit bank-the-remainder choice.
The helper records the choice but never chooses the gate action.
For a root fix, it starts fresh counts for the report's clusters while keeping every other cluster's active streak.
For a bank choice, it archives the surfaced stop under the same rule so later Review gates can record new or still-open clusters.
Follow only the exact gate action firstmate authorized.
