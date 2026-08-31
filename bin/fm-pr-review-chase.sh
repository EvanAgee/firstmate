#!/usr/bin/env bash
# Re-request stale GitHub reviewers during the watcher's existing PR check.
# The caller supplies a canonical poll snapshot. This script revalidates that
# identity, requires green checks and resolved review threads, then keeps a
# private per-head request count beside the poll artifacts. One head gets at
# most three re-requests, six hours apart. A 24-hour wait emits one blocker and
# ends the chase without approving, dismissing, or merging anything.
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

reviewer_valid() {
  local reviewer=${1-}
  [ "${#reviewer}" -ge 1 ] && [ "${#reviewer}" -le 39 ] || return 1
  case "$reviewer" in
    *[!A-Za-z0-9-]*|-*|*-) return 1 ;;
  esac
}

chase_state_valid() {
  local file=$1 version saved_head reviewer count last_request escalated extra
  fm_pr_private_file_valid "$file" 600 "$state_device" || return 1
  exec 8< "$file" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r saved_head <&8 || { exec 8<&-; return 1; }
  [ "$version" = fm-pr-review-chase-v1 ] && fm_pr_head_valid "$saved_head" \
    || { exec 8<&-; return 1; }
  while IFS=$(printf '\t') read -r reviewer count last_request escalated extra <&8; do
    reviewer_valid "$reviewer" \
      && [[ "$count" =~ ^[0-9]+$ ]] \
      && [[ "$last_request" =~ ^[0-9]+$ ]] \
      && { [ "$escalated" = 0 ] || [ "$escalated" = 1 ]; } \
      && [ -z "$extra" ] \
      || { exec 8<&-; return 1; }
  done
  exec 8<&-
  [ "$(cut -f1 "$file" | tail -n +3 | sort | uniq -d | wc -l | tr -d ' ')" = 0 ]
}

if [ -e "$chase_state" ] || [ -L "$chase_state" ]; then
  chase_state_valid "$chase_state" || exit 0
fi

owner=${path%%/*}
repo=${path#*/}
query="query { repository(owner:\"$owner\", name:\"$repo\") { pullRequest(number:$number) { state url headRefOid commits(last:1) { nodes { commit { oid committedDate statusCheckRollup { state } } } } reviewThreads(first:100) { totalCount nodes { isResolved } } reviewRequests(first:100) { totalCount nodes { requestedReviewer { __typename ... on User { login } } } } reviews(last:100) { nodes { author { login } submittedAt commit { oid } } } } } }"
api_response=$(gh-axi api POST /graphql --field query="$query" \
  --jq '.data.repository.pullRequest | tojson | @base64' 2>/dev/null) || exit 0
[ "$(printf '%s\n' "$api_response" | grep -c '^  body: ')" = 1 ] || exit 0
[ "$(printf '%s\n' "$api_response" | sed -n 's/^  truncated: //p')" = false ] || exit 0
encoded_pr=$(printf '%s\n' "$api_response" | sed -n 's/^  body: //p')
pr=$(printf '%s\n' "$encoded_pr" | jq -Rr '@base64d' 2>/dev/null) || exit 0
candidates=$(printf '%s\n' "$pr" | jq -r '
  . as $pr
  | select($pr.state == "OPEN")
  | select($pr.url == $url)
  | select(($pr.headRefOid | type) == "string")
  | select(($pr.commits.nodes | length) == 1)
  | $pr.commits.nodes[0].commit as $commit
  | select($commit.oid == $pr.headRefOid)
  | select($commit.statusCheckRollup.state == "SUCCESS")
  | select($pr.reviewThreads.totalCount <= 100)
  | select($pr.reviewThreads.totalCount == ($pr.reviewThreads.nodes | length))
  | select(all($pr.reviewThreads.nodes[]; .isResolved == true))
  | select($pr.reviewRequests.totalCount <= 100)
  | select($pr.reviewRequests.totalCount == ($pr.reviewRequests.nodes | length))
  | ($commit.committedDate | fromdateiso8601) as $head_time
  | $pr.reviewRequests.nodes[].requestedReviewer
  | select(.__typename == "User")
  | .login as $login
  | ($pr.reviews.nodes
      | map(select(.author.login == $login and (.commit.oid | type) == "string"))
      | sort_by(.submittedAt)
      | last) as $review
  | select($review != null and $review.commit.oid != $pr.headRefOid)
  | [$login, $pr.headRefOid, ($head_time | tostring)]
  | @tsv
' --arg url "$url" 2>/dev/null | sort -u) || exit 0
[ -n "$candidates" ] || exit 0

now=${FM_PR_REVIEW_CHASE_NOW:-$(date +%s)}
[[ "$now" =~ ^[0-9]+$ ]] || exit 0
head=$(printf '%s\n' "$candidates" | cut -f2 | head -1)
fm_pr_head_valid "$head" || exit 0
[ "$(printf '%s\n' "$candidates" | cut -f2 | sort -u | wc -l | tr -d ' ')" = 1 ] || exit 0

saved_head=
if [ -f "$chase_state" ]; then
  IFS= read -r _version < "$chase_state" || exit 0
  saved_head=$(sed -n '2p' "$chase_state") || exit 0
fi

state_tmp=$(mktemp "$state/.fm-pr-review-chase.XXXXXX") || exit 0
actions_tmp=$(mktemp "$state/.fm-pr-review-actions.XXXXXX") || { rm -f -- "$state_tmp"; exit 0; }
cleanup() {
  rm -f -- "$state_tmp" "$actions_tmp"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
printf '%s\n%s\n' fm-pr-review-chase-v1 "$head" > "$state_tmp" || exit 0

while IFS=$(printf '\t') read -r reviewer candidate_head head_time; do
  reviewer_valid "$reviewer" || exit 0
  [ "$candidate_head" = "$head" ] || exit 0
  [[ "$head_time" =~ ^[0-9]+$ ]] || exit 0
  count=0
  last_request=0
  escalated=0
  if [ "$saved_head" = "$head" ]; then
    old=$(awk -F '\t' -v reviewer="$reviewer" '$1 == reviewer {print $2 "\t" $3 "\t" $4; exit}' "$chase_state")
    if [ -n "$old" ]; then
      IFS=$(printf '\t') read -r count last_request escalated <<< "$old"
    fi
  fi
  quiet_seconds=$((now - head_time))
  if [ "$quiet_seconds" -ge "$ESCALATE_SECONDS" ]; then
    if [ "$escalated" -eq 0 ]; then
      escalated=1
      printf 'escalate\t%s\t%s\n' "$reviewer" "$quiet_seconds" >> "$actions_tmp" || exit 0
    fi
  elif [ "$quiet_seconds" -ge "$RETRY_SECONDS" ] \
    && [ "$count" -lt "$MAX_REQUESTS" ] \
    && { [ "$last_request" -eq 0 ] || [ $((now - last_request)) -ge "$RETRY_SECONDS" ]; }; then
    count=$((count + 1))
    last_request=$now
    printf 'request\t%s\t0\n' "$reviewer" >> "$actions_tmp" || exit 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$reviewer" "$count" "$last_request" "$escalated" >> "$state_tmp" || exit 0
done <<< "$candidates"

chmod 0600 "$state_tmp" || exit 0
chase_state_valid "$state_tmp" || exit 0
fm_pr_regular_destination_on_device_or_absent "$chase_state" "$state_device" || exit 0
mv -f -- "$state_tmp" "$chase_state" || exit 0
state_tmp=

messages=
add_message() {
  if [ -n "$messages" ]; then
    messages="$messages; $1"
  else
    messages=$1
  fi
}

while IFS=$(printf '\t') read -r action reviewer quiet_seconds; do
  [ -n "$action" ] || continue
  case "$action" in
    request)
      if ! gh-axi api DELETE "repos/$path/pulls/$number/requested_reviewers" \
        --field "reviewers[]=$reviewer" >/dev/null 2>&1; then
        add_message "reviewer chase failed for $reviewer on $url while removing the stale request"
        continue
      fi
      if ! gh-axi api POST "repos/$path/pulls/$number/requested_reviewers" \
        --field "reviewers[]=$reviewer" >/dev/null 2>&1; then
        add_message "reviewer chase failed for $reviewer on $url while restoring the request"
      fi
      ;;
    escalate)
      quiet_hours=$(awk -v seconds="$quiet_seconds" 'BEGIN {printf "%.1f", seconds / 3600}')
      add_message "reviewer wait: $url has waited $quiet_hours hours for requested reviewer $reviewer"
      ;;
    *) exit 0 ;;
  esac
done < "$actions_tmp"

[ -z "$messages" ] || printf '%s\n' "$messages"
exit 0
