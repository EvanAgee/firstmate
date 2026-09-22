#!/usr/bin/env bash
# fm-outage-sync.sh - reconcile local outage landings with GitHub once GitHub is
# reachable again.
#
# During a GitHub outage bin/fm-merge-local.sh fast-forwards green work onto each
# project's LOCAL default branch and records one line per landing in the
# reconciliation ledger state/outage-landings/<project>.log. When the detection
# layer clears state/.github-down and the watcher reports "GitHub is back", this
# script walks that ledger and, per landed commit:
#
#   1. Fetches origin so the comparison is against GitHub's current default branch.
#   2. If the landed commit is already an ancestor of origin/<default>, it is
#      already on GitHub - a no-op - and the ledger entry is cleared. This is what
#      makes the whole thing idempotent: a re-run after a successful sync does
#      nothing. Deferred workflows are NOT auto-dispatched on this path (a re-run
#      would double-fire them); if such an entry still names deferred checks, the
#      script says so once so they are not silently dropped.
#   3. Otherwise, if local <default> is a clean fast-forward AHEAD of
#      origin/<default> (origin's tip is an ancestor of the local tip), it pushes
#      local <default> to origin/<default> - a plain fast-forward push, never
#      --force. On a confirmed push it dispatches the deferred schedule-only
#      workflows recorded for that landing (gh-axi workflow run <name> --ref
#      <default>) and clears the ledger entry.
#   4. If local and origin have DIVERGED (origin advanced during the outage with
#      commits the local branch does not have), it ESCALATES: it prints a clear
#      line naming the project and leaves the ledger entry in place. It never
#      force-pushes and never force-merges; the landed work is safe on the local
#      branch and just waits for a manual rebase. This is the same
#      refuse-on-divergence posture bin/fm-merge-local.sh and bin/fm-fleet-sync.sh
#      already take, applied to the push.
#
# The push-triggered workflows (those gating on push:branches:[<default>], e.g.
# ci.yml) re-fire automatically on the fast-forward push, so only the
# schedule-only workflows recorded as deferred are dispatched by hand.
#
# This is firstmate's operational state under state/, so firstmate writes the
# ledger directly; the push into projects/ is the same sanctioned local-merge
# authority bin/fm-merge-local.sh already exercises, exercised on return.
#
# Usage:
#   fm-outage-sync.sh              reconcile every project ledger
#   fm-outage-sync.sh <project>    reconcile only <project>.log
#   fm-outage-sync.sh -h|--help    print this header
#
# Exit status is 0 when every entry it processed was synced or was already an
# ancestor (a clean run), and non-zero when at least one entry escalated (a
# divergence a human must reconcile) or a push/fetch failed, so a caller can tell
# "all reconciled" from "some still owe attention".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER_DIR="$STATE/outage-landings"

# gh-axi is the repo's GitHub wrapper; a test seam swaps it for a recorder.
GH="${FM_GH_BIN:-gh-axi}"

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ONLY_PROJECT=${1:-}

default_branch() {  # <proj>
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Rewrite a ledger file to drop exactly the lines whose landing SHA (field 6,
# "after") is in the passed newline-separated set of cleared SHAs. Writing a temp
# file and moving it keeps a concurrent read from seeing a half-written ledger.
drop_cleared_entries() {  # <ledger-file> <cleared-shas-newline-separated>
  local ledger=$1 cleared=$2 tmp after
  tmp=$(mktemp "$ledger.XXXXXX") || return 1
  while IFS=$(printf '\t') read -r _at _id _proj _branch _before after _deferred _review; do
    [ -n "$after" ] || continue
    case "$cleared" in
      *"$after"*)
        # Match only on a whole-line SHA to avoid a substring false positive.
        if printf '%s\n' "$cleared" | grep -qxF "$after"; then
          continue
        fi
        ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_at" "$_id" "$_proj" "$_branch" "$_before" "$after" "$_deferred" "$_review" >> "$tmp"
  done < "$ledger"
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$ledger"
  else
    rm -f "$tmp" "$ledger"
  fi
}

# Dispatch the deferred schedule-only workflows for one landing on the given ref.
# A comma-separated, possibly-empty list; each name is dispatched independently
# and a failure to dispatch one is reported but does not block clearing the entry
# (the commit is already on origin, which is the thing that must not be lost).
dispatch_deferred() {  # <proj> <default> <deferred-csv>
  local proj=$1 default=$2 csv=$3 name rest
  [ -n "$csv" ] || return 0
  rest=$csv
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*) name=${rest%%,*}; rest=${rest#*,} ;;
      *) name=$rest; rest= ;;
    esac
    # Trim surrounding whitespace.
    name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$name" ] || continue
    if ( cd "$proj" && "$GH" workflow run "$name" --ref "$default" ) >/dev/null 2>&1; then
      echo "  dispatched deferred workflow $name on $default"
    else
      echo "  WARNING: could not dispatch deferred workflow $name on $default (dispatch it by hand)" >&2
    fi
  done
}

# Reconcile one ledger file. Echoes progress; returns 0 if every entry it saw is
# now on origin (synced or already-ancestor), 1 if any escalated or failed.
sync_ledger() {  # <ledger-file>
  local ledger=$1 rc=0 cleared="" default origin_ref proj branch after deferred
  [ -f "$ledger" ] || return 0

  while IFS=$(printf '\t') read -r _at _id proj branch _before after deferred _review; do
    [ -n "$proj" ] && [ -n "$after" ] || continue
    if [ ! -d "$proj" ] || ! git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "ESCALATE: $proj is not a readable git repository; the outage landing $after cannot be synced automatically" >&2
      rc=1
      continue
    fi

    if ! git -C "$proj" fetch origin --quiet 2>/dev/null; then
      echo "ESCALATE: fetch of origin failed for $proj; leaving landing $after for a retry" >&2
      rc=1
      continue
    fi

    default=$(default_branch "$proj") || {
      echo "ESCALATE: cannot determine default branch for $proj; leaving landing $after" >&2
      rc=1
      continue
    }
    origin_ref="origin/$default"
    if ! git -C "$proj" rev-parse --verify --quiet "$origin_ref^{commit}" >/dev/null; then
      echo "ESCALATE: $origin_ref does not exist for $proj; leaving landing $after" >&2
      rc=1
      continue
    fi

    # Already on GitHub: idempotent no-op, clear the entry. This is both the
    # re-run case (the entry was synced earlier) and the stacked case (an earlier
    # landing's push carried this commit up too). Deferred schedule-only workflows
    # are NOT auto-dispatched here: on a re-run they would double-fire, and there
    # is no durable way to tell a re-run from a genuinely-un-dispatched stack. When
    # this entry still names deferred checks, say so once so they are not silently
    # dropped - firstmate or a human can dispatch them by hand if they truly never
    # ran (bin/fm-github-health.sh / gh-axi workflow run).
    if git -C "$proj" merge-base --is-ancestor "$after" "$origin_ref" 2>/dev/null; then
      echo "$proj: landing $after already on $origin_ref; nothing to push"
      if [ -n "$deferred" ]; then
        echo "  note: deferred checks [$deferred] for landing $after were not auto-dispatched (commit already on origin); dispatch them by hand if they never ran"
      fi
      cleared="$cleared$after"$'\n'
      continue
    fi

    # The landed commit is not on origin yet. It must be reachable from the local
    # default branch (fm-merge-local fast-forwarded it there) for a safe push.
    if ! git -C "$proj" merge-base --is-ancestor "$after" "$default" 2>/dev/null; then
      echo "ESCALATE: landing $after is not on local $default in $proj; it needs manual reconciliation" >&2
      rc=1
      continue
    fi

    # Divergence check: origin's tip must be an ancestor of local <default> for a
    # clean fast-forward push. If origin advanced with commits the local branch
    # lacks, refuse and escalate - never force-push.
    if ! git -C "$proj" merge-base --is-ancestor "$origin_ref" "$default" 2>/dev/null; then
      echo "ESCALATE: local $default and $origin_ref diverged in $proj during the outage; the outage landings need rebasing before they can go up (never force-pushed)" >&2
      rc=1
      continue
    fi

    if git -C "$proj" push origin "$default":"$default" --quiet 2>/dev/null; then
      echo "$proj: pushed local $default to $origin_ref (landing $after)"
      dispatch_deferred "$proj" "$default" "$deferred"
      cleared="$cleared$after"$'\n'
    else
      echo "ESCALATE: fast-forward push of $default failed for $proj (origin may have moved mid-sync); leaving landing $after" >&2
      rc=1
    fi
  done < "$ledger"

  if [ -n "$cleared" ]; then
    drop_cleared_entries "$ledger" "$cleared" || {
      echo "WARNING: could not rewrite ledger $ledger after clearing synced entries" >&2
      rc=1
    }
  fi
  return "$rc"
}

overall=0
if [ -n "$ONLY_PROJECT" ]; then
  ledger="$LEDGER_DIR/$ONLY_PROJECT.log"
  if [ ! -f "$ledger" ]; then
    echo "no outage-landings ledger for '$ONLY_PROJECT' (nothing to sync)"
    exit 0
  fi
  sync_ledger "$ledger" || overall=1
else
  [ -d "$LEDGER_DIR" ] || { echo "no outage landings to sync"; exit 0; }
  found=0
  for ledger in "$LEDGER_DIR"/*.log; do
    [ -e "$ledger" ] || continue
    found=1
    sync_ledger "$ledger" || overall=1
  done
  [ "$found" -eq 1 ] || echo "no outage landings to sync"
fi
exit "$overall"
