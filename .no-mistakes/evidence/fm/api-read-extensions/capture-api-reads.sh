#!/usr/bin/env bash
# Capture live HTTP JSON for the four additive API reads.
# Speaks the public localhost API against a throwaway home; writes artifacts
# next to this script. Not a repo test.
set -eu

ROOT="${FM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
# Worktree path is passed in; do not guess.
if [ -z "${WORKTREE:-}" ]; then
  echo "WORKTREE is required" >&2
  exit 1
fi
ROOT="$WORKTREE"
EVIDENCE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=/dev/null
. "$ROOT/tests/api-helpers.sh"

split_http() {
  HTTP_CODE=
  HTTP_BODY=
  IFS= read -r HTTP_CODE || true
  HTTP_BODY=$(cat)
}

save() {
  local name=$1
  printf '%s\n' "$HTTP_BODY" > "$EVIDENCE/$name"
  printf 'saved %s status=%s bytes=%s\n' "$name" "$HTTP_CODE" "${#HTTP_BODY}"
}

home=$(fm_test_api_home api-evidence)
fakebin="$home/fakebin"
mkdir -p "$fakebin" "$home/data/ship-task" "$home/projects/alpha"

# --- rigs fixture ---
cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "note": "FLOOR RULE: nothing drops below Grok. codex gpt-5.6-sol is capped until 2026-09-01.",
  "rules": [
    {
      "when": "The task is a builder assignment.",
      "use": [
        { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" }
      ],
      "pin": { "harness": "claude", "model": "claude-opus-4-8", "effort": "high" }
    }
  ],
  "default": [
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" }
  ],
  "defaultPin": { "harness": "pi", "model": "xai/grok-4.6" }
}
EOF
printf 'pi\n' > "$home/config/crew-harness"
printf '# pinned by hand\nclaude opus high\n' > "$home/config/secondmate-harness"

# --- fleet / task-detail fixture ---
cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-07-07)
EOF
cat > "$home/data/ship-task/brief.md" <<'EOF'
# Task

Build the enrich window end to end.

# Extra

Not part of the prompt.
EOF
cat > "$home/state/ship-task.meta" <<EOF
window=firstmate:fm-ship-task
worktree=$home/projects/alpha
project=alpha
harness=claude
model=claude-opus-4-8
kind=ship
mode=ship
spawn_gen=s1756150000.123
yolo=off
EOF
# Three status lines written in two bursts so birth and mtime differ.
printf 'spawned: work begins\n' > "$home/state/ship-task.status"
sleep 2
printf 'working: first pass done\ndone: PR merged\n' >> "$home/state/ship-task.status"

# A delivery log that would have been the old pin source. Interpolation-only
# behavior must ignore it.
printf '123\twatcher started Wed Aug 26 14:04:51 2026\tsignal %s/state/ship-task.status\n' "$home" \
  > "$home/state/.watch-deliveries.log"

# --- captain-holds fixture ---
expected="$(cd "$home" && pwd)/data/backlog.md"
cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
[ -z "\${TASKS_AXI_FILE:-}" ] || { echo "leaked TASKS_AXI_FILE" >&2; exit 1; }
file=
args=()
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --file ]; then
    file=\$2
    shift 2
    continue
  fi
  args+=("\$1")
  shift
done
[ "\$file" = $(printf '%q' "$expected") ] || { echo "wrong --file: \$file" >&2; exit 1; }
set -- "\${args[@]}"
if [ "\${1:-}" = list ]; then
  printf '%s\n' '  ready-decision-key-a,captain,queued'
  printf '%s\n' '  blocked-hold,captain,queued'
  printf '%s\n' '  done-hold,captain,done'
  exit 0
fi
if [ "\${1:-}" = show ]; then
  case "\$2" in
    ready-decision-key-a)
      cat <<'EOF'
task:
  id: ready-decision-key-a
  title: "Pick the memory path"
  state: queued
  blocked: no
  blocked_by: none
  hold_reason: "Captain must choose"
  hold_kind: captain
  repo: firstmate
  created: 2026-08-20
EOF
      ;;
    blocked-hold)
      cat <<'EOF'
task:
  id: blocked-hold
  title: "Waits on another task"
  state: queued
  blocked: yes
  blocked_by: other-task
  hold_reason: "Blocked"
  hold_kind: captain
  repo: aos
  created: 2026-08-19
EOF
      ;;
    done-hold)
      cat <<'EOF'
task:
  id: done-hold
  title: "Already answered"
  state: done
  blocked: no
  blocked_by: none
  hold_kind: captain
  repo: firstmate
  created: 2026-08-18
EOF
      ;;
  esac
  exit 0
fi
exit 1
SH
chmod +x "$fakebin/tasks-axi"

# Record file times for interpolation check.
stat_birth=$(python3 - <<PY
import os, time
p = "$home/state/ship-task.status"
st = os.stat(p)
birth = getattr(st, "st_birthtime", None)
if birth is None:
    birth = st.st_ctime
print(int(birth * 1000))
print(int(st.st_mtime * 1000))
PY
)
birth_ms=$(printf '%s\n' "$stat_birth" | sed -n '1p')
mtime_ms=$(printf '%s\n' "$stat_birth" | sed -n '2p')
printf 'status_birth_ms=%s\nstatus_mtime_ms=%s\n' "$birth_ms" "$mtime_ms" \
  > "$EVIDENCE/status-file-clock.txt"

port=$(TASKS_AXI_FILE="$home/other-backlog.md" PATH="$fakebin:$PATH" fm_test_api_start "$home")
printf 'port=%s home=%s\n' "$port" "$home" > "$EVIDENCE/capture-meta.txt"

resp=$(fm_test_api_http "$port" /rigs GET 8000)
split_http <<<"$resp"
[ "$HTTP_CODE" = 200 ]
save rigs.json

resp=$(fm_test_api_http "$port" /tasks/ship-task GET 15000)
split_http <<<"$resp"
[ "$HTTP_CODE" = 200 ]
save task-detail.json

resp=$(fm_test_api_http "$port" /fleet GET 10000)
split_http <<<"$resp"
[ "$HTTP_CODE" = 200 ]
save fleet.json

resp=$(fm_test_api_http "$port" /captain-holds GET 8000)
split_http <<<"$resp"
[ "$HTTP_CODE" = 200 ]
save captain-holds.json

# Compact timeline vs file clock comparison for reviewers.
JSON="$HTTP_BODY" node -e '
const fs = require("fs");
const detail = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const clock = fs.readFileSync(process.argv[2], "utf8");
const birth = Number((clock.match(/status_birth_ms=(\d+)/) || [])[1]);
const mtime = Number((clock.match(/status_mtime_ms=(\d+)/) || [])[1]);
const events = detail.task.timeline.map((e) => ({
  index: e.index,
  verb: e.verb,
  observed_at: e.observed_at,
  observed_ms: Date.parse(e.observed_at),
  time_approximate: e.time_approximate,
}));
const first = events[0].observed_ms;
const last = events[events.length - 1].observed_ms;
const out = {
  harness: detail.task.harness,
  model: detail.task.model,
  started_at: detail.task.started_at,
  status_birth_ms: birth,
  status_mtime_ms: mtime,
  first_observed_ms: first,
  last_observed_ms: last,
  first_vs_birth_ms: first - birth,
  last_vs_mtime_ms: last - mtime,
  all_approximate: events.every((e) => e.time_approximate === true),
  non_decreasing: events.every((e, i, a) => i === 0 || e.observed_ms >= a[i - 1].observed_ms),
  ignored_delivery_log: true,
  events,
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
' "$EVIDENCE/task-detail.json" "$EVIDENCE/status-file-clock.txt" \
  > "$EVIDENCE/timeline-interpolation.json"

fm_test_api_stop "$home"
echo "capture complete"
