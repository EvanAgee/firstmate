#!/usr/bin/env bash
# fm-issue-guard-lib.sh - the spawn-time duplicate-issue guardrail, sourced by
# bin/fm-spawn.sh. A ship dispatch that names the GitHub issue(s) it covers must
# not duplicate a claim that already exists:
#   - in this home: a live task's state/<id>.meta already records the same
#     normalized issue ref, or
#   - in the repo: an open pull request (via gh-axi) claims the same
#     normalized issue ref in its title or body.
# Either claim is a hard stop for the spawn: the caller refuses before any
# worktree or endpoint is created. Refusals print one plain-English error line
# naming the exact claiming task id or PR URL.
#
# The GitHub half is deliberately fail-open on reachability and fail-closed on
# evidence: if gh-axi cannot answer, the open-PR check is reported as skipped
# (FM_ISSUE_GUARD_GH_SKIPPED=1 plus one stderr notice) and the spawn is judged
# on the local fleet scan alone; a GitHub failure never adds a claim and never
# hard-fails the spawn by itself, because local overlap is the primary case.
# A non-zero FM_ISSUE_GUARD_GH_SKIPPED notice is loud, so the caller never
# silently treats "GitHub unreachable" as "no PR claims the issue". The
# preflight also exposes the deduped normalized refs comma-separated in
# FM_ISSUE_GUARD_NORMALIZED for the caller's meta record.
#
# Normalization: a ref is `owner/repo#123`, a bare `#123`, or a bare `123`.
# Bare forms resolve against the project's GitHub origin remote (owner/repo),
# which is where the task would ship its PR. The owner/repo slug is lowercased
# so case-insensitive GitHub identities compare equal. A ref that cannot be
# normalized is a spawn refusal, not a silent pass. Matching is by the full
# normalized ref, so #123 and #124 never collide, and an owner/repo#n for a
# different repo does not claim this repo's #n. A closed or merged PR claims
# nothing: only open PRs are consulted (the list call asks for --state open).
# A torn-down task cannot linger as a claim because fm-teardown removes
# state/<id>.meta.
#
# Liveness: a matching meta claims the issue unless its recorded worker is
# authoritatively gone (fm_backend_agent_alive returns dead). alive or any
# unknown/unverified verdict keeps the claim, since a false "gone" could launch
# a duplicate worker on a live task.
#
# gh-axi seam: the binary is resolved from FM_GH_BIN (default gh-axi) at call
# time, the same override fm-outage-sync.sh uses, so tests can inject a recorder.

FM_ISSUE_GUARD_GH_SKIPPED=0
FM_ISSUE_GUARD_NORMALIZED=

if ! declare -F fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"
fi

fm_issue_guard_gh() {
  local bin=${FM_GH_BIN:-gh-axi}
  "$bin" "$@"
}

# fm_issue_guard_repo_slug <remote-url> -> owner/repo, or non-zero for a
# non-GitHub origin, which cannot address GitHub issues or PRs.
fm_issue_guard_repo_slug() {
  local url=$1
  case "$url" in
    ssh://git@github.com/*|git@github.com:*|https://github.com/*|http://github.com/*) : ;;
    *) return 1 ;;
  esac
  local path
  case "$url" in
    git@github.com:*) path=${url#git@github.com:} ;;
    *github.com/*) path=${url#*github.com/} ;;
  esac
  path=${path%/}
  path=${path%.git}
  path=${path%/}
  case "$path" in
    */*) : ;;
    *) return 1 ;;
  esac
  case "$path" in
    */*/*) return 1 ;;
  esac
  printf '%s\n' "$path"
}

# fm_issue_guard_project_slug <project-dir> -> owner/repo of the project
# checkout's origin remote, or non-zero when there is no GitHub origin.
fm_issue_guard_project_slug() {
  local dir=$1 url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  fm_issue_guard_repo_slug "$url"
}

# fm_issue_guard_normalize <project-dir> <ref> -> owner/repo#<number>.
# Prints a refusal on stderr and returns non-zero for anything that is not a
# parseable GitHub issue identity.
fm_issue_guard_normalize() {
  local dir=$1 ref=$2 slug number
  case "$ref" in
    ''|*[!0-9A-Za-z./#_-]*)
      echo "error: --issue '$ref' is not a GitHub issue ref (use owner/repo#123, #123, or 123)" >&2
      return 1
      ;;
    *#*#*)
      echo "error: --issue '$ref' is not a GitHub issue ref (use owner/repo#123, #123, or 123)" >&2
      return 1
      ;;
  esac
  case "$ref" in
    *#*)
      slug=${ref%%#*}
      number=${ref##*#}
      case "$slug" in
        '') : ;; # bare #n: resolve against the project repo below
        */*/*)
          echo "error: --issue '$ref' is not a GitHub issue ref (use owner/repo#123, #123, or 123)" >&2
          return 1
          ;;
        */*)
          [ -n "${slug%%/*}" ] && [ -n "${slug#*/}" ] || {
            echo "error: --issue '$ref' is not a GitHub issue ref (use owner/repo#123, #123, or 123)" >&2
            return 1
          }
          ;;
        *)
          echo "error: --issue '$ref' is not a GitHub issue ref (use owner/repo#123, #123, or 123)" >&2
          return 1
          ;;
      esac
      ;;
    *)
      slug=
      number=$ref
      ;;
  esac
  case "$number" in
    ''|*[!0-9]*)
      echo "error: --issue '$ref' has no issue number (use owner/repo#123, #123, or 123)" >&2
      return 1
      ;;
  esac
  if [ -z "$slug" ]; then
    if ! slug=$(fm_issue_guard_project_slug "$dir"); then
      echo "error: --issue '$ref' has no repo to resolve against: the project checkout has no github.com origin remote; pass owner/repo#$number explicitly" >&2
      return 1
    fi
  fi
  slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  printf '%s#%s\n' "$slug" "$number"
}

# fm_issue_guard_meta_records_ref <meta-file> <normalized-ref> -> non-zero when
# the meta does not record the ref in its comma-separated issues= field.
fm_issue_guard_meta_records_ref() {
  local v
  v=$(fm_meta_get "$1" issues)
  [ -n "$v" ] || return 1
  case ",$v," in
    *",$2,"*) return 0 ;;
  esac
  return 1
}

# fm_issue_guard_task_worker_alive <meta-file>: coarse worker-present verdict.
fm_issue_guard_task_worker_alive() {
  local meta=$1 backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    printf '%s\n' unknown
    return 0
  fi
  case "$(fm_backend_agent_alive "$backend" "$target")" in
    dead) printf '%s\n' dead ;;
    *) printf '%s\n' alive ;;
  esac
}

# fm_issue_guard_local_fleet_claim <state-dir> <self-task-id> <normalized-ref>
# Prints the claiming task id and returns 0 when a live task in the state dir
# records the ref; returns non-zero otherwise. The self task id is excluded so
# a relaunch never trips over its own record.
fm_issue_guard_local_fleet_claim() {
  local state=$1 self=$2 ref=$3 meta id
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" = "$self" ] && continue
    fm_issue_guard_meta_records_ref "$meta" "$ref" || continue
    case "$(fm_issue_guard_task_worker_alive "$meta")" in
      dead) continue ;;
    esac
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

# fm_issue_guard_text_claims_issue <text> <owner/repo> <issue-number>
# True when text references this repo's issue: a bare #n, or this slug#n.
# An owner/repo#n for any other slug is a different issue and does not match.
fm_issue_guard_text_claims_issue() {
  local haystack=$1 slug=$2 number=$3 lowered exploded piece
  lowered=$(printf '%s' "$haystack" | tr '[:upper:]' '[:lower:]')
  exploded=$(printf '%s' "$lowered" | sed -E 's|[[:alnum:]._-]+/[[:alnum:]._-]+#[0-9]+|\n&\n|g')
  while IFS= read -r piece; do
    [ -n "$piece" ] || continue
    case "$piece" in
      "$slug#$number") return 0 ;;
    esac
    case "$piece" in
      *[[:alnum:]._-]/*[[:alnum:]._-]#[0-9]*) continue ;;
    esac
    printf '%s\n' "$piece" | grep -Eq "#$number([^0-9]|$)" && return 0
  done <<EOF
$exploded
EOF
  return 1
}

# fm_issue_guard_open_pr_claim <owner/repo> <issue-number> -> the PR URL of an
# open PR in the repo that claims this repo's issue. Exit 0 with the URL on stdout
# for a claim, 1 for no claim, 2 when gh-axi cannot answer (check skipped, not
# a claim). Callers must not rely on FM_ISSUE_GUARD_GH_SKIPPED from inside a
# command substitution; return 2 is the subshell-safe skip signal.
# gh-axi pr list indents its data rows, so the parser trims leading space
# before taking the number; the URL is constructed from the slug and number
# because pr list's url field is optional extra data, not a required column.
fm_issue_guard_open_pr_claim() {
  local slug=$1 number=$2 list_out line trimmed pr_num
  if ! list_out=$(fm_issue_guard_gh pr list -R "$slug" --state open --limit 100 --fields url,body 2>&1); then
    return 2
  fi
  while IFS= read -r line; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      [0-9]*) pr_num=${trimmed%%,*} ;;
      *) continue ;;
    esac
    case "$pr_num" in
      ''|*[!0-9]*) continue ;;
    esac
    if fm_issue_guard_text_claims_issue "$line" "$slug" "$number"; then
      printf 'https://github.com/%s/pull/%s\n' "$slug" "$pr_num"
      return 0
    fi
  done <<EOF
$list_out
EOF
  return 1
}

# fm_issue_guard_preflight <state-dir> <project-dir> <self-task-id> <ref>...
# The one entry point fm-spawn calls after flag validation. Returns non-zero
# when the spawn must refuse; prints one plain-English error per claiming task
# or PR, plus the skip notice when the open-PR check could not run.
fm_issue_guard_preflight() {
  local state=$1 proj=$2 self=$3
  shift 3
  [ "$#" -gt 0 ] || return 0
  local -a refs=()
  local raw ref fleet_claim='' fleet_ref='' pr_claim='' pr_ref='' slug number pr_rc
  for raw in "$@"; do
    ref=$(fm_issue_guard_normalize "$proj" "$raw") || return 1
    case " ${refs[*]-} " in
      *" $ref "*) continue ;;
    esac
    refs+=("$ref")
  done
  for ref in "${refs[@]}"; do
    if fleet_claim=$(fm_issue_guard_local_fleet_claim "$state" "$self" "$ref"); then
      fleet_ref=$ref
      break
    fi
  done
  FM_ISSUE_GUARD_GH_SKIPPED=0
  # shellcheck disable=SC2034 # fm-spawn.sh reads this after a successful preflight
  FM_ISSUE_GUARD_NORMALIZED=$(IFS=,; printf '%s' "${refs[*]}")
  for ref in "${refs[@]}"; do
    [ "$FM_ISSUE_GUARD_GH_SKIPPED" -eq 0 ] || break
    slug=${ref%%#*}
    number=${ref##*#}
    pr_rc=0
    pr_claim=$(fm_issue_guard_open_pr_claim "$slug" "$number") || pr_rc=$?
    case "$pr_rc" in
      0) pr_ref=$ref; break ;;
      2) FM_ISSUE_GUARD_GH_SKIPPED=1; break ;;
    esac
  done
  if [ -n "$fleet_claim" ]; then
    echo "error: spawn refused: issue $fleet_ref is already claimed by live task $fleet_claim in this home; resolve or tear down that task before dispatching another worker on it" >&2
  fi
  if [ -n "$pr_claim" ]; then
    echo "error: spawn refused: issue $pr_ref is already referenced by open PR $pr_claim; dispatch only after that PR merges or closes" >&2
  fi
  if [ "$FM_ISSUE_GUARD_GH_SKIPPED" -eq 1 ]; then
    echo "notice: open-PR duplicate check could not reach GitHub and was skipped; the spawn is clear only against this home's local fleet, not against open PRs in ${refs[0]%%#*}" >&2
  fi
  [ -z "$fleet_claim" ] && [ -z "$pr_claim" ]
}
