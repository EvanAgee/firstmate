#!/usr/bin/env bash
# Append one task's delivery timing to data/delivery-log.jsonl.
#
# The caller supplies facts known only at landing time. This script adds the
# dispatch timestamp from state/<task-id>.meta and the matching no-mistakes run
# timing while both sources are available. Unavailable facts are JSON null.
#
# Ledger record:
#   task_id, repo, pr_url, dispatched_at, no_mistakes_started_at,
#   pr_opened_at, merged_at, review_rounds [{round, minutes}],
#   active_fix_minutes, test_minutes, document_minutes, parked_ms.
#
# Usage:
#   fm-delivery-record.sh <task-id> --repo <name> \
#     [--project-path <path>] [--branch <name>] [--pr-url <url>] \
#     [--pr-opened-at <ISO-8601>] [--merged-at <ISO-8601>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NO_MISTAKES_DB="${FM_DELIVERY_DB:-$HOME/.no-mistakes/state.sqlite}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  printf '%s\n' \
    'Usage: fm-delivery-record.sh <task-id> --repo <name>' \
    '       [--project-path <path>] [--branch <name>] [--pr-url <url>]' \
    '       [--pr-opened-at <ISO-8601>] [--merged-at <ISO-8601>]'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=${1:-}
case "$ID" in
  ''|*[!A-Za-z0-9._-]*|.*|-*)
    echo "error: invalid task id" >&2
    exit 2
    ;;
esac
shift

REPO=
PROJECT_PATH=
BRANCH=
PR_URL=
PR_OPENED_AT=
MERGED_AT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      REPO=${2:-}
      shift 2
      ;;
    --project-path)
      PROJECT_PATH=${2:-}
      shift 2
      ;;
    --branch)
      BRANCH=${2:-}
      shift 2
      ;;
    --pr-url)
      PR_URL=${2:-}
      shift 2
      ;;
    --pr-opened-at)
      PR_OPENED_AT=${2:-}
      shift 2
      ;;
    --merged-at)
      MERGED_AT=${2:-}
      shift 2
      ;;
    *)
      echo "error: unknown delivery record argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO" ]; then
  usage >&2
  exit 2
fi

META="$STATE/$ID.meta"
if [ -z "$PROJECT_PATH" ] && [ -f "$META" ] && [ ! -L "$META" ]; then
  PROJECT_PATH=$(sed -n 's/^project=//p' "$META" | head -n 1)
fi
if [ -z "$BRANCH" ] && [ -f "$META" ] && [ ! -L "$META" ]; then
  WORKTREE=$(sed -n 's/^worktree=//p' "$META" | head -n 1)
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  fi
fi
if [ -z "$BRANCH" ]; then
  BRANCH="fm/$ID"
fi

epoch_to_iso() {
  local epoch=$1
  if date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return 0
  fi
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

DISPATCHED_AT=
if [ -f "$META" ] && [ ! -L "$META" ]; then
  SPAWN_GEN=$(sed -n 's/^spawn_gen=//p' "$META" | head -n 1)
  if [[ "$SPAWN_GEN" =~ ^s?([0-9]{10,13})(\.|$) ]]; then
    SPAWN_EPOCH=${BASH_REMATCH[1]}
    if [ "${#SPAWN_EPOCH}" -eq 13 ]; then
      SPAWN_EPOCH=$((SPAWN_EPOCH / 1000))
    fi
    DISPATCHED_AT=$(epoch_to_iso "$SPAWN_EPOCH" || true)
  fi
fi

sql_quote() {
  local value=$1
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

NM_JSON=
if [ -f "$NO_MISTAKES_DB" ] && [ ! -L "$NO_MISTAKES_DB" ]; then
  PROJECT_SQL=$(sql_quote "$PROJECT_PATH")
  BRANCH_SQL=$(sql_quote "$BRANCH")
  PR_URL_SQL=$(sql_quote "$PR_URL")
  NM_JSON=$(sqlite3 -readonly -noheader "$NO_MISTAKES_DB" <<SQL 2>/dev/null || true
WITH matching AS (
  SELECT r.id, r.created_at, r.parked_ms
  FROM runs r
  JOIN repos p ON p.id = r.repo_id
  WHERE (r.branch = $BRANCH_SQL AND p.working_path = $PROJECT_SQL)
     OR ($PR_URL_SQL <> '' AND r.pr_url = $PR_URL_SQL)
), ordered_rounds AS (
  SELECT
    row_number() OVER (ORDER BY m.created_at, sr.created_at, sr.round, sr.id) AS round_number,
    round(sr.duration_ms / 60000.0, 3) AS minutes
  FROM matching m
  JOIN step_results s ON s.run_id = m.id AND s.step_name = 'review'
  JOIN step_rounds sr ON sr.step_result_id = s.id
)
SELECT json_object(
  'no_mistakes_started_at',
    (SELECT strftime('%Y-%m-%dT%H:%M:%SZ', min(created_at), 'unixepoch') FROM matching),
  'review_rounds',
    CASE WHEN EXISTS (SELECT 1 FROM matching)
      THEN json(COALESCE((
        SELECT json_group_array(json_object('round', round_number, 'minutes', minutes))
        FROM ordered_rounds
      ), '[]'))
      ELSE NULL
    END,
  'active_fix_minutes',
    CASE WHEN EXISTS (SELECT 1 FROM matching) THEN (
      SELECT round(COALESCE(sum(a.duration_ms), 0) / 60000.0, 3)
      FROM matching m
      LEFT JOIN agent_invocations a ON a.run_id = m.id AND a.purpose = 'review-fix'
    ) ELSE NULL END,
  'test_minutes', (
    SELECT round(sum(s.duration_ms) / 60000.0, 3)
    FROM matching m
    JOIN step_results s ON s.run_id = m.id AND s.step_name = 'test'
  ),
  'document_minutes', (
    SELECT round(sum(s.duration_ms) / 60000.0, 3)
    FROM matching m
    JOIN step_results s ON s.run_id = m.id AND s.step_name = 'document'
  ),
  'parked_ms', (SELECT sum(parked_ms) FROM matching)
);
SQL
)
fi

if ! printf '%s' "$NM_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  NM_JSON='{
    "no_mistakes_started_at": null,
    "review_rounds": null,
    "active_fix_minutes": null,
    "test_minutes": null,
    "document_minutes": null,
    "parked_ms": null
  }'
fi

RECORD=$(jq -cn \
  --arg task_id "$ID" \
  --arg repo "$REPO" \
  --arg pr_url "$PR_URL" \
  --arg dispatched_at "$DISPATCHED_AT" \
  --arg pr_opened_at "$PR_OPENED_AT" \
  --arg merged_at "$MERGED_AT" \
  --argjson no_mistakes "$NM_JSON" \
  'def nullable: if . == "" then null else . end;
   {
     task_id: $task_id,
     repo: $repo,
     pr_url: ($pr_url | nullable),
     dispatched_at: ($dispatched_at | nullable),
     pr_opened_at: ($pr_opened_at | nullable),
     merged_at: ($merged_at | nullable)
   } + $no_mistakes')

mkdir -p "$DATA"
LEDGER="$DATA/delivery-log.jsonl"
LOCK="$DATA/.delivery-log.lock"
LOCK_ATTEMPTS=0
while ! fm_lock_try_acquire "$LOCK"; do
  LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
  if [ "$LOCK_ATTEMPTS" -ge 50 ]; then
    echo "error: could not lock the delivery ledger" >&2
    exit 1
  fi
  sleep 0.02
done
trap 'fm_lock_release "$LOCK"' EXIT

if [ -L "$LEDGER" ]; then
  echo "error: delivery ledger must not be a symlink" >&2
  exit 1
fi
if [ -f "$LEDGER" ] && jq -Rse --arg task_id "$ID" '
  split("\n")
  | map(fromjson? | select(.task_id == $task_id))
  | length > 0
' "$LEDGER" >/dev/null; then
  exit 0
fi
printf '%s\n' "$RECORD" >> "$LEDGER"
