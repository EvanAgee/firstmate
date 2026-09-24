#!/usr/bin/env bash
# Point a ship brief still on "Spec: to-spec phase" at the one spec its lane wrote.
#
# A ship brief scaffolded without --spec (bin/fm-brief.sh) starts on
# "Spec: to-spec phase": the worker's first job is writing docs/specs/<task>.md.
# The captain's spec-gate hook refuses bin/fm-merge-local.sh for a brief still on
# that line, and it judges a command before the command runs, so the brief must
# name the real spec before the landing command starts. Run this command on its
# own first, then land.
#
# It reads the task's recorded worktree from state/<task>.meta and lists the
# candidate specs that worktree's checked-out commit added or changed against
# the project's default branch: docs/specs/*.md and docs/design/*-spec.md.
# When the first backticked spec path in the brief's "# Spec first" section
# (bin/fm-brief.sh writes docs/specs/<task-id>.md there) is one of those
# candidates, that file is the spec. Otherwise it lints every candidate and drops each one that
# fails, so an index such as docs/specs/MAP.md never counts, and exactly one
# must remain. It lints where the hook will read, in the worktree, with
# $FM_SPEC_LINT (default ~/.agents/skills/spec-lint/spec-lint), then rewrites
# the brief's first "Spec:" line to "Spec: <path relative to the worktree>",
# which is the line the hook reads and the way it resolves a relative path at
# landing time. Every other byte of the brief is kept.
#
# It refuses, exits 1, and leaves the brief untouched when the brief-named spec
# does not lint, when no candidate or more than one lints clean (naming each
# candidate as clean or dropped, with the linter's faults), or when the brief
# has no "Spec:" line. A brief that already names another spec is left alone
# (exit 0), so running this before every landing is safe. It never checks the
# proof's acceptance criterion ids; the hook owns that check at landing.
#
# Usage: fm-spec-point.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SPEC_LINT=${FM_SPEC_LINT:-$HOME/.agents/skills/spec-lint/spec-lint}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  echo "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
ID=$1

BRIEF="$DATA/$ID/brief.md"
META="$STATE/$ID.meta"
[ -f "$BRIEF" ] || die "error: no brief for task $ID at $BRIEF"

current=$(grep -m1 '^Spec:' "$BRIEF" || true)
[ -n "$current" ] || die "refused: $BRIEF has no Spec: line; scaffold ship briefs with bin/fm-brief.sh, which writes one"
current=$(printf '%s\n' "$current" | sed 's/^Spec:[[:space:]]*//; s/[[:space:]]*$//')
if [ "$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')" != "to-spec phase" ]; then
  echo "$ID's brief already names $current; nothing to point"
  exit 0
fi

[ -f "$META" ] || die "error: no meta for task $ID at $META"
WORKTREE=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
if [ -z "$WORKTREE" ] || ! git -C "$WORKTREE" rev-parse --verify --quiet HEAD >/dev/null; then
  die "error: task $ID has no readable worktree recorded in $META"
fi

# The branch a landing moves: origin/HEAD's target when recorded, else main or
# master, preferring the local branch over its remote-tracking copy.
default_base() {
  local name ref
  name=$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  name=${name#origin/}
  for ref in ${name:+"$name" "origin/$name"} main origin/main master origin/master; do
    if git -C "$WORKTREE" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}
BASE=$(default_base) || die "error: cannot find the default branch in $WORKTREE"

changed=$(git -C "$WORKTREE" diff --name-only --no-renames --diff-filter=d "$BASE...HEAD" -- 'docs/specs/*.md' 'docs/design/*-spec.md')
# shellcheck disable=SC2016 # the backticks are literal brief text the regex matches, not command substitution.
named=$(awk '/^# Spec first/ { on = 1; next } on && /^# / { exit } on' "$BRIEF" \
  | grep -oE '`docs/(specs/[^`[:space:]]+\.md|design/[^`[:space:]]+-spec\.md)`' | head -n1 | tr -d '`')

[ -x "$SPEC_LINT" ] || die "error: spec linter not found at $SPEC_LINT; set FM_SPEC_LINT to its path"

SPEC=
if [ -n "$named" ] && printf '%s\n' "$changed" | grep -qxF -- "$named"; then
  if ! lint_out=$("$SPEC_LINT" "$WORKTREE/$named" 2>&1); then
    printf '%s\n' "$lint_out" >&2
    die "refused: $named, which $ID's brief names, does not lint clean; the worker fixes it before landing"
  fi
  SPEC=$named
fi

if [ -z "$SPEC" ]; then
  kept=0 why=
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if lint_out=$("$SPEC_LINT" "$WORKTREE/$f" 2>&1); then
      kept=$((kept + 1)) SPEC=$f
      why+=$'\n'"  $f: lints clean"
    else
      why+=$'\n'"  $f: dropped, does not lint:"$'\n'$(printf '%s\n' "$lint_out" | sed 's/^/    /')
    fi
  done <<< "$changed"
  if [ "$kept" -ne 1 ]; then
    die "refused: $ID's lane in $WORKTREE changed $kept specs that lint clean among docs/specs/*.md and docs/design/*-spec.md against $BASE; it must change exactly one$why"
  fi
fi

# Write in place so the brief keeps its file and permissions.
rewritten=$(SPEC_PATH="$SPEC" awk '!done && /^Spec:/ { print "Spec: " ENVIRON["SPEC_PATH"]; done = 1; next } { print }' "$BRIEF")
printf '%s\n' "$rewritten" > "$BRIEF"
echo "pointed $ID's brief at $SPEC"
