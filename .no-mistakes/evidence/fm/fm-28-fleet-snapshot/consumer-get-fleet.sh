#!/usr/bin/env bash
# Consumer-facing GET /fleet walkthrough. Speaks real HTTP against throwaway homes.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../worktrees/b99440365b40/01M0YW8HA7YBC1SNRX42PRQEN0" && pwd)"
# The evidence dir is not the repo; resolve the worktree from this run.
if [ ! -f "$ROOT/bin/fm-api.sh" ]; then
  ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0YW8HA7YBC1SNRX42PRQEN0"
fi
EVIDENCE="/Users/evanagee/.no-mistakes/evidence/01M0YW8HA7YBC1SNRX42PRQEN0"
cd "$ROOT"
# shellcheck source=/dev/null
. "$ROOT/tests/api-helpers.sh"

write_fleet_fixture() {
  local home=$1
  mkdir -p "$home/projects/alpha"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-07-07)

## Queued
- [ ] queued-task - Queued Task (repo: alpha) (kind: ship) (since 2026-07-08)

## Done
- [x] done-task - Done Task (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: implementing the snapshot\n' > "$home/state/ship-task.status"
}

echo "=== 1. Empty home: GET /fleet ==="
home=$(fm_test_api_home api-fleet-empty-e2e)
port=$(fm_test_api_start "$home")
echo "home=$home"
echo "port=$port"
resp=$(fm_test_api_http "$port" /fleet GET 15000)
printf '%s\n' "$resp" | tee "$EVIDENCE/empty-home-http.txt"
code=$(printf '%s\n' "$resp" | head -n1)
body=$(printf '%s\n' "$resp" | tail -n +2)
printf '%s\n' "$body" | jq . > "$EVIDENCE/empty-home-fleet.json"
echo "status=$code schema=$(jq -r .schema "$EVIDENCE/empty-home-fleet.json") tasks=$(jq '.tasks|length' "$EVIDENCE/empty-home-fleet.json") records=$(jq '.backlog.records|length' "$EVIDENCE/empty-home-fleet.json")"
fm_test_api_stop "$home"

echo
echo "=== 2. Fixture home: GET /fleet ==="
home=$(fm_test_api_home api-fleet-fixture-e2e)
write_fleet_fixture "$home"
port=$(fm_test_api_start "$home")
echo "home=$home"
echo "port=$port"
resp=$(fm_test_api_http "$port" /fleet GET 15000)
printf '%s\n' "$resp" | tee "$EVIDENCE/fixture-home-http.txt"
code=$(printf '%s\n' "$resp" | head -n1)
body=$(printf '%s\n' "$resp" | tail -n +2)
printf '%s\n' "$body" | jq . > "$EVIDENCE/fixture-home-fleet.json"
echo "status=$code"
echo "schema=$(jq -r .schema "$EVIDENCE/fixture-home-fleet.json")"
echo "fm_home=$(jq -r .fm_home "$EVIDENCE/fixture-home-fleet.json")"
echo "task_ids=$(jq -c '[.tasks[].id]' "$EVIDENCE/fixture-home-fleet.json")"
echo "ship_task_state=$(jq -c '.tasks[] | select(.id=="ship-task") | .current_state' "$EVIDENCE/fixture-home-fleet.json")"
echo "backlog_states=$(jq -c '[.backlog.records[].state]' "$EVIDENCE/fixture-home-fleet.json")"
echo "backlog_ids=$(jq -c '[.backlog.records[].id]' "$EVIDENCE/fixture-home-fleet.json")"

echo
echo "=== 3. Same home via firstmate snapshot script ==="
script=$(FM_HOME="$(cd "$home" && pwd)" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s\n' "$script" | jq . > "$EVIDENCE/fixture-home-script.json"
python3 - <<'PY'
import json, pathlib
ev = pathlib.Path("/Users/evanagee/.no-mistakes/evidence/01M0YW8HA7YBC1SNRX42PRQEN0")
def strip(v):
    if isinstance(v, list):
        return [strip(x) for x in v]
    if isinstance(v, dict):
        return {k: strip(val) for k, val in v.items() if k not in ("generated", "observed_at")}
    return v
api = json.loads((ev / "fixture-home-fleet.json").read_text())
script = json.loads((ev / "fixture-home-script.json").read_text())
same = strip(api) == strip(script)
print("api_matches_script=" + ("yes" if same else "NO"))
if not same:
    print("api_keys", sorted(api))
    print("script_keys", sorted(script))
PY

echo
echo "=== 4. POST /fleet is rejected ==="
resp=$(fm_test_api_http "$port" /fleet POST 2000)
printf '%s\n' "$resp" | tee "$EVIDENCE/post-fleet-http.txt"

echo
echo "=== 5. Contract pointer from configuration.md ==="
rg -n -A3 'GET /fleet' "$ROOT/docs/configuration.md" | tee "$EVIDENCE/contract-docs.txt"

fm_test_api_stop "$home"
echo
echo "=== consumer walkthrough complete ==="
