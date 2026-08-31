#!/usr/bin/env bash
# Discover and arm missing PR watches without relying on firstmate to notice a
# status line.
# Usage: fm-pr-autoarm.sh sweep
#        fm-pr-autoarm.sh announce <task-id> <status-line>
#
# sweep resumes through ordinary task metadata without pr=, resolves the exact
# upstream branch from each recorded worktree, and checks that branch's forge.
# One exact match is armed through fm-pr-check.sh, no matches and forge errors
# stay silent, and local ambiguity prints one wake line.
# announce extracts one canonical GitHub PR or GitLab MR URL from the supplied
# status line and arms it through the same path. Existing pr= metadata is always
# left alone.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PR_CHECK_BIN="${FM_PR_CHECK_BIN:-$SCRIPT_DIR/fm-pr-check.sh}"
LOOKUP_TIMEOUT=${FM_PR_AUTOARM_LOOKUP_TIMEOUT:-2}
SWEEP_BUDGET=${FM_PR_AUTOARM_SWEEP_BUDGET:-20}
SWEEP_CURSOR="$STATE/.pr-autoarm-sweep-cursor"

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

case "$LOOKUP_TIMEOUT" in
  ''|*[!0-9]*|0) LOOKUP_TIMEOUT=2 ;;
esac
case "$SWEEP_BUDGET" in
  ''|*[!0-9]*|0) SWEEP_BUDGET=20 ;;
esac

FM_PR_AUTOARM_PROVIDER=
FM_PR_AUTOARM_HOST=
FM_PR_AUTOARM_PATH=
FM_PR_AUTOARM_URL=
FM_PR_AUTOARM_COUNT=0
FM_PR_AUTOARM_AMBIGUITIES=

fm_pr_autoarm_meta_has_pr() {
  grep -q '^pr=' "$1" 2>/dev/null
}

fm_pr_autoarm_meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_pr_autoarm_note() {
  local task=$1 reason=$2 entry
  entry="task=$task $reason"
  if [ -n "$FM_PR_AUTOARM_AMBIGUITIES" ]; then
    FM_PR_AUTOARM_AMBIGUITIES="$FM_PR_AUTOARM_AMBIGUITIES; $entry"
  else
    FM_PR_AUTOARM_AMBIGUITIES=$entry
  fi
}

fm_pr_autoarm_remote_parse() {
  local url=$1 authority path host
  FM_PR_AUTOARM_PROVIDER=
  FM_PR_AUTOARM_HOST=
  FM_PR_AUTOARM_PATH=
  case "$url" in
    git@*:*)
      authority=${url#git@}
      host=${authority%%:*}
      path=${authority#*:}
      ;;
    ssh://git@*/*)
      authority=${url#ssh://git@}
      host=${authority%%/*}
      path=${authority#*/}
      ;;
    https://*/*|http://*/*)
      authority=${url#*://}
      host=${authority%%/*}
      path=${authority#*/}
      ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [ -n "$host" ] && [ -n "$path" ] || return 1
  if [ "$host" = github.com ]; then
    fm_pr_url_parse "https://github.com/$path/pull/1" || return 1
    [ "$FM_PR_PROVIDER" = github ] || return 1
    FM_PR_AUTOARM_PROVIDER=github
    FM_PR_AUTOARM_HOST=github.com
    FM_PR_AUTOARM_PATH=$FM_PR_PATH
    return 0
  fi
  fm_pr_gitlab_host_valid "$host" || return 1
  fm_pr_gitlab_path_valid "$path" || return 1
  FM_PR_AUTOARM_PROVIDER=gitlab
  FM_PR_AUTOARM_HOST=$host
  FM_PR_AUTOARM_PATH=$path
}

fm_pr_autoarm_lookup() {
  local provider=$1 host=$2 path=$3 branch=$4 output raw url head_path head_branch extra count=0 owner encoded_path
  FM_PR_AUTOARM_URL=
  FM_PR_AUTOARM_COUNT=0
  case "$provider" in
    github)
      command -v gh >/dev/null 2>&1 || return 2
      owner=${path%%/*}
      output=$(fm_run_timed "$LOOKUP_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
        gh api --method GET "repos/$path/pulls" \
        -f state=open -f "head=$owner:$branch" -f per_page=2 \
        --jq '.[] | [.html_url, .head.repo.full_name, .head.ref] | @tsv' \
        2>/dev/null </dev/null) || return 2
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || return 2
      encoded_path=${path//\//%2F}
      raw=$(fm_run_timed "$LOOKUP_TIMEOUT" glab api --hostname "$host" --paginate \
        --method GET "projects/$encoded_path/merge_requests" \
        --raw-field state=opened --raw-field "source_branch=$branch" \
        --raw-field per_page=100 2>/dev/null </dev/null) || return 2
      # shellcheck disable=SC2016
      output=$(printf '%s' "$raw" | perl -MJSON::PP -e '
        local $/;
        my $text = <STDIN>;
        my $branch = shift;
        my $json = JSON::PP->new;
        while ($text =~ /\S/) {
          $text =~ s/^\s+//;
          my ($page, $used) = $json->decode_prefix($text);
          die "invalid page" unless ref($page) eq "ARRAY" && $used;
          substr($text, 0, $used, "");
          for my $mr (@$page) {
            die "invalid merge request" unless ref($mr) eq "HASH"
              && defined($mr->{web_url})
              && defined($mr->{source_branch})
              && defined($mr->{source_project_id})
              && defined($mr->{target_project_id});
            next unless $mr->{source_branch} eq $branch;
            next unless "$mr->{source_project_id}" eq "$mr->{target_project_id}";
            print "$mr->{web_url}\n";
          }
        }
      ' "$branch") || return 2
      ;;
    *) return 3 ;;
  esac
  while IFS= read -r raw || [ -n "$raw" ]; do
    url=$raw
    head_path=
    head_branch=
    extra=
    if [ "$provider" = github ]; then
      IFS=$'\t' read -r url head_path head_branch extra <<< "$raw"
      [ -n "$url" ] && [ -n "$head_path" ] && [ -n "$head_branch" ] \
        && [ -z "$extra" ] || return 2
      [ "$(printf '%s' "$head_path" | tr '[:upper:]' '[:lower:]')" \
        = "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" ] || return 2
      [ "$head_branch" = "$branch" ] || return 2
    fi
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || return 2
    [ "$FM_PR_PROVIDER" = "$provider" ] || return 2
    [ "$FM_PR_HOST" = "$host" ] || return 2
    if [ "$provider" = github ]; then
      [ "$(printf '%s' "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')" \
        = "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" ] || return 2
    else
      [ "$FM_PR_PATH" = "$path" ] || return 2
    fi
    count=$((count + 1))
    [ "$count" -ne 1 ] || FM_PR_AUTOARM_URL=$FM_PR_URL
  done <<EOF
$output
EOF
  FM_PR_AUTOARM_COUNT=$count
}

fm_pr_autoarm_arm() {
  local task=$1 url=$2
  "$PR_CHECK_BIN" --only-if-unarmed "$task" "$url" >/dev/null 2>&1
}

fm_pr_autoarm_cursor_write() {
  local task=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.pr-autoarm-sweep.XXXXXX") || return 1
  if ! printf '%s\n' "$task" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$SWEEP_CURSOR"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_pr_autoarm_sweep_one() {
  local meta=$1 task worktree ref record record_ref remote upstream_ref branch remote_url lookup_rc
  task=$(basename "$meta" .meta)
  fm_pr_task_id_valid "$task" || return 0
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    fm_pr_autoarm_note "$task" "metadata is unreadable"
    return 0
  fi
  fm_pr_autoarm_meta_has_pr "$meta" && return 0
  [ "$(fm_pr_autoarm_meta_field "$meta" kind)" != secondmate ] || return 0
  worktree=$(fm_pr_autoarm_meta_field "$meta" worktree)
  if [ -z "$worktree" ] || [ ! -d "$worktree" ] || [ -L "$worktree" ]; then
    fm_pr_autoarm_note "$task" "worktree is missing or unreadable"
    return 0
  fi
  ref=$(git -C "$worktree" symbolic-ref --quiet HEAD 2>/dev/null) || {
    fm_pr_autoarm_note "$task" "has no resolvable branch"
    return 0
  }
  case "$ref" in
    refs/heads/*) ;;
    *)
      fm_pr_autoarm_note "$task" "has no resolvable branch"
      return 0
      ;;
  esac
  record=$(git -C "$worktree" for-each-ref \
    --format='%(refname)%09%(upstream:remotename)%09%(upstream:remoteref)' "$ref" 2>/dev/null | head -1)
  IFS=$'\t' read -r record_ref remote upstream_ref <<< "$record"
  if [ "$record_ref" != "$ref" ] || [ -z "$remote" ] || [ "$remote" = . ]; then
    fm_pr_autoarm_note "$task" "branch ${ref#refs/heads/} has no upstream"
    return 0
  fi
  case "$upstream_ref" in
    refs/heads/*) branch=${upstream_ref#refs/heads/} ;;
    *)
      fm_pr_autoarm_note "$task" "branch ${ref#refs/heads/} has no upstream"
      return 0
      ;;
  esac
  remote_url=$(git -C "$worktree" remote get-url "$remote" 2>/dev/null) || {
    fm_pr_autoarm_note "$task" "upstream remote is unreadable"
    return 0
  }
  if ! fm_pr_autoarm_remote_parse "$remote_url"; then
    fm_pr_autoarm_note "$task" "upstream forge is unreadable"
    return 0
  fi
  lookup_rc=0
  fm_pr_autoarm_lookup "$FM_PR_AUTOARM_PROVIDER" "$FM_PR_AUTOARM_HOST" \
    "$FM_PR_AUTOARM_PATH" "$branch" || lookup_rc=$?
  case "$lookup_rc" in
    0) ;;
    *) return 0 ;;
  esac
  case "$FM_PR_AUTOARM_COUNT" in
    0) return 0 ;;
    1)
      if ! fm_pr_autoarm_meta_has_pr "$meta" \
        && ! fm_pr_autoarm_arm "$task" "$FM_PR_AUTOARM_URL"; then
        fm_pr_autoarm_note "$task" "could not arm $FM_PR_AUTOARM_URL"
      fi
      ;;
    *) fm_pr_autoarm_note "$task" "has more than one open PR for branch $branch" ;;
  esac
}

fm_pr_autoarm_sweep() {
  local meta task cursor='' resume=1 started=$SECONDS processed=0 last_task='' exhausted=0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  if [ -f "$SWEEP_CURSOR" ] && [ ! -L "$SWEEP_CURSOR" ]; then
    cursor=$(sed -n '1p' "$SWEEP_CURSOR" 2>/dev/null || true)
    fm_pr_task_id_valid "$cursor" || cursor=
  fi
  if [ -n "$cursor" ] && { [ -e "$STATE/$cursor.meta" ] || [ -L "$STATE/$cursor.meta" ]; }; then
    resume=0
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    last_task=$(basename "$meta" .meta)
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    task=$(basename "$meta" .meta)
    if [ "$resume" -eq 0 ]; then
      [ "$task" != "$cursor" ] || resume=1
      continue
    fi
    if ! fm_pr_autoarm_cursor_write "$task"; then
      fm_pr_autoarm_note "$task" "could not save sweep progress"
      exhausted=1
      break
    fi
    fm_pr_autoarm_sweep_one "$meta"
    processed=$((processed + 1))
    if [ "$processed" -gt 0 ] && [ $((SECONDS - started)) -ge "$SWEEP_BUDGET" ] \
      && [ "$task" != "$last_task" ]; then
      exhausted=1
      break
    fi
  done
  [ "$exhausted" -eq 1 ] || rm -f -- "$SWEEP_CURSOR"
  [ -z "$FM_PR_AUTOARM_AMBIGUITIES" ] \
    || printf 'pr-autoarm: %s\n' "$FM_PR_AUTOARM_AMBIGUITIES"
}

fm_pr_autoarm_announce() {
  local task=$1 line=$2 meta candidate urls='' count=0 url=''
  fm_pr_task_id_valid "$task" || return 0
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  fm_pr_autoarm_meta_has_pr "$meta" && return 0
  [ "$(fm_pr_autoarm_meta_field "$meta" kind)" != secondmate ] || return 0
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    [ -n "$candidate" ] || continue
    while :; do
      case "$candidate" in
        *'>'|*')'|*']'|*'}'|*','|*'.'|*';'|*':'|*'!') candidate=${candidate%?} ;;
        *) break ;;
      esac
    done
    fm_pr_url_parse "$candidate" || continue
    if ! printf '%s\n' "$urls" | grep -Fqx "$FM_PR_URL"; then
      urls="${urls}${FM_PR_URL}"$'\n'
      count=$((count + 1))
      url=$FM_PR_URL
    fi
  done < <(printf '%s\n' "$line" | grep -Eo 'https://[^[:space:]]+' || true)
  [ "$count" -eq 1 ] || return 0
  fm_pr_autoarm_arm "$task" "$url"
}

case "${1:-}" in
  sweep)
    [ "$#" -eq 1 ] || { echo "error: invalid PR autoarm request" >&2; exit 2; }
    fm_pr_autoarm_sweep
    ;;
  announce)
    [ "$#" -eq 3 ] || { echo "error: invalid PR autoarm request" >&2; exit 2; }
    fm_pr_autoarm_announce "$2" "$3"
    ;;
  *)
    echo "error: invalid PR autoarm request" >&2
    exit 2
    ;;
esac
