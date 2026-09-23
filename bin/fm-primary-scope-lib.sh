#!/usr/bin/env bash
# Usage: source bin/fm-primary-scope-lib.sh; fm_primary_scope_matches <root> <state>
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when task metadata under $2 records $1 as a spawned task's worktree.
# A recycled pool worktree can keep a retired secondmate home's gitignored
# marker, and a crewmate inherits FM_HOME from its parent, so this record is the
# proof that the session is a task and not the home that spawned it.
fm_root_is_task_worktree() {
  local root=$1 state=$2 real
  real=$(cd "$root" 2>/dev/null && pwd -P) || real=$root
  grep -Fxqs -e "worktree=$root" -e "worktree=$real" "$state"/*.meta
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
# A root that $2's task metadata records as a task worktree is never primary.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  ! fm_root_is_task_worktree "$root" "$state"
}
