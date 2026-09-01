#!/usr/bin/env bash
# Perform an approved local merge for a ship task: fast-forward the project's
# default branch to the crewmate's lane branch, entirely on the local machine.
# After the fast-forward succeeds, available task and no-mistakes timing is
# appended to the home-local data/delivery-log.jsonl without changing the merge.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it stays narrow. It
# runs in exactly two situations:
#
#   1. mode=local-only tasks - the original use: a task that never had a PR and
#      lands straight onto the local default branch after the captain approves
#      (or yolo=on auto-approves).
#   2. A normally-PR-bound task (mode=no-mistakes / direct-PR) ONLY while GitHub
#      is unreachable - state/.github-down present. During an outage a green,
#      locally-validated task cannot open or merge a PR, so it lands locally by
#      the same clean fast-forward and syncs to GitHub on return
#      (bin/fm-outage-sync.sh). When GitHub is up this path is REFUSED and the
#      task uses the normal PR flow (bin/fm-pr-merge.sh), unchanged.
#
# In both cases the merge is a clean fast-forward only: it refuses a diverged
# branch and tells you to have the crewmate rebase. It never force-merges and
# never touches unlanded work. The outage path lands only what the captain's
# existing authority (yolo, or an explicit approval) already covers; it invents
# no new merge authority. See AGENTS.md prime directives, task lifecycle, and
# data/outage-local-merge-design/ (the design) plus its captain-decision.md.
#
# The lane branch is resolved in this order: an explicit second argument, else
# the branch currently checked out in the task's recorded worktree (the lane the
# crewmate committed on), else the legacy fm/<id> name. A PR-bound outage landing
# also appends one line to the reconciliation ledger
# state/outage-landings/<project>.log recording what landed and which
# GitHub-dispatched checks are still owed (bin/fm-outage-sync.sh reads it on
# return). The ledger is a record of what already safely happened; it gates and
# drives nothing.
#
# Usage: fm-merge-local.sh <task-id> [<lane-branch>] [--deferred-checks <list>]
#   <lane-branch>          explicit branch to fast-forward the default branch to;
#                          omit to resolve from the task worktree or fm/<id>.
#   --deferred-checks <l>  comma-separated names of the schedule-only workflows
#                          that could not run during the outage and must be
#                          dispatched on return (recorded verbatim in the ledger
#                          for an outage landing; ignored for a local-only task).
#   --adversarial-review-passed <ref>
#                          proof that a SECOND, independent agent adversarially
#                          reviewed this change and cleared it. It is REQUIRED for
#                          an autonomous outage auto-land on a yolo=on project: per
#                          the captain's decision (data/outage-local-merge-design/
#                          captain-decision.md), green-on-local work auto-lands
#                          during an outage only if it also passes an adversarial
#                          review, and firstmate spawns and supervises that review
#                          before calling this script (a script cannot supervise an
#                          agent). Without it a yolo=on outage landing is refused,
#                          so the unsafe state - auto-landing with only one review -
#                          cannot occur even by mistake. <ref> is recorded in the
#                          ledger as evidence. A yolo=off landing is captain-approved
#                          and does not use this gate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

ID=${1:?usage: fm-merge-local.sh <task-id> [<lane-branch>] [--deferred-checks <list>] [--adversarial-review-passed <ref>]}
shift
LANE_BRANCH=
DEFERRED_CHECKS=
ADVERSARIAL_REVIEW=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --deferred-checks)
      DEFERRED_CHECKS=${2:-}
      shift 2
      ;;
    --deferred-checks=*)
      DEFERRED_CHECKS=${1#--deferred-checks=}
      shift
      ;;
    --adversarial-review-passed)
      ADVERSARIAL_REVIEW=${2:-}
      shift 2
      ;;
    --adversarial-review-passed=*)
      ADVERSARIAL_REVIEW=${1#--adversarial-review-passed=}
      shift
      ;;
    --*)
      echo "error: unknown option '$1'" >&2
      exit 1
      ;;
    *)
      if [ -z "$LANE_BRANCH" ]; then
        LANE_BRANCH=$1
        shift
      else
        echo "error: unexpected extra argument '$1'" >&2
        exit 1
      fi
      ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
YOLO=$(grep '^yolo=' "$META" | cut -d= -f2- || true)
WORKTREE=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
FLAG="$STATE/.github-down"

# Mode gate. A local-only task always lands here. A normally-PR-bound task is
# allowed ONLY during an outage; otherwise it must use the normal PR merge.
OUTAGE_LANDING=no
case "$MODE" in
  local-only)
    :
    ;;
  no-mistakes|direct-PR)
    if [ -e "$FLAG" ]; then
      OUTAGE_LANDING=yes
    else
      echo "error: task $ID is mode=$MODE; a PR-bound task lands locally only while GitHub is unreachable (state/.github-down present)." >&2
      echo "GitHub is reachable, so merge its PR with bin/fm-pr-merge.sh <id> <PR url> after approval instead." >&2
      exit 1
    fi
    ;;
  *)
    echo "error: task $ID is mode=$MODE, which cannot land locally; expected local-only, or a PR-bound mode during a GitHub outage" >&2
    exit 1
    ;;
esac

# Adversarial-review gate for an AUTONOMOUS outage auto-land. Per the captain's
# decision, a yolo=on project auto-lands green-on-local work during an outage only
# if a second, independent agent also adversarially reviewed and cleared it.
# firstmate runs that review and passes --adversarial-review-passed <ref>; without
# it the auto-land is refused here, so "auto-land with only one review" is
# impossible at the mechanism level, not merely by agent memory. A yolo=off outage
# landing is captain-approved (firstmate only calls this after the captain's word),
# so it does not use this gate.
if [ "$OUTAGE_LANDING" = yes ] && [ "$YOLO" = on ] && [ -z "$ADVERSARIAL_REVIEW" ]; then
  echo "error: task $ID is an autonomous outage auto-land (mode=$MODE, yolo=on) but no adversarial review was recorded." >&2
  echo "An outage auto-land requires a second independent agent to adversarially review and clear the change first; pass --adversarial-review-passed <ref> once that review clears." >&2
  exit 1
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the lane branch: explicit arg, else the task worktree's current branch,
# else the legacy fm/<id> name. The worktree's checked-out branch is the lane the
# crewmate committed on, so it is the right default for an outage landing whose
# branch is ticket-named rather than fm/<id>.
resolve_lane_branch() {
  local b
  if [ -n "$LANE_BRANCH" ]; then
    printf '%s\n' "$LANE_BRANCH"
    return 0
  fi
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    b=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$b" ]; then
      printf '%s\n' "$b"
      return 0
    fi
  fi
  printf '%s\n' "fm/$ID"
}

BRANCH=$(resolve_lane_branch)
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
  || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before_full=$(git -C "$PROJ" rev-parse "$DEFAULT")
before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after_full=$(git -C "$PROJ" rev-parse "$DEFAULT")
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
LANDED_AT=
if ! LANDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ); then
  echo "warning: could not determine the local landing timestamp for $ID" >&2
  LANDED_AT=
fi

delivery_repo=$(basename "$PROJ")
case "$delivery_repo" in
  ''|.|..|*/*) delivery_repo=project ;;
esac
if ! "$SCRIPT_DIR/fm-delivery-record.sh" "$ID" \
  --repo "$delivery_repo" \
  --project-path "$PROJ" \
  --branch "$BRANCH" \
  --merged-at "$LANDED_AT"; then
  echo "warning: delivery timing was not recorded for $ID after the local landing" >&2
fi

# Record the reconciliation ledger entry for an outage landing so the work can be
# pushed and its deferred GitHub checks dispatched when GitHub returns. Only an
# outage landing owes GitHub a round-trip; a local-only task never had a PR.
if [ "$OUTAGE_LANDING" = yes ]; then
  ledger_dir="$STATE/outage-landings"
  mkdir -p "$ledger_dir"
  project_name=$(basename "$PROJ")
  case "$project_name" in
    ''|.|..|*/*) project_name=project ;;
  esac
  landed_at=${LANDED_AT:-unknown}
  # Strip any tab or newline from free-text fields so one landing stays one line
  # and the tab-separated field contract cannot be broken by the review ref.
  review_ref=$(printf '%s' "$ADVERSARIAL_REVIEW" | tr '\t\n' '  ')
  deferred_field=$(printf '%s' "$DEFERRED_CHECKS" | tr '\t\n' '  ')
  # One tab-separated line per landing, self-contained so sync-on-return needs no
  # other record: landed-at, task id, project path, lane branch, before and after
  # default-branch SHAs, the deferred schedule-only workflows, and the adversarial
  # review evidence (empty for a captain-approved yolo=off landing). Record-only;
  # it drives nothing. Field order is the contract bin/fm-outage-sync.sh parses.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$landed_at" "$ID" "$PROJ" "$BRANCH" "$before_full" "$after_full" "$deferred_field" "$review_ref" \
    >> "$ledger_dir/$project_name.log"
  echo "recorded outage landing for $project_name in $ledger_dir/$project_name.log (deferred checks: ${DEFERRED_CHECKS:-none}, review: ${ADVERSARIAL_REVIEW:-none})"
fi
