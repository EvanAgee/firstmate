#!/usr/bin/env bash
# Re-request one stale GitHub reviewer during the watcher's authenticated PR check.
# State contains, in order, the format version, head, first-observed time, completed
# request count, last completed request time, escalation flag, and an in-flight
# reviewer or "-". Limits belong to the head, not the reviewer. An in-flight
# reviewer is restored before any new action after an interrupted DELETE-then-POST.
# Usage: fm-pr-review-chase.sh --validated <state> <task-id> <provider> <url> <host> <path> <number>
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

RETRY_SECONDS=21600
ESCALATE_SECONDS=86400
MAX_REQUESTS=3

[ "$#" -eq 8 ] && [ "$1" = --validated ] || exit 0
state=$2
id=$3
provider=$4
url=$5
host=$6
path=$7
number=$8

fm_pr_task_id_valid "$id" || exit 0
fm_pr_url_parse "$url" || exit 0
[ "$provider" = "$FM_PR_PROVIDER" ] || exit 0
[ "$host" = "$FM_PR_HOST" ] || exit 0
[ "$path" = "$FM_PR_PATH" ] || exit 0
[ "$number" = "$FM_PR_NUMBER" ] || exit 0
[ "$provider" = github ] || exit 0
[ -d "$state" ] && [ ! -L "$state" ] || exit 0
command -v gh-axi >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

state_device=$(fm_pr_file_device "$state") || exit 0
[ -n "$state_device" ] || exit 0
chase_state="$state/$id.pr-review-chase"
state_tmp=

# shellcheck disable=SC2329
cleanup() {
  [ -z "$state_tmp" ] || rm -f -- "$state_tmp"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

reviewer_valid() {
  local reviewer=${1-}
  [ "${#reviewer}" -ge 1 ] && [ "${#reviewer}" -le 39 ] || return 1
  case "$reviewer" in
    *[!A-Za-z0-9-]*|-*|*-) return 1 ;;
  esac
}

chase_state_valid() {
  local file=$1 version saved_head reviewer_observed count last_request escalated in_flight _extra
  fm_pr_private_file_valid "$file" 600 "$state_device" || return 1
  exec 8< "$file" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r saved_head <&8 || { exec 8<&-; return 1; }
  IFS= read -r reviewer_observed <&8 || { exec 8<&-; return 1; }
  IFS= read -r count <&8 || { exec 8<&-; return 1; }
  IFS= read -r last_request <&8 || { exec 8<&-; return 1; }
  IFS= read -r escalated <&8 || { exec 8<&-; return 1; }
  IFS= read -r in_flight <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-review-chase-v2 ] && fm_pr_head_valid "$saved_head" \
    && [[ "$reviewer_observed" =~ ^[0-9]+$ ]] && [ "$reviewer_observed" -gt 0 ] \
    && [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -le "$MAX_REQUESTS" ] \
    && [[ "$last_request" =~ ^[0-9]+$ ]] \
    && { [ "$escalated" = 0 ] || [ "$escalated" = 1 ]; } \
    && { [ "$in_flight" = - ] || reviewer_valid "$in_flight"; }
}

load_chase_state() {
  exec 8< "$chase_state" || return 1
  IFS= read -r _version <&8 || { exec 8<&-; return 1; }
  IFS= read -r saved_head <&8 || { exec 8<&-; return 1; }
  IFS= read -r observed_at <&8 || { exec 8<&-; return 1; }
  IFS= read -r request_count <&8 || { exec 8<&-; return 1; }
  IFS= read -r last_request_at <&8 || { exec 8<&-; return 1; }
  IFS= read -r escalated <&8 || { exec 8<&-; return 1; }
  IFS= read -r in_flight_reviewer <&8 || { exec 8<&-; return 1; }
  exec 8<&-
}

write_chase_state() {
  local head=$1 observed=$2 count=$3 last_request=$4 did_escalate=$5 in_flight=$6
  state_tmp=$(mktemp "$state/.fm-pr-review-chase.XXXXXX") || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    fm-pr-review-chase-v2 "$head" "$observed" "$count" "$last_request" \
    "$did_escalate" "$in_flight" > "$state_tmp" || return 1
  chmod 0600 "$state_tmp" || return 1
  chase_state_valid "$state_tmp" || return 1
  fm_pr_regular_destination_on_device_or_absent "$chase_state" "$state_device" || return 1
  mv -f -- "$state_tmp" "$chase_state" || return 1
  state_tmp=
}

decode_graphql_body() {
  local response=$1 encoded
  [ "$(printf '%s\n' "$response" | grep -c '^  body: ')" = 1 ] || return 1
  [ "$(printf '%s\n' "$response" | sed -n 's/^  truncated: //p')" = false ] || return 1
  encoded=$(printf '%s\n' "$response" | sed -n 's/^  body: //p')
  GRAPHQL_BODY=$(printf '%s\n' "$encoded" | jq -Rer '@base64d | fromjson' 2>/dev/null) || return 1
}

owner=${path%%/*}
repo=${path#*/}

fetch_pr() {
  local query response
  query="query { repository(owner:\"$owner\", name:\"$repo\") { pullRequest(number:$number) { state url headRefOid isDraft mergeable mergeStateStatus reviewDecision commits(last:1) { nodes { commit { oid statusCheckRollup { state } } } } reviewThreads(first:100) { totalCount nodes { isResolved } } reviewRequests(first:100) { totalCount nodes { requestedReviewer { __typename ... on User { login } } } } } } }"
  response=$(gh-axi api POST /graphql --field query="$query" \
    --jq '.data.repository.pullRequest | tojson | @base64' 2>/dev/null) || return 1
  decode_graphql_body "$response" || return 1
  PR_JSON=$GRAPHQL_BODY
  printf '%s\n' "$PR_JSON" | jq -e 'type == "object"' >/dev/null 2>&1
}

tracked_head() {
  printf '%s\n' "$PR_JSON" | jq -er '
    select(.state == "OPEN")
    | select(.url == $url)
    | select((.headRefOid | type) == "string")
    | select((.commits.nodes | length) == 1)
    | select(.commits.nodes[0].commit.oid == .headRefOid)
    | .headRefOid
  ' --arg url "$url" 2>/dev/null
}

candidate_reviewer() {
  printf '%s\n' "$PR_JSON" | jq -er '
    select(.state == "OPEN")
    | select(.url == $url)
    | select(.headRefOid == $head)
    | select(.isDraft == false)
    | select(.mergeable == "MERGEABLE")
    | select(.mergeStateStatus == "BLOCKED")
    | select(.reviewDecision == "REVIEW_REQUIRED" or .reviewDecision == "CHANGES_REQUESTED")
    | select((.commits.nodes | length) == 1)
    | select(.commits.nodes[0].commit.oid == $head)
    | select(.commits.nodes[0].commit.statusCheckRollup.state == "SUCCESS")
    | select(.reviewThreads.totalCount <= 100)
    | select(.reviewThreads.totalCount == (.reviewThreads.nodes | length))
    | select(all(.reviewThreads.nodes[]; .isResolved == true))
    | select(.reviewRequests.totalCount == 1)
    | select((.reviewRequests.nodes | length) == 1)
    | .reviewRequests.nodes[0].requestedReviewer
    | select(.__typename == "User")
    | .login
  ' --arg url "$url" --arg head "$1" 2>/dev/null
}

review_requests_valid() {
  printf '%s\n' "$PR_JSON" | jq -e '
    (.reviewRequests.totalCount | type) == "number"
    and .reviewRequests.totalCount <= 100
    and (.reviewRequests.nodes | type) == "array"
    and .reviewRequests.totalCount == (.reviewRequests.nodes | length)
  ' >/dev/null 2>&1
}

reviewer_is_requested() {
  printf '%s\n' "$PR_JSON" | jq -e '
    any(.reviewRequests.nodes[];
      .requestedReviewer.__typename == "User"
      and .requestedReviewer.login == $reviewer)
  ' --arg reviewer "$1" >/dev/null 2>&1
}

fetch_latest_review() {
  local reviewer=$1 reviewer_json cursor='' after='' query response page reviews next_cursor seen=''
  reviewer_valid "$reviewer" || return 1
  reviewer_json=$(jq -Rn --arg reviewer "$reviewer" '$reviewer | @json') || return 1
  reviews='[]'
  while :; do
    if [ -n "$cursor" ]; then
      after=", after:\"$cursor\""
    else
      after=
    fi
    query="query { repository(owner:\"$owner\", name:\"$repo\") { pullRequest(number:$number) { reviews(first:100, author:$reviewer_json$after) { nodes { author { login } submittedAt commit { oid } } pageInfo { hasNextPage endCursor } } } } }"
    response=$(gh-axi api POST /graphql --field query="$query" \
      --jq '.data.repository.pullRequest.reviews | tojson | @base64' 2>/dev/null) || return 1
    decode_graphql_body "$response" || return 1
    page=$GRAPHQL_BODY
    printf '%s\n' "$page" | jq -e '
      type == "object"
      and (.nodes | type) == "array"
      and (.pageInfo.hasNextPage | type) == "boolean"
    ' >/dev/null 2>&1 || return 1
    reviews=$(jq -cn --argjson previous "$reviews" --argjson page "$page" \
      '$previous + $page.nodes') || return 1
    [ "$(printf '%s\n' "$page" | jq -r '.pageInfo.hasNextPage')" = true ] || break
    next_cursor=$(printf '%s\n' "$page" | jq -er '.pageInfo.endCursor | select(type == "string")') || return 1
    [ "${#next_cursor}" -ge 1 ] && [ "${#next_cursor}" -le 512 ] || return 1
    case "$next_cursor" in
      *[!A-Za-z0-9+/=:_-]*) return 1 ;;
    esac
    case " $seen " in
      *" $next_cursor "*) return 1 ;;
    esac
    seen="$seen $next_cursor"
    cursor=$next_cursor
  done
  LATEST_REVIEW=$(printf '%s\n' "$reviews" | jq -cer '
    map(select(.author.login == $reviewer)
      | select((.submittedAt | type) == "string")
      | select((.commit.oid | type) == "string"))
    | sort_by(.submittedAt)
    | last
    | select(. != null)
  ' --arg reviewer "$reviewer" 2>/dev/null) || return 1
}

review_is_for_older_head() {
  printf '%s\n' "$LATEST_REVIEW" | jq -e --arg head "$1" '.commit.oid != $head' >/dev/null 2>&1
}

now=${FM_PR_REVIEW_CHASE_NOW:-$(date +%s)}
[[ "$now" =~ ^[0-9]+$ ]] && [ "$now" -gt 0 ] || exit 0

saved_head=
observed_at=0
request_count=0
last_request_at=0
escalated=0
in_flight_reviewer=-
if [ -e "$chase_state" ] || [ -L "$chase_state" ]; then
  chase_state_valid "$chase_state" || exit 0
  load_chase_state || exit 0
fi

fetch_pr || exit 0
head=$(tracked_head) || exit 0
fm_pr_head_valid "$head" || exit 0

if [ "$in_flight_reviewer" != - ]; then
  review_requests_valid || exit 0
  if ! reviewer_is_requested "$in_flight_reviewer"; then
    if ! gh-axi api POST "repos/$path/pulls/$number/requested_reviewers" \
      --field "reviewers[]=$in_flight_reviewer" >/dev/null 2>&1; then
      printf 'reviewer chase failed for %s on %s while restoring the request\n' \
        "$in_flight_reviewer" "$url"
      exit 0
    fi
  fi
  [ "$request_count" -lt "$MAX_REQUESTS" ] || exit 0
  request_count=$((request_count + 1))
  last_request_at=$now
  in_flight_reviewer=-
  write_chase_state "$saved_head" "$observed_at" "$request_count" \
    "$last_request_at" "$escalated" "$in_flight_reviewer" || exit 0
fi

if [ "$saved_head" != "$head" ]; then
  saved_head=$head
  observed_at=$now
  request_count=0
  last_request_at=0
  escalated=0
  in_flight_reviewer=-
  write_chase_state "$saved_head" "$observed_at" "$request_count" \
    "$last_request_at" "$escalated" "$in_flight_reviewer" || exit 0
fi

quiet_seconds=$((now - observed_at))
[ "$quiet_seconds" -ge 0 ] || exit 0
reviewer=$(candidate_reviewer "$head") || exit 0
reviewer_valid "$reviewer" || exit 0
fetch_latest_review "$reviewer" || exit 0
review_is_for_older_head "$head" || exit 0

if [ "$quiet_seconds" -ge "$ESCALATE_SECONDS" ]; then
  [ "$escalated" -eq 0 ] || exit 0
  quiet_hours=$(awk -v seconds="$quiet_seconds" 'BEGIN {printf "%.1f", seconds / 3600}')
  printf 'reviewer wait: %s has waited %s hours for requested reviewer %s\n' \
    "$url" "$quiet_hours" "$reviewer" || exit 0
  escalated=1
  write_chase_state "$saved_head" "$observed_at" "$request_count" \
    "$last_request_at" "$escalated" "$in_flight_reviewer" || exit 0
  exit 0
fi

[ "$quiet_seconds" -ge "$RETRY_SECONDS" ] || exit 0
[ "$request_count" -lt "$MAX_REQUESTS" ] || exit 0
if [ "$last_request_at" -ne 0 ] && [ $((now - last_request_at)) -lt "$RETRY_SECONDS" ]; then
  exit 0
fi

fetch_pr || exit 0
revalidated_head=$(tracked_head) || exit 0
[ "$revalidated_head" = "$head" ] || exit 0
revalidated_reviewer=$(candidate_reviewer "$head") || exit 0
[ "$revalidated_reviewer" = "$reviewer" ] || exit 0
fetch_latest_review "$reviewer" || exit 0
review_is_for_older_head "$head" || exit 0

in_flight_reviewer=$reviewer
write_chase_state "$saved_head" "$observed_at" "$request_count" \
  "$last_request_at" "$escalated" "$in_flight_reviewer" || exit 0

if ! gh-axi api DELETE "repos/$path/pulls/$number/requested_reviewers" \
  --field "reviewers[]=$reviewer" >/dev/null 2>&1; then
  printf 'reviewer chase failed for %s on %s while removing the stale request\n' \
    "$reviewer" "$url"
  exit 0
fi
if ! gh-axi api POST "repos/$path/pulls/$number/requested_reviewers" \
  --field "reviewers[]=$reviewer" >/dev/null 2>&1; then
  printf 'reviewer chase failed for %s on %s while restoring the request\n' \
    "$reviewer" "$url"
  exit 0
fi

request_count=$((request_count + 1))
last_request_at=$now
in_flight_reviewer=-
write_chase_state "$saved_head" "$observed_at" "$request_count" \
  "$last_request_at" "$escalated" "$in_flight_reviewer" || exit 0
exit 0
