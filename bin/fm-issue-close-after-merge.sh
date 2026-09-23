#!/usr/bin/env bash
# Close a shipped task's linked GitHub issues once its work has landed on the
# default branch, so an issue stops depending on a worker remembering a
# "Closes #n" line. Some lanes deliberately write "Refs #n" instead, and GitHub
# then leaves the issue open after the merge; firstmate closes it here instead.
#
# Two forms, one per way work lands:
#   <task-id> <merged-pr-url>    after a PR merge (bin/fm-pr-merge.sh and the
#                                merge watch in bin/fm-watch.sh)
#   <task-id> --landed <sha>     after a local landing was pushed
#                                (bin/fm-merge-local.sh --push); <sha> is the
#                                full lowercase commit the default branch landed on
#
# The issues come only from the task's own state/<id>.meta issues= field, which
# bin/fm-spawn.sh records as comma-separated lowercase owner/repo#<number>
# refs. The entire list is validated before any forge call.
# Positive zero-padded numbers are accepted and lose
# their leading zeros in forge calls and receipts.
# A task with no issues= field is a silent no-op, because most tasks ship
# without a linked issue.
#
# An optional issues_keep_open= field in the same meta, in the same ref format,
# names linked issues whose acceptance still has captain-only items. Firstmate
# appends that line by hand when it learns an issue must outlive the landing;
# no script writes it. A kept issue is never read or touched on either form.
#
# For each linked issue:
#   kept open      -> print "kept-open: <owner/repo>#<n>" and touch nothing
#   already closed -> print "already-closed: <owner/repo>#<n>" and touch nothing
#   open           -> close it with one plain-English comment naming the merged
#                     PR URL or the landed commit URL, remove the
#                     agent-in-progress label when the issue carries it, and
#                     print "closed: <owner/repo>#<n> <url>"
#
# Four refusals keep this from ever closing something it was not asked to.
# The work must be on the default branch: the PR form reads a merged PR state,
# and the landed form asks GitHub to compare <sha> with the default branch and
# accepts only "identical" or "ahead", so a failed or unpushed landing never
# retires an issue. Every linked issue must live in one repository, the PR's own
# for the PR form, so a task that names an issue elsewhere is refused rather
# than partly applied. A task that records linked issues must ship through
# GitHub, because only its issue tracker is addressed here. And an issue absent
# from the task's own metadata is never reached at all.
#
# The no-issues check runs before the GitHub check, so an ordinary GitLab task,
# which never records GitHub issues, exits quietly instead of making its caller
# log a warning about work it was never asked to do.
#
# A failed issue read or a failed close prints
# "issue-close-failed: <owner/repo>#<n> <reason>" on stderr and exits non-zero
# without touching any later issue, so firstmate sees exactly which issue still
# needs a hand. A failed label removal only warns, because the close already
# landed: its receipt still prints and every later issue is still handled, so
# one cosmetic label never leaves another linked issue open. Callers treat a
# failure as reportable, never as a reason to undo a merge that already landed.
#
# The gh-axi binary is resolved from FM_GH_BIN at call time, the same override
# bin/fm-outage-sync.sh uses, so tests can inject a recorder. Each issue's state
# and labels are read with plain gh instead, because gh-axi's issue view prints
# no labels line; that one JSON call answers both whether the issue is open and
# whether it carries the label to strip. The landed form's compare read uses
# plain gh api for the same reason.
# Usage: fm-issue-close-after-merge.sh <task-id> <merged-pr-url>
#        fm-issue-close-after-merge.sh <task-id> --landed <sha>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  printf '%s\n' 'Usage: fm-issue-close-after-merge.sh <task-id> <merged-pr-url>' \
    '       fm-issue-close-after-merge.sh <task-id> --landed <sha>'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

invalid_request() {
  echo "error: invalid issue close request" >&2
  exit 2
}

ID=${1:-}
LANDED_SHA=
if [ "$#" -eq 3 ] && [ "$2" = --landed ]; then
  fm_pr_task_id_valid "$ID" || invalid_request
  LANDED_SHA=$3
  if ! [[ "$LANDED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: '$LANDED_SHA' is not a full commit SHA" >&2
    exit 2
  fi
else
  [ "$#" -eq 2 ] || invalid_request
  { fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$2"; } || invalid_request
  URL=$FM_PR_URL
  PR_SLUG="$FM_PR_OWNER/$FM_PR_REPO"
  # The meta stores a case-insensitive GitHub identity lowercased, so compare
  # and report against the same spelling.
  PR_SLUG_LOWER=$(printf '%s' "$PR_SLUG" | tr '[:upper:]' '[:lower:]')
fi

gh_axi() {
  "${FM_GH_BIN:-gh-axi}" "$@"
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

ISSUES=$(grep '^issues=' "$META" | tail -1 | cut -d= -f2- || true)
# No linked issue is the ordinary case, not a problem to report. This runs
# before the provider check so an ordinary GitLab task, which never records
# GitHub issues, exits quietly instead of making its caller log a warning.
[ -n "$ISSUES" ] || exit 0

# Only GitHub issues are addressed here. A GitLab merge request parses, but its
# issue tracker is a different API, so a task that does record linked issues is
# refused rather than half-handled.
if [ -z "$LANDED_SHA" ] && [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: $URL is not a GitHub pull request; refusing to close any issue" >&2
  exit 1
fi

# Split the comma-separated refs and hold them until every one is validated, so
# a task naming a foreign repo is refused before any issue is closed.
issue_ref_pattern='[a-z0-9-]+/[a-z0-9._-]+#0*[1-9][0-9]*'
if ! [[ "$ISSUES" =~ ^${issue_ref_pattern}(,${issue_ref_pattern})*$ ]]; then
  echo "error: task metadata records '$ISSUES', which is not a GitHub issue ref list" >&2
  exit 1
fi
KEEP_OPEN=$(grep '^issues_keep_open=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$KEEP_OPEN" ] \
  && ! [[ "$KEEP_OPEN" =~ ^${issue_ref_pattern}(,${issue_ref_pattern})*$ ]]; then
  echo "error: task metadata records issues_keep_open '$KEEP_OPEN', which is not a GitHub issue ref list" >&2
  exit 1
fi

# normalize_ref <owner/repo#n> -> owner/repo#n with the number's leading zeros
# dropped, so a kept-open ref and a linked ref compare by value.
normalize_ref() {
  local number=${1##*#}
  while [ "${number#0}" != "$number" ]; do
    number=${number#0}
  done
  printf '%s#%s' "${1%%#*}" "$number"
}

KEEP_SET=,
if [ -n "$KEEP_OPEN" ]; then
  IFS=, read -r -a KEEP_REFS <<< "$KEEP_OPEN"
  for ref in "${KEEP_REFS[@]}"; do
    KEEP_SET="$KEEP_SET$(normalize_ref "$ref"),"
  done
fi

REFS=()
IFS=, read -r -a REFS <<< "$ISSUES"
NUMBERS=()
if [ -n "$LANDED_SHA" ]; then
  # A landing has no PR to name its repository, so the linked issues must
  # agree on one, and that repository's default branch is what gets checked.
  PR_SLUG=${REFS[0]%%#*}
  PR_SLUG_LOWER=$PR_SLUG
fi
for ref in "${REFS[@]}"; do
  slug=${ref%%#*}
  ref=$(normalize_ref "$ref")
  if [ "$slug" != "$PR_SLUG_LOWER" ]; then
    if [ -n "$LANDED_SHA" ]; then
      echo "error: task metadata links issues in more than one repository ($PR_SLUG and $slug); refusing to close any issue" >&2
    else
      echo "error: task metadata links $ref, which is not in the merged PR's repository $PR_SLUG" >&2
    fi
    exit 1
  fi
  NUMBERS+=("${ref##*#}")
done
[ "${#NUMBERS[@]}" -gt 0 ] || exit 0

# The landing itself is the authority for closing anything, so check it first
# and refuse everything when the work is not on the default branch.
if [ -n "$LANDED_SHA" ]; then
  # GitHub's compare of <sha>...HEAD reports "identical" or "ahead" exactly
  # when the default branch contains the commit; "behind", "diverged", or an
  # unknown commit means the push never reached it.
  URL="https://github.com/$PR_SLUG/commit/$LANDED_SHA"
  COMMENT="Fixed by $URL, landed on the default branch."
  if ! COMPARE=$(gh api "repos/$PR_SLUG/compare/$LANDED_SHA...HEAD" --jq .status 2>/dev/null); then
    echo "error: could not confirm $LANDED_SHA is on the default branch of $PR_SLUG; refusing to close any issue" >&2
    exit 1
  fi
  case "$COMPARE" in
    identical|ahead) : ;;
    *)
      echo "error: $LANDED_SHA is not on the default branch of $PR_SLUG (compare: ${COMPARE:-unknown}); refusing to close any issue" >&2
      exit 1
      ;;
  esac
else
  # gh-axi reports the PR state lowercase in its own listing; the forge's own
  # uppercase spelling is accepted too so this does not depend on which one a
  # version prints.
  COMMENT="Fixed by $URL, merged to main."
  if ! PR_VIEW=$(gh_axi pr view "$FM_PR_NUMBER" -R "$PR_SLUG" 2>/dev/null); then
    echo "error: could not read the state of $URL; refusing to close any issue" >&2
    exit 1
  fi
  PR_STATE=$(printf '%s\n' "$PR_VIEW" \
    | sed -n 's/^  state: //p' | head -1 | tr -d '"')
  case "$PR_STATE" in
    merged|MERGED) : ;;
    *)
      echo "error: $URL is not merged (state: ${PR_STATE:-unknown}); refusing to close any issue" >&2
      exit 1
      ;;
  esac
fi

for number in "${NUMBERS[@]}"; do
  ref="$PR_SLUG_LOWER#$number"
  case "$KEEP_SET" in
    *",$ref,"*)
      printf 'kept-open: %s\n' "$ref"
      continue
      ;;
  esac
  # One read answers both questions this loop asks: is the issue still open,
  # and does it carry the label to strip. The reply is a single JSON line,
  # {"labels":["a","b"],"state":"OPEN"}, with the state uppercase.
  if ! view=$(gh issue view "$number" -R "$PR_SLUG" \
    --json state,labels --jq '{state,labels:[.labels[].name]}' 2>/dev/null); then
    echo "issue-close-failed: $ref could not be read from GitHub" >&2
    exit 1
  fi
  state=$(printf '%s' "$view" | sed -n 's/.*"state":"\([A-Za-z]*\)".*/\1/p')
  case "$state" in
    CLOSED)
      printf 'already-closed: %s\n' "$ref"
      continue
      ;;
    OPEN) : ;;
    *)
      echo "issue-close-failed: $ref reported an unreadable state (${state:-none})" >&2
      exit 1
      ;;
  esac
  if ! gh_axi issue close "$number" -R "$PR_SLUG" --reason completed \
    --comment "$COMMENT" >/dev/null 2>&1; then
    echo "issue-close-failed: $ref could not be closed on GitHub" >&2
    exit 1
  fi
  # The label matters only while an agent is working the issue, so remove it
  # exactly when the issue carries it and leave every other label alone. A
  # failed edit only warns: the close already landed, so its receipt still has
  # to print and every later issue still has to be handled. A leftover label on
  # a closed issue is cosmetic; a linked issue left open is the bug this script
  # exists to prevent.
  case "$view" in
    *'"agent-in-progress"'*)
      gh_axi issue edit "$number" -R "$PR_SLUG" \
        --remove-label agent-in-progress >/dev/null 2>&1 \
        || echo "warning: $ref was closed but its agent-in-progress label could not be removed" >&2
      ;;
  esac
  printf 'closed: %s %s\n' "$ref" "$URL"
done
