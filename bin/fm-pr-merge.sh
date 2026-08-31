#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
# After a successful merge, available task and no-mistakes timing is appended to
# the home-local data/delivery-log.jsonl without changing the merge result.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# They also must not include --auto because this command records delivery timing
# only after GitHub confirms the pull request has merged.
#
# A project whose data/projects.md bracket list contains the exact
# captain-merge token requires --captain-approved <pr-url>. The approval URL
# must exactly equal the canonical PR URL produced by bin/fm-pr-lib.sh. This
# per-PR flag bypasses only the captain-merge refusal and is logged to stderr.
# The caller must pass it before the optional -- separator. No environment or
# configuration value supplies approval.
#
# Before merging, the PR's review threads must all be resolved. GitHub's
# mergeable state covers checks but not review conversations, so a green PR can
# still carry open CodeRabbit, Copilot, or human feedback. This script asks
# GitHub's GraphQL API for reviewThreads.isResolved and refuses to merge while
# any thread is unresolved. It fails closed: if the thread query errors or
# returns anything it cannot read as a plain thread count, it refuses rather
# than merging blind. A PR with more than 100 review threads is refused with an
# explanation rather than paginated, because that count is far past any real PR.
# --allow-unresolved-threads bypasses only this gate and is logged so it is
# never silent; the caller must pass it before the optional -- separator.
# Usage:
#   fm-pr-merge.sh <task-id> <pr-url> [--captain-approved <pr-url>] \
#     [--allow-unresolved-threads] \
#     [-- <extra gh-axi pr merge args>]
set -eu

# GitHub GraphQL caps a reviewThreads page at 100 nodes. The gate reads the
# first page plus totalCount; a PR past this bound is refused, not paginated.
FM_PR_THREADS_PAGE_SIZE=100

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  printf '%s\n' \
    'Usage: fm-pr-merge.sh <task-id> <pr-url> [--captain-approved <pr-url>] [--allow-unresolved-threads] [-- <extra gh-axi pr merge args>]' \
    '' \
    '  --captain-approved <pr-url>  Bypass the captain-merge refusal only when this' \
    '                               value exactly matches the canonical PR URL.' \
    '  --allow-unresolved-threads   Bypass only the review-thread refusal.' \
    '' \
    'Extra merge arguments must not include --repo, -R, or --auto.'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

# Approval flags are read before the optional -- separator so they are never
# confused with gh-axi flags.
allow_unresolved_threads=0
captain_approved_url=
captain_approved_seen=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-unresolved-threads)
      allow_unresolved_threads=1
      shift
      ;;
    --captain-approved)
      if [ "$captain_approved_seen" -eq 1 ]; then
        echo "error: --captain-approved may be supplied only once" >&2
        exit 2
      fi
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "error: --captain-approved requires the canonical PR URL" >&2
        exit 2
      fi
      captain_approved_seen=1
      captain_approved_url=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_uses_auto_merge() {
  local arg
  for arg in "$@"; do
    [ "$arg" = --auto ] && return 0
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Print a single unresolved-thread count for the PR, or fail. The owner, repo,
# and number are inlined into the GraphQL query rather than passed as variables:
# gh-axi does not forward --field as GraphQL variables, and all three come from
# the strict URL parser (GitHub username and repository charsets, digits only),
# so no untrusted text reaches the query. jq emits one bare scalar so gh-axi
# prints it raw; a spaced or quoted jq result would be wrapped in gh-axi's YAML
# envelope, which the integer check below would then reject.
unresolved_thread_query() {
  local owner=$1 repo=$2 number=$3 jq_expr=$4
  gh-axi api POST /graphql --field query="{ repository(owner:\"$owner\",name:\"$repo\"){ pullRequest(number:$number){ reviewThreads(first:$FM_PR_THREADS_PAGE_SIZE){ totalCount nodes{ isResolved } } } } }" --jq "$jq_expr"
}

# Refuse to merge unless every review thread on the PR is resolved. Fails closed:
# a query error, a null PR, or any non-integer output refuses rather than merges.
require_resolved_threads() {
  local owner=$1 repo=$2 number=$3 total unresolved
  total=$(unresolved_thread_query "$owner" "$repo" "$number" \
    '.data.repository.pullRequest.reviewThreads.totalCount') || {
    echo "error: could not read the PR's review threads; refusing to merge" >&2
    return 1
  }
  case "$total" in
    ''|*[!0-9]*)
      echo "error: could not read the PR's review threads; refusing to merge" >&2
      return 1
      ;;
  esac
  if [ "$total" -gt "$FM_PR_THREADS_PAGE_SIZE" ]; then
    echo "error: PR has $total review threads, more than the $FM_PR_THREADS_PAGE_SIZE this check reads; refusing to merge" >&2
    return 1
  fi
  unresolved=$(unresolved_thread_query "$owner" "$repo" "$number" \
    '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length') || {
    echo "error: could not read the PR's review threads; refusing to merge" >&2
    return 1
  }
  case "$unresolved" in
    ''|*[!0-9]*)
      echo "error: could not read the PR's review threads; refusing to merge" >&2
      return 1
      ;;
  esac
  if [ "$unresolved" -gt 0 ]; then
    echo "error: PR has $unresolved unresolved review thread(s); resolve them or pass --allow-unresolved-threads" >&2
    return 1
  fi
}

reject_repo_overrides "$@" || exit 1
if caller_uses_auto_merge "$@"; then
  echo "error: --auto is unsupported because delivery timing requires a completed merge" >&2
  exit 2
fi

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

if ! PROJECT_RECORD=$(grep '^project=' "$META"); then
  echo "error: task metadata has a missing, empty, or ambiguous project identity" >&2
  exit 1
fi
case "$PROJECT_RECORD" in
  project=|*$'\n'*)
    echo "error: task metadata has a missing, empty, or ambiguous project identity" >&2
    exit 1
    ;;
esac
PROJECT_PATH=${PROJECT_RECORD#project=}
if ! PROJECT=$(basename -- "$PROJECT_PATH") || [ -z "$PROJECT" ]; then
  echo "error: task metadata has a missing, empty, or ambiguous project identity" >&2
  exit 1
fi
captain_merge_line=
if captain_merge_line=$("$SCRIPT_DIR/fm-project-mode.sh" --captain-merge "$PROJECT"); then
  :
else
  captain_merge_status=$?
  captain_merge_line=
  if [ "$captain_merge_status" -ne 1 ]; then
    echo "error: could not read captain-merge policy for project \"$PROJECT\"" >&2
    exit 1
  fi
fi
if [ -n "$captain_merge_line" ]; then
  if [ "$captain_approved_url" = "$URL" ]; then
    echo "note: --captain-approved matched $URL; bypassing the captain-merge refusal for project \"$PROJECT\"" >&2
  else
    echo "error: captain approval required; refusing to merge captain-merge project \"$PROJECT\"" >&2
    echo "error: registry: $captain_merge_line" >&2
    echo "error: PR: $URL" >&2
    echo "error: pass --captain-approved $URL only after a current explicit captain instruction naming this PR" >&2
    exit 1
  fi
elif [ -n "$captain_approved_url" ] && [ "$captain_approved_url" != "$URL" ]; then
  echo "error: --captain-approved URL must exactly match $URL" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$allow_unresolved_threads" -eq 1 ]; then
  echo "note: --allow-unresolved-threads set; skipping the review-thread gate for $URL"
else
  require_resolved_threads "$PR_OWNER" "$PR_REPO" "$PR_NUMBER" || exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# The merge command accepted the request. Delivery timing is record-only, so an
# API or ledger failure never changes that result.
PR_FACTS=
PR_MERGED=
PR_OPENED_AT=
MERGED_AT=
MERGED_VALUE=
PR_LOOKUP_OK=1
if ! PR_FACTS=$(gh-axi api GET "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
  --jq '{merged:.merged,pr_opened_at:.created_at,merged_at:.merged_at}'); then
  echo "warning: could not read pull request timestamps for $URL" >&2
  PR_LOOKUP_OK=0
else
  PR_MERGED=$(printf '%s\n' "$PR_FACTS" | sed -n 's/^merged: //p')
  PR_OPENED_AT=$(printf '%s\n' "$PR_FACTS" \
    | sed -n 's/^pr_opened_at: "\([^"]*\)"$/\1/p')
  MERGED_VALUE=$(printf '%s\n' "$PR_FACTS" | sed -n 's/^merged_at: //p')
  case "$PR_MERGED" in
    true|false) ;;
    *) PR_LOOKUP_OK=0 ;;
  esac
  case "$PR_OPENED_AT" in
    ????-??-??T??:??:??Z) ;;
    *) PR_OPENED_AT=; PR_LOOKUP_OK=0 ;;
  esac
  case "$MERGED_VALUE" in
    null) MERGED_AT= ;;
    '"'????-??-??T??:??:??Z'"') MERGED_AT=${MERGED_VALUE#\"}; MERGED_AT=${MERGED_AT%\"} ;;
    *) MERGED_AT=; PR_LOOKUP_OK=0 ;;
  esac
  [ "$PR_MERGED" != true ] || [ -n "$MERGED_AT" ] || PR_LOOKUP_OK=0
  if [ "$PR_LOOKUP_OK" -eq 0 ]; then
    echo "warning: could not parse pull request timestamps for $URL" >&2
  fi
fi

if [ "$PR_MERGED" = false ]; then
  echo "error: $URL is not merged after the merge command completed" >&2
  exit 1
fi

delivery_args=(
  "$ID"
  --repo "$PROJECT"
  --project-path "$PROJECT_PATH"
  --pr-url "$URL"
)
[ -z "$PR_OPENED_AT" ] || delivery_args+=(--pr-opened-at "$PR_OPENED_AT")
[ -z "$MERGED_AT" ] || delivery_args+=(--merged-at "$MERGED_AT")
if ! "$SCRIPT_DIR/fm-delivery-record.sh" "${delivery_args[@]}"; then
  echo "warning: delivery timing was not recorded for $ID after merging $URL" >&2
fi
