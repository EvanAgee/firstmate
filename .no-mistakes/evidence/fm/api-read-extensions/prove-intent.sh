#!/usr/bin/env bash
# Manual HTTP proof of the three required API-read hardening behaviors.
set -u
EVIDENCE_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0ZSRTC98B778W5RXVZZ6W26
# shellcheck source=/dev/null
. "$ROOT/tests/api-helpers.sh"

split_http() {
  HTTP_CODE=
  HTTP_BODY=
  IFS= read -r HTTP_CODE || true
  HTTP_BODY=$(cat)
}

pretty() {
  node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]), null, 2) + "\n")' "$1"
}

echo "=== 1. GET /rigs refuses a symlinked crew-dispatch.json ==="
home=$(fm_test_api_home prove-rigs-symlink)
printf '{"note":"SECRET-FROM-SYMLINK","rules":[{"when":"leaked","use":[{"harness":"codex"}]}]}\n' > "$home/elsewhere.json"
ln -s "$home/elsewhere.json" "$home/config/crew-dispatch.json"
port=$(fm_test_api_start "$home")
resp=$(fm_test_api_http "$port" /rigs)
split_http <<<"$resp"
echo "status=$HTTP_CODE"
pretty "$HTTP_BODY" | tee "$EVIDENCE_DIR/rigs-symlink-response.json"
echo "target=$(readlink "$home/config/crew-dispatch.json")"
echo "target-note=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).note)' "$home/elsewhere.json")"
fm_test_api_stop "$home"

echo
echo "=== 2a. GET /fleet still enriches a normal in-data brief ==="
home=$(fm_test_api_home prove-enrich-safe)
mkdir -p "$home/data/safe-task"
printf '# Task\n\nLegitimate in-data prompt\n' > "$home/data/safe-task/brief.md"
printf 'window=fixture:fm-safe\nharness=pi\nkind=ship\nmode=ship\nmodel=xai/grok-4.6\n' > "$home/state/safe-task.meta"
printf 'working: safe task\n' > "$home/state/safe-task.status"
port=$(fm_test_api_start "$home")
resp=$(fm_test_api_http "$port" /fleet GET 15000)
split_http <<<"$resp"
echo "status=$HTTP_CODE"
pretty "$HTTP_BODY" > "$EVIDENCE_DIR/fleet-safe-response.json"
node -e '
const d = JSON.parse(process.argv[1]);
const tasks = (d.tasks || []).map(t => ({ id: t.id, enrich: t.enrich || null }));
console.log(JSON.stringify({ status: process.argv[2], tasks }, null, 2));
' "$HTTP_BODY" "$HTTP_CODE" | tee "$EVIDENCE_DIR/fleet-safe-enrich-summary.json"
fm_test_api_stop "$home"

echo
echo "=== 2b. enrichFleetTasks refuses a task id of .. that would leave data/ ==="
home=$(fm_test_api_home prove-enrich-dotdot)
printf '# Task\n\nSECRET PROMPT FROM OUTSIDE DATA\n' > "$home/brief.md"
mkdir -p "$home/data/safe-task"
printf '# Task\n\nInside the data root\n' > "$home/data/safe-task/brief.md"
echo "outside-brief=$(cat "$home/brief.md")"
echo "resolved-escape=$(node -e 'const p=require("path"); console.log(p.resolve(process.argv[1],"data","..","brief.md"))' "$home")"
HOME_PATH="$home" MODULE_URL="file://$ROOT/bin/fm-api-reads.mjs" node --input-type=module <<'JS' | tee "$EVIDENCE_DIR/fleet-dotdot-enrich-summary.json"
import path from "node:path";
const { enrichFleetTasks } = await import(process.env.MODULE_URL);
const home = process.env.HOME_PATH;
const out = enrichFleetTasks(home, {
  roots: { data: path.join(home, "data") },
  tasks: [{ id: ".." }, { id: "safe-task" }],
});
process.stdout.write(JSON.stringify({
  outside_brief_path: path.resolve(home, "brief.md"),
  would_resolve_to: path.resolve(home, "data", "..", "brief.md"),
  escaped: out.tasks.find((task) => task.id === "..").enrich,
  safe: out.tasks.find((task) => task.id === "safe-task").enrich,
}, null, 2) + "\n");
JS

echo
echo "=== 3. GET /tasks/<id> interpolates timeline; delivery log is ignored ==="
home=$(fm_test_api_home prove-timeline)
cat > "$home/state/timed-task.meta" <<'EOF'
window=fixture:fm-timed-task
spawn_gen=s1756150000.123
harness=codex
model=gpt-5.6-sol
kind=ship
EOF
cat > "$home/state/timed-task.status" <<'EOF'
spawned: work begins
working: first pass done
done: PR merged
EOF
# Plant a delivery log with dates the old pin path would have used. The live
# clock must ignore this file.
mkdir -p "$home/state"
printf '123\twatcher Wed Aug 26 10:00:00 2026\tsignal %s/state/timed-task.status\n' "$home" > "$home/state/.watch-deliveries.log"
printf '124\twatcher Wed Aug 26 11:00:00 2026\tsignal %s/state/timed-task.status\n' "$home" >> "$home/state/.watch-deliveries.log"
printf '125\twatcher Wed Aug 26 12:00:00 2026\tsignal %s/state/timed-task.status\n' "$home" >> "$home/state/.watch-deliveries.log"
# Stretch birth vs mtime so interpolation is visible.
python3 - <<PY
import os, time
p = os.path.join("$home", "state", "timed-task.status")
now = time.time()
os.utime(p, (now - 3600, now))
print("status-birth-or-atime", now - 3600)
print("status-mtime", now)
PY
port=$(fm_test_api_start "$home")
resp=$(fm_test_api_http "$port" /tasks/timed-task GET 15000)
split_http <<<"$resp"
echo "status=$HTTP_CODE"
pretty "$HTTP_BODY" > "$EVIDENCE_DIR/task-detail-timeline-response.json"
node -e '
const d = JSON.parse(process.argv[1]);
const t = d.task || {};
const times = (t.timeline || []).map(e => ({
  verb: e.verb,
  observed_at: e.observed_at,
  time_approximate: e.time_approximate,
  ms: Date.parse(e.observed_at)
}));
const planted = [
  Date.parse("Wed Aug 26 10:00:00 2026"),
  Date.parse("Wed Aug 26 11:00:00 2026"),
  Date.parse("Wed Aug 26 12:00:00 2026"),
];
const usedPlanted = times.some(e => planted.includes(e.ms));
console.log(JSON.stringify({
  http_status: process.argv[2],
  harness: t.harness,
  model: t.model,
  started_at: t.started_at,
  timeline: times,
  used_delivery_log_times: usedPlanted,
  non_decreasing: times.every((e, i, a) => i === 0 || e.ms >= a[i-1].ms),
  all_approximate: times.every(e => e.time_approximate === true)
}, null, 2));
' "$HTTP_BODY" "$HTTP_CODE" | tee "$EVIDENCE_DIR/task-detail-timeline-summary.json"
stat -f 'status birth=%SB mtime=%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$home/state/timed-task.status" | tee "$EVIDENCE_DIR/task-detail-status-stat.txt"
fm_test_api_stop "$home"

echo
echo "evidence written under $EVIDENCE_DIR"
