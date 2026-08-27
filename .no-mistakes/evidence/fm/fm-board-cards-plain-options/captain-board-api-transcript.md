# Captain board API evidence

Throwaway firstmate home with:
- two worker status files containing open internal needs-decision lines
- data/captain-queue.json with one good open card, one resolved card, and five bad cards (generic A/B/C, Option A prefix, lowercase a prefix, unmarked, jargon)
- tasks-axi listing two open captain holds and one done hold

## GET /captain-queue  (HTTP 200)

```json
{
  "ok": true,
  "updatedAt": "2026-08-27T16:00:00Z",
  "items": [
    {
      "id": "fm-memory-path",
      "num": 3,
      "question": "Keep trimming memory, or adopt a vault?",
      "context": "The research recommends staying with trim.",
      "commands": [],
      "options": [
        "Stay with trim (recommended)",
        "Adopt a vault",
        "Something else"
      ],
      "recommended": "Stay with trim (recommended)",
      "askedAt": "2026-08-26T20:45:00Z",
      "status": "open",
      "project": "firstmate"
    }
  ]
}
```

## GET /captain-holds  (HTTP 200)

```json
{
  "ok": true,
  "holds": [
    {
      "id": "ready-decision-key-a",
      "title": "Pick the memory path",
      "reason": "Captain must choose",
      "repo": "firstmate",
      "createdAt": "2026-08-20",
      "blockedBy": [],
      "actionable": true,
      "done": false,
      "answerable": true
    },
    {
      "id": "blocked-hold",
      "title": "Waits on another task",
      "reason": "Blocked",
      "repo": "aos",
      "createdAt": "2026-08-19",
      "blockedBy": [
        "other-task"
      ],
      "actionable": false,
      "done": false,
      "answerable": false
    }
  ]
}
```
