#!/usr/bin/env bash
# Switch a project between firstmate's two delivery flows: the full PR flow and
# the fast local-only flow. Captain decision 2026-09-16; the contract is
# docs/specs/flow-switch.md, which is authoritative over this comment.
#
# The two flows:
#
#   |                     | full (default)                 | fast                          |
#   |---------------------|--------------------------------|-------------------------------|
#   | Registry posture    | [no-mistakes-prod-only +yolo]  | [local-only +yolo]            |
#   | Worker delivery     | pipeline or PR, waits          | clean local branch, stops     |
#   | Merge               | bin/fm-pr-merge.sh after green | bin/fm-merge-local.sh --push: |
#   |                     |                                | ff, push main, close issues   |
#   | Main-protection and | active                         | disabled                      |
#   | Copilot-review      |                                |                               |
#   | rulesets            |                                |                               |
#   | Commit-identity     | active                         | active, never touched         |
#   | Guard               | required checks before merge   | CI on main + auto-revert on   |
#   |                     |                                | red (the post-merge workflow) |
#
# What the switch never does: merge, push, spawn, edit a project's code,
# delete a ruleset, or change config/crew-dispatch.json. Lanes already running
# finish under the flow they launched in.
#
# Subcommands:
#   fm-flow.sh <project> fast
#       Rewrite the project's registry line in data/projects.md to
#       [local-only +yolo], keeping the description and dates. Store the
#       previous posture annotation in state/.flow-<project> for `full`.
#       Set enforcement=disabled on the project's main-protection ruleset and
#       its Copilot review ruleset. Refuse unless the post-merge workflow
#       (.github/workflows/main-postmerge.yml) exists on the project's default
#       branch, unless --no-guard <reason> is passed. Append a dated line to
#       data/captain.md under Working style recording that firstmate may push
#       <project> main without asking while fast is on. Print the project's
#       open fleet PRs so none is stranded. Idempotent: a second fast with
#       nothing to change changes nothing and says so.
#   fm-flow.sh <project> full
#       Restore the registry annotation recorded at the last fast flip, set
#       both rulesets back to active, and remove the push-authority line.
#   fm-flow.sh <project> status
#       Print the registry posture, each ruleset's enforcement, the stored
#       previous posture, and a one-word verdict: fast, full, or DRIFT when
#       the sides disagree.
#
# Ruleset discovery is by target condition and name, never hardcoded ids: the
# main-protection ruleset is the active branch ruleset whose conditions include
# ~DEFAULT_BRANCH; the review ruleset is the one whose name contains Copilot.
# The matched ids and their current rule types are printed. Zero or multiple
# matches refuse. status also reports whether the main ruleset carries
# pull_request or required_status_checks rules, so it is visible when the
# gates are already gone.
#
# Every GitHub write is one `gh api -X PUT` call. A 403 is reported as a
# rate-limit or permission problem and never retried.
#
# Flags:
#   --no-guard <reason>   allow `fast` without the post-merge workflow; the
#                         reason is recorded in the output
#
# Overrides for tests and homes: FM_ROOT_OVERRIDE, FM_HOME, FM_DATA_OVERRIDE,
# FM_STATE_OVERRIDE, FM_PROJECTS_OVERRIDE, FM_GH_BIN (default `gh`).
# Usage: fm-flow.sh <project> fast|full|status [--no-guard <reason>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
GH_BIN="${FM_GH_BIN:-gh}"

usage() {
  printf '%s\n' 'Usage: fm-flow.sh <project> fast|full|status [--no-guard <reason>]'
}

die() {
  printf 'fm-flow: %s\n' "$1" >&2
  exit 1
}

# --- argument parsing --------------------------------------------------------

NO_GUARD=0
NO_GUARD_REASON=""
MODE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    fast|full|status)
      [ -z "$MODE" ] || die "exactly one of fast|full|status"
      MODE=$1
      shift
      ;;
    --no-guard)
      NO_GUARD=1
      shift
      [ $# -gt 0 ] || die "--no-guard requires a reason"
      NO_GUARD_REASON=$1
      [ -n "$NO_GUARD_REASON" ] || die "--no-guard requires a non-empty reason"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

[ -n "$MODE" ] || { usage >&2; exit 1; }
[ ${#POSITIONAL[@]} -eq 1 ] || { usage >&2; exit 1; }
NAME=${POSITIONAL[0]}

REG="$DATA/projects.md"
FLOW_STATE="$STATE/.flow-$NAME"
CAPTAIN="$DATA/captain.md"
PUSH_MARKER="firstmate may push $NAME main without asking while fast is on"

[ -f "$REG" ] || die "no registry at $REG"

# --- project resolution ------------------------------------------------------

# resolve_repo_slug: owner/repo from the project clone's origin remote, or from
# the registry line's https://github.com/<owner>/<repo> URL as a fallback.
resolve_repo_slug() {
  local clone="$PROJECTS/$NAME" url path
  if [ -d "$clone/.git" ] || [ -f "$clone/.git" ]; then
    url=$(git -C "$clone" remote get-url origin 2>/dev/null || true)
  fi
  [ -n "${url:-}" ] || url=$(awk -v n="$NAME" '
    $1=="-" && $2==n {
      for (i=1; i<=NF; i++) if ($i ~ /^https:\/\/github\.com\/[^\/]+\/[^\/]+/) {
        print $i; exit
      }
    }' "$REG")
  [ -n "${url:-}" ] || die "cannot resolve a GitHub origin for project \"$NAME\" (no clone with an origin remote, no https github URL in the registry)"
  case "$url" in
    git@github.com:*) path=${url#git@github.com:} ;;
    *github.com/*)    path=${url#*github.com/} ;;
    *) die "unrecognized GitHub remote URL: $url" ;;
  esac
  path=${path%.git}
  path=${path%/}
  case "$path" in
    */*) printf '%s\n' "$path" ;;
    *) die "unrecognized GitHub remote URL: $url" ;;
  esac
}

# --- registry line rewrite ---------------------------------------------------

# registry_line: print the project's complete registry line, or fail.
registry_line() {
  awk -v n="$NAME" '$1=="-" && $2==n { print; exit }' "$REG"
}

# registry_annotation: the bracketed posture annotation, e.g.
# "no-mistakes-prod-only +yolo". Empty when the line carries no annotation.
# The bracket scan mirrors bin/fm-project-mode.sh's line grammar.
registry_annotation() {
  awk -v n="$NAME" '
    $1=="-" && $2==n {
      annotation="";
      if ($3 ~ /^\[/) {
        for (i=3; i<=NF; i++) {
          annotation = annotation (annotation==""?"":" ") $i;
          if ($i ~ /\]$/) break;
        }
        if (annotation !~ /\]$/) annotation="";
        gsub(/^\[|\]$/, "", annotation);
      }
      print annotation; exit
    }' "$REG"
}

# rewrite_registry <new-annotation>: atomically replace the project's bracketed
# annotation in the registry line, keeping everything before and after intact.
rewrite_registry() {
  local new=$1 tmp
  tmp=$(mktemp "$REG.tmp.XXXXXX") || die "cannot create a registry temp file"
  awk -v n="$NAME" -v repl="[$new]" '
    {
      if ($1=="-" && $2==n) {
        has_ann=0;
        if ($3 ~ /^\[/) has_ann=1;
        out="";
        inbr=0;
        for (i=1; i<=NF; i++) {
          if (has_ann && !inbr && $i ~ /^\[/) {
            inbr=1; out=out (out==""?"":" ") repl;
            if ($i ~ /\]$/) inbr=0; continue
          }
          if (inbr) { if ($i ~ /\]$/) inbr=0; continue }
          out=out (out==""?"":" ") $i
          if (i==2 && !has_ann) { out=out " " repl }
        }
        print out
      } else {
        print
      }
    }' "$REG" > "$tmp"
  mv "$tmp" "$REG"
}

# replace_registry_line <whole-line>: atomically replace the project's
# complete registry line (hand-flip restore path).
replace_registry_line() {
  local new=$1 tmp
  tmp=$(mktemp "$REG.tmp.XXXXXX") || die "cannot create a registry temp file"
  awk -v n="$NAME" -v newline="$new" '
    { if ($1=="-" && $2==n) print newline; else print }' "$REG" > "$tmp"
  mv "$tmp" "$REG"
}

# --- rulesets ----------------------------------------------------------------

list_ruleset_ids() {
  if ! "$GH_BIN" api "repos/$REPO_SLUG/rulesets" \
      --jq '.[] | "\(.id)\t\(.name)"' 2>/dev/null; then
    die "could not list rulesets for $REPO_SLUG (GitHub read failed)"
  fi
}

# ruleset_detail <id>: JSON with .name, .target, .enforcement, .bypass_actors,
# and the full .rules array (objects, parameters included), so the PUT body
# never rewrites a rule's parameters.
ruleset_detail() {
  "$GH_BIN" api "repos/$REPO_SLUG/rulesets/$1" \
    --jq '{name: .name, target: .target, enforcement: .enforcement, bypass_actors: .bypass_actors, conditions: .conditions, rules: .rules}' 2>/dev/null
}

# discover_main_ruleset <ids-file>: print the id of the branch ruleset
# whose conditions include ~DEFAULT_BRANCH (the main-protection ruleset by
# target, not by rule list; its required checks were removed 2026-09). Exactly
# one match required. Enforcement does not gate candidacy: fast disables the
# matched ruleset, and full must still find it.
discover_main_ruleset() {
  local ids_file=$1 id name count=0 match=""
  while IFS="$(printf '\t')" read -r id name; do
    [ -n "$id" ] || continue
    if ruleset_detail "$id" | jq -e '
      .target == "branch" and
      (.conditions.ref_name.include // [] | index("~DEFAULT_BRANCH") != null)' >/dev/null 2>&1; then
      count=$((count + 1))
      match=$id
    fi
  done < "$ids_file"
  [ "$count" -eq 1 ] || die "expected exactly one main-protection ruleset (a branch ruleset targeting ~DEFAULT_BRANCH) on $REPO_SLUG, found $count"
  printf '%s\n' "$match"
}

# discover_review_ruleset <ids-file> <main-id>: print the id of the ruleset
# whose name contains Copilot, excluding the already-matched main-protection
# ruleset (on repos where the main ruleset is itself Copilot-named). Exactly
# one match required.
discover_review_ruleset() {
  local ids_file=$1 main_id=$2 id name count=0 match=""
  while IFS="$(printf '\t')" read -r id name; do
    [ -n "$id" ] || continue
    [ "$id" != "$main_id" ] || continue
    case "$name" in
      *Copilot*)
        count=$((count + 1))
        match=$id
        ;;
    esac
  done < "$ids_file"
  [ "$count" -eq 1 ] || die "expected exactly one review ruleset (name containing Copilot, other than the main-protection ruleset) on $REPO_SLUG, found $count"
  printf '%s\n' "$match"
}

# print_matched_ids <main-id> <review-id>: print each matched id and the rule
# types it currently carries.
print_matched_ids() {
  local main_id=$1 review_id=$2 main_rules review_rules
  main_rules=$(ruleset_detail "$main_id" | jq -r '[.rules[].type] | join(",")')
  review_rules=$(ruleset_detail "$review_id" | jq -r '[.rules[].type] | join(",")')
  printf 'matched rulesets: main-protection=%s (rules: %s) review=%s (rules: %s)\n' \
    "$main_id" "${main_rules:-none}" "$review_id" "${review_rules:-none}"
}

# main_gate_report <main-id>: one line naming which merge gates the
# main-protection ruleset still carries: pull_request and/or
# required_status_checks, or "none (gates already gone)".
main_gate_report() {
  local types
  types=$(ruleset_detail "$1" | jq -r '[.rules[].type] | join(" ")')
  case "$types" in
    *pull_request*required_status_checks*|*required_status_checks*pull_request*)
      printf 'pull_request + required_status_checks present' ;;
    *pull_request*)      printf 'pull_request present (required_status_checks gone)' ;;
    *required_status_checks*) printf 'required_status_checks present (pull_request gone)' ;;
    *)                   printf 'none (gates already gone)' ;;
  esac
}

# A 403 from gh api means rate limit or permission: report it, never retry.
put_enforcement() {
  local id=$1 enforcement=$2 detail body err
  detail=$(ruleset_detail "$id") || die "could not read ruleset $id on $REPO_SLUG"
  body=$(printf '%s' "$detail" | jq -c '{name, target, enforcement: $e, bypass_actors, rules}' --arg e "$enforcement") \
    || die "could not build the update payload for ruleset $id"
  err=$(mktemp) || die "cannot create a temp file"
  if printf '%s' "$body" | "$GH_BIN" api "repos/$REPO_SLUG/rulesets/$id" \
      -X PUT --input - >/dev/null 2>"$err"; then
    rm -f "$err"
    printf 'ruleset %s enforcement -> %s\n' "$id" "$enforcement"
    return 0
  fi
  if grep -q "403" "$err" 2>/dev/null; then
    rm -f "$err"
    die "GitHub refused the ruleset update with 403: a rate-limit or permission problem; not retrying"
  fi
  rm -f "$err"
  die "ruleset $id enforcement update to $enforcement failed"
}

# --- guard workflow ----------------------------------------------------------

# guard_present: does .github/workflows/main-postmerge.yml exist on the
# project's default branch? A 404 is a legitimate absence, not an error.
guard_present() {
  local default_branch
  default_branch=$("$GH_BIN" api "repos/$REPO_SLUG" --jq '.default_branch' 2>/dev/null) || \
    die "could not read the default branch of $REPO_SLUG"
  [ -n "$default_branch" ] || die "empty default branch for $REPO_SLUG"
  "$GH_BIN" api "repos/$REPO_SLUG/contents/.github/workflows/main-postmerge.yml?ref=$default_branch" \
    --jq '.path' >/dev/null 2>&1 && return 0
  return 1
}

# --- captain.md push-authority line ------------------------------------------

has_push_line() {
  grep -qF "$PUSH_MARKER" "$CAPTAIN" 2>/dev/null
}

append_push_line() {
  if ! grep -q '^## Working style' "$CAPTAIN" 2>/dev/null; then
    printf '## Working style\n' >> "$CAPTAIN"
  fi
  printf -- '- **Flow switch push authority** (%s): %s.\n' "$(date +%F)" "$PUSH_MARKER" >> "$CAPTAIN"
}

remove_push_line() {
  [ -f "$CAPTAIN" ] || return 0
  local tmp
  tmp=$(mktemp "$CAPTAIN.tmp.XXXXXX") || die "cannot create a captain.md temp file"
  grep -vF "$PUSH_MARKER" "$CAPTAIN" > "$tmp" || true
  mv "$tmp" "$CAPTAIN"
}

# --- open PR listing ---------------------------------------------------------

list_open_prs() {
  "$GH_BIN" pr list -R "$REPO_SLUG" --state open --limit 100 2>/dev/null || \
    printf '(could not list open PRs for %s)\n' "$REPO_SLUG"
}

# --- subcommands -------------------------------------------------------------

# stored_posture: the previous posture from state/.flow-<project>, supporting
# both writers: this script's bare annotation line ("no-mistakes-prod-only
# +yolo") and the hand-flip format whose previous_registry_line= key carries
# the complete previous registry line.
stored_posture() {
  [ -f "$FLOW_STATE" ] || return 0
  local line
  line=$(grep '^previous_registry_line=' "$FLOW_STATE" 2>/dev/null | head -1) || true
  if [ -n "$line" ]; then
    printf '%s\n' "${line#previous_registry_line=}"
  else
    cat "$FLOW_STATE"
  fi
}


cmd_status() {
  local annotation main_id review_id main_enf review_enf stored verdict
  annotation=$(registry_annotation)
  local ids_tmp
  ids_tmp=$(mktemp) || die "cannot create a temp file"
  list_ruleset_ids > "$ids_tmp"
  main_id=$(discover_main_ruleset "$ids_tmp")
  review_id=$(discover_review_ruleset "$ids_tmp" "$main_id")
  rm -f "$ids_tmp"
  main_enf=$(ruleset_detail "$main_id" | jq -r '.enforcement')
  review_enf=$(ruleset_detail "$review_id" | jq -r '.enforcement')
  stored=$(stored_posture)
  verdict=DRIFT
  if [ "$main_enf" = disabled ] && [ "$review_enf" = disabled ] \
      && [ "$annotation" = "local-only +yolo" ]; then
    verdict=fast
  elif [ "$main_enf" = active ] && [ "$review_enf" = active ] \
      && [ "${annotation%% *}" = "no-mistakes-prod-only" ]; then
    verdict=full
  fi
  print_matched_ids "$main_id" "$review_id"
  printf 'registry posture: [%s]\n' "$annotation"
  printf 'main-protection ruleset %s enforcement: %s\n' "$main_id" "$main_enf"
  printf 'main-protection ruleset gates: %s\n' \
    "$(main_gate_report "$main_id")"
  printf 'review ruleset %s enforcement: %s\n' "$review_id" "$review_enf"
  printf 'stored previous posture: %s\n' "${stored:-<none>}"
  printf 'verdict: %s\n' "$verdict"
}

cmd_fast() {
  local annotation stored main_id review_id ids_tmp
  [ -n "$(registry_line)" ] || die "project \"$NAME\" has no registry line in $REG"
  annotation=$(registry_annotation)

  ids_tmp=$(mktemp) || die "cannot create a temp file"
  list_ruleset_ids > "$ids_tmp"
  main_id=$(discover_main_ruleset "$ids_tmp")
  review_id=$(discover_review_ruleset "$ids_tmp" "$main_id")
  rm -f "$ids_tmp"
  print_matched_ids "$main_id" "$review_id"

  local changed=0

  # Guard: the post-merge workflow must exist on the default branch.
  if ! guard_present; then
    if [ "$NO_GUARD" -eq 1 ]; then
      printf 'guard: post-merge workflow absent; proceeding under --no-guard (%s)\n' "$NO_GUARD_REASON"
    else
      die "the post-merge workflow (.github/workflows/main-postmerge.yml) is absent from $REPO_SLUG's default branch; fast mode's guard would be gone. Pass --no-guard <reason> to override."
    fi
  else
    printf 'guard: post-merge workflow present on the default branch\n'
  fi

  # Rulesets first: only touch the ones not already disabled (idempotence).
  # Doing the GitHub writes before the local edits means a refused write
  # leaves the registry, the stored posture, and captain.md untouched.
  local main_enf review_enf
  main_enf=$(ruleset_detail "$main_id" | jq -r '.enforcement')
  review_enf=$(ruleset_detail "$review_id" | jq -r '.enforcement')
  if [ "$main_enf" != disabled ]; then
    put_enforcement "$main_id" disabled
    changed=1
  else
    printf 'ruleset %s already disabled\n' "$main_id"
  fi
  if [ "$review_enf" != disabled ]; then
    put_enforcement "$review_id" disabled
    changed=1
  else
    printf 'ruleset %s already disabled\n' "$review_id"
  fi

  # Registry: store the complete previous line once, then flip to fast. The
  # stored file uses the same previous_registry_line= shape a hand flip writes,
  # so full always restores the line exactly.
  if [ "$annotation" != "local-only +yolo" ]; then
    printf 'previous_registry_line=%s\n' "$(registry_line)" > "$FLOW_STATE"
    rewrite_registry "local-only +yolo"
    printf 'registry: [%s] -> [local-only +yolo]\n' "$annotation"
    changed=1
  else
    printf 'registry: already [local-only +yolo]\n'
  fi

  # Push-authority line in captain.md.
  if has_push_line; then
    printf 'captain.md: push-authority line already present\n'
  else
    append_push_line
    printf 'captain.md: push-authority line appended\n'
    changed=1
  fi

  if [ "$changed" -eq 0 ]; then
    printf 'fast: no changes needed; already fast\n'
  fi

  printf 'open PRs on %s:\n' "$REPO_SLUG"
  list_open_prs
}

cmd_full() {
  local annotation stored main_id review_id ids_tmp
  [ -n "$(registry_line)" ] || die "project \"$NAME\" has no registry line in $REG"
  annotation=$(registry_annotation)
  stored=$(stored_posture)
  [ -n "$stored" ] || die "no stored previous posture at $FLOW_STATE; run fast first"

  ids_tmp=$(mktemp) || die "cannot create a temp file"
  list_ruleset_ids > "$ids_tmp"
  main_id=$(discover_main_ruleset "$ids_tmp")
  review_id=$(discover_review_ruleset "$ids_tmp" "$main_id")
  rm -f "$ids_tmp"
  print_matched_ids "$main_id" "$review_id"

  local changed=0

  # Rulesets first, then the local edits: a refused write leaves the
  # registry and captain.md untouched.
  local main_enf review_enf
  main_enf=$(ruleset_detail "$main_id" | jq -r '.enforcement')
  review_enf=$(ruleset_detail "$review_id" | jq -r '.enforcement')
  if [ "$main_enf" != active ]; then
    put_enforcement "$main_id" active
    changed=1
  else
    printf 'ruleset %s already active\n' "$main_id"
  fi
  if [ "$review_enf" != active ]; then
    put_enforcement "$review_id" active
    changed=1
  else
    printf 'ruleset %s already active\n' "$review_id"
  fi

  # The stored value is always the complete previous registry line, whether
  # written by fast or by a hand flip. Only restore when it actually differs.
  if [ "$stored" != "$(registry_line)" ]; then
    replace_registry_line "$stored"
    printf 'registry: line restored from %s\n' "$FLOW_STATE"
    changed=1
  else
    printf 'registry: already matches the stored previous line\n'
  fi

  if has_push_line; then
    remove_push_line
    printf 'captain.md: push-authority line removed\n'
    changed=1
  else
    printf 'captain.md: no push-authority line\n'
  fi

  if [ "$changed" -eq 0 ]; then
    printf 'full: no changes needed; already full\n'
  fi
}

REPO_SLUG=$(resolve_repo_slug)

case "$MODE" in
  status) cmd_status ;;
  fast)   cmd_fast ;;
  full)   cmd_full ;;
esac
