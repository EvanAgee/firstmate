#!/usr/bin/env bash
# Close a shipped task's linked GitHub issues once its PR has merged, so an
# issue stops depending on a worker remembering a "Closes #n" line in the PR
# body. Some lanes deliberately write "Refs #n" instead, and GitHub then leaves
# the issue open after the merge; firstmate closes it here instead.
#
# The issues come only from the task's own state/<id>.meta issues= field, which
# bin/fm-spawn.sh records as comma-separated normalized owner/repo#<number>
# refs. A task with no issues= field is a silent no-op, because most tasks ship
# without a linked issue.
#
# For each linked issue:
#   already closed -> print "already-closed: <owner/repo>#<n>" and touch nothing
#   open           -> close it with one plain-English comment naming the merged
#                     PR URL, remove the agent-in-progress label when the issue
#                     carries it, and print "closed: <owner/repo>#<n> <url>"
#
# Four refusals keep this from ever closing something it was not asked to.
# The PR must report a merged state, so a failed or still-open merge never
# retires an issue. Every linked issue must live in the PR's own repository, so
# a task that names an issue elsewhere is refused rather than partly applied.
# A task that records linked issues must ship through GitHub, because only its
# issue tracker is addressed here. And an issue absent from the task's own
# metadata is never reached at all.
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
# whether it carries the label to strip.
# Usage: fm-issue-close-after-merge.sh <task-id> <merged-pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  printf '%s\n' 'Usage: fm-issue-close-after-merge.sh <task-id> <merged-pr-url>'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -ne 2 ]; then
  echo "error: invalid issue close request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid issue close request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_SLUG="$FM_PR_OWNER/$FM_PR_REPO"
# The meta stores a case-insensitive GitHub identity lowercased, so compare and
# report against the same spelling.
PR_SLUG_LOWER=$(printf '%s' "$PR_SLUG" | tr '[:upper:]' '[:lower:]')

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
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: $URL is not a GitHub pull request; refusing to close any issue" >&2
  exit 1
fi

# Split the comma-separated refs and hold them until every one is validated, so
# a task naming a foreign repo is refused before any issue is closed.
issue_ref_pattern='[a-z0-9-]+/[a-z0-9._-]+#[1-9][0-9]*'
if ! [[ "$ISSUES" =~ ^${issue_ref_pattern}(,${issue_ref_pattern})*$ ]]; then
  echo "error: task metadata records '$ISSUES', which is not a GitHub issue ref list" >&2
  exit 1
fi
REFS=()
IFS=, read -r -a REFS <<< "$ISSUES"
NUMBERS=()
for ref in "${REFS[@]}"; do
  slug=${ref%%#*}
  number=${ref##*#}
  if [ "$slug" != "$PR_SLUG_LOWER" ]; then
    echo "error: task metadata links $ref, which is not in the merged PR's repository $PR_SLUG" >&2
    exit 1
  fi
  NUMBERS+=("$number")
done
[ "${#NUMBERS[@]}" -gt 0 ] || exit 0

# The merge itself is the authority for closing anything, so read it first and
# refuse everything when the PR did not merge. gh-axi reports the state
# lowercase in its own listing; the forge's own uppercase spelling is accepted
# too so this does not depend on which one a version prints.
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

for number in "${NUMBERS[@]}"; do
  ref="$PR_SLUG_LOWER#$number"
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
    --comment "Fixed by $URL, merged to main." >/dev/null 2>&1; then
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
