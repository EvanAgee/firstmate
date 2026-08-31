# Review-loop stop CLI transcript

This transcript records the executable helper as a crewmate and firstmate would use it. Paths from the temporary test home are normalized to `<FM_HOME>`.

```text
$ FM_HOME=<FM_HOME> bin/fm-review-loop-stop.sh record demo-task --run run-demo --head review-a --changed "Added request replay protection." --cluster "file:src/replay.ts"
continue: review round 1 recorded; no cluster reached 3 rounds
[exit 0]

$ FM_HOME=<FM_HOME> bin/fm-review-loop-stop.sh record demo-task --run run-demo --head review-b --changed "Preserved replay identity across retries." --cluster "file:src/replay.ts"
continue: review round 2 recorded; no cluster reached 3 rounds
[exit 0]

$ FM_HOME=<FM_HOME> bin/fm-review-loop-stop.sh record demo-task --run run-demo --head review-c --changed "Moved replay settlement before response delivery." --cluster "file:src/replay.ts"
# Repeated review clusters

Run: `run-demo`
Threshold: 3 consecutive review rounds

## What each cluster returned against

### `file:src/replay.ts`

- Round 1 reviewed `review-a`: Added request replay protection.
- Round 2 reviewed `review-b`: Preserved replay identity across retries.
- Round 3 reviewed `review-c`: Moved replay settlement before response delivery.

## Decision

- Fix at root. Repair the owning design before another review round.
- Bank the remainder. Keep the current work and route the unresolved findings to a follow-up.

Firstmate chooses under the task's existing authority rules.

stop: report=<FM_HOME>/state/review-loops/demo-task-run-demo-1.md
[exit 20]

$ FM_HOME=<FM_HOME> bin/fm-review-loop-stop.sh record demo-task --run run-demo --head review-d --changed "Tried another replay edge fix." --cluster "file:src/replay.ts"
stop: review clusters already surfaced in <FM_HOME>/state/review-loops/demo-task-run-demo-1.md
[exit 20]

$ sed <FM_HOME>/state/demo-task.status
needs-decision [key=review-loop-run-demo-1]: review clusters 'file:src/replay.ts' reached 3 rounds; choose fix at root or bank the remainder; report=<FM_HOME>/state/review-loops/demo-task-run-demo-1.md
status event count: 1

$ FM_HOME=<FM_HOME> bin/fm-review-loop-stop.sh resolve demo-task --run run-demo --decision bank
resolved: review-loop stop for run-demo recorded as bank

$ FM_HOME=<FM_HOME> bin/fm-review-loop-stop.sh record demo-task --run run-demo --head review-e --changed "Updated export formatting." --cluster "file:src/export.ts"
continue: review round 4 recorded; no cluster reached 3 rounds

$ jq '{threshold, generation, surfaced, resolution, rounds}' <FM_HOME>/state/review-loops/demo-task.json
{
  "threshold": 3,
  "generation": 2,
  "surfaced": null,
  "resolution": {
    "choice": "bank",
    "generation": 1,
    "clusters": [
      "file:src/replay.ts"
    ],
    "report": "<FM_HOME>/state/review-loops/demo-task-run-demo-1.md"
  },
  "rounds": [
    {
      "round": 1,
      "head": "review-a",
      "changed": "Added request replay protection.",
      "clusters": []
    },
    {
      "round": 2,
      "head": "review-b",
      "changed": "Preserved replay identity across retries.",
      "clusters": []
    },
    {
      "round": 3,
      "head": "review-c",
      "changed": "Moved replay settlement before response delivery.",
      "clusters": []
    },
    {
      "round": 4,
      "head": "review-e",
      "changed": "Updated export formatting.",
      "clusters": [
        "file:src/export.ts"
      ]
    }
  ]
}
```
