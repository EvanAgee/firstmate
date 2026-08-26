# GET /fleet consumer walkthrough

A consumer started `bin/fm-api.sh` against throwaway firstmate homes and
spoke real HTTP to `127.0.0.1`. No source inspection.

## Empty home

`GET /fleet` → **200**

```json
{
  "schema": "fm-fleet-snapshot.v1",
  "tasks": [],
  "backlog": { "present": false, "records": [] }
}
```

Empty fleet, not an error. Full body: `empty-home-fleet.json`.

## Fixture home (tasks, statuses, stages)

`GET /fleet` → **200**, `schema=fm-fleet-snapshot.v1`

| surface | value |
| --- | --- |
| task ids | `["ship-task"]` |
| ship-task current_state.state | `unknown` (no live pane) |
| ship-task last_event | `working: implementing the snapshot` |
| backlog stages | `["in_flight","queued","done"]` |
| backlog ids | `["ship-task","queued-task","done-task"]` |

Full body: `fixture-home-fleet.json`.

## API agrees with firstmate

`GET /fleet` body equals `bin/fm-fleet-snapshot.sh --json` for the same home
after stripping `generated` / `observed_at`.

`api_matches_script=yes`

## Method contract

`POST /fleet` → **405** `{"ok":false,"error":"method not allowed"}`

## Documented JSON contract

`docs/configuration.md` states the body is `bin/fm-fleet-snapshot.sh --json`
(schema `fm-fleet-snapshot.v1`). The response itself carries `"schema":
"fm-fleet-snapshot.v1"`.
