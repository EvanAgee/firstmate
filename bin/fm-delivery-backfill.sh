#!/usr/bin/env bash
# Backfill recent merged-task timing into data/delivery-log.jsonl.
#
# GitHub supplies the pull request timestamps and head branch. The matching
# no-mistakes runs supply pipeline, review, fix, test, document, and parked
# timing through bin/fm-delivery-record.sh. A pull request still gets a partial
# record when no matching run exists. Existing task ids are skipped.
#
# This one-shot command scans aos, faapto, and firstmate. It is safe to rerun.
# Usage: fm-delivery-backfill.sh [--limit <merged-PRs-per-repo>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LIMIT=30

usage() {
  printf '%s\n' 'Usage: fm-delivery-backfill.sh [--limit <merged-PRs-per-repo>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit)
      LIMIT=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown delivery backfill argument '$1'" >&2
      exit 2
      ;;
  esac
done
case "$LIMIT" in
  ''|*[!0-9]*)
    echo "error: --limit must be an integer from 1 to 100" >&2
    exit 2
    ;;
esac
if [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 100 ]; then
  echo "error: --limit must be an integer from 1 to 100" >&2
  exit 2
fi

ledger_has_task() {
  local ledger=$1 task_id=$2
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 1
  jq -Rse --arg task_id "$task_id" '
    split("\n")
    | map(fromjson? | select(.task_id == $task_id))
    | length > 0
  ' "$ledger" >/dev/null
}

decode_gh_rows() {
  local response=$1 count payload
  count=${response%%]:*}
  count=${count#[}
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  payload=${response#*]:}
  payload=${payload# }
  if [ "$count" -eq 0 ]; then
    [ -z "$payload" ] || return 1
    return 0
  fi
  [ -n "$payload" ] || return 1
  printf '[%s]' "$payload" | jq -r '.[]'
}

LEDGER="$DATA/delivery-log.jsonl"
FAILED=0
while IFS='|' read -r REPO SLUG PROJECT_PATH; do
  [ -n "$REPO" ] || continue
  if ! RESPONSE=$(gh-axi api GET \
    "/repos/$SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=$LIMIT" \
    --jq '[.[] | select(.merged_at != null) | [.number,.head.ref,.created_at,.merged_at,.html_url] | @tsv]'); then
    echo "warning: could not read recent merged pull requests for $SLUG" >&2
    FAILED=1
    continue
  fi
  RESPONSE=$(printf '%s\n' "$RESPONSE" | head -n 1)
  if ! ROWS=$(decode_gh_rows "$RESPONSE"); then
    echo "warning: could not parse recent merged pull requests for $SLUG" >&2
    FAILED=1
    continue
  fi

  while IFS=$(printf '\t') read -r PR_NUMBER BRANCH PR_OPENED_AT MERGED_AT PR_URL; do
    [ -n "$PR_NUMBER" ] || continue
    case "$BRANCH" in
      fm/*) TASK_ID=${BRANCH#fm/} ;;
      *)
        echo "warning: skipping $PR_URL because its task id cannot be recovered from branch $BRANCH" >&2
        continue
        ;;
    esac
    case "$TASK_ID" in
      ''|*[!A-Za-z0-9._-]*|.*|-*)
        echo "warning: skipping $PR_URL because branch $BRANCH has an invalid task id" >&2
        continue
        ;;
    esac
    if ledger_has_task "$LEDGER" "$TASK_ID"; then
      continue
    fi
    if ! "$SCRIPT_DIR/fm-delivery-record.sh" "$TASK_ID" \
      --repo "$REPO" \
      --project-path "$PROJECT_PATH" \
      --branch "$BRANCH" \
      --pr-url "$PR_URL" \
      --pr-opened-at "$PR_OPENED_AT" \
      --merged-at "$MERGED_AT"; then
      echo "warning: delivery timing was not backfilled for $TASK_ID ($PR_URL)" >&2
      FAILED=1
    fi
  done <<< "$ROWS"
done <<EOF
aos|SuperDuperIT/aos|$FM_HOME/projects/aos
faapto|EvanAgee/faapto|$FM_HOME/projects/faapto
firstmate|EvanAgee/firstmate|$FM_HOME
EOF

exit "$FAILED"
