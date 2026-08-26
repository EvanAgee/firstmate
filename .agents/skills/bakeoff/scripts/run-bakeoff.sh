#!/usr/bin/env bash
# Harness bake-off runner: hand ONE identical brief to N harness/model combos,
# each in its own isolated git worktree, run headless to completion, time each,
# capture its diff + RESULT.md. No pushes, no PRs, no merges. Read-only to the
# firstmate clone's tracked files (worktrees live outside it).
#
# Usage: run-bakeoff.sh <clone-dir> <base-ref> <brief-file> <work-root> [agent-timeout-secs] [slug-filter]
#   base-ref: commit/branch to branch each worktree from (use the PRE-feature commit)
#   slug-filter: optional single slug to run just one agent (canary)
# Luna/Terra stay off the default roster. BAKEOFF_EXTRAS=1 includes them, or
# pass luna/terra as the slug filter. Both need paid OpenAI credits.
set -uo pipefail

CLONE="${1:?clone dir}"
BASE="${2:?base branch}"
BRIEF="${3:?brief file}"
ROOT="${4:?work root}"
TIMEOUT=2400
FILTER=""
if [ -n "${5:-}" ]; then
  if [[ "$5" =~ ^[0-9]+$ ]]; then
    TIMEOUT="$5"
    FILTER="${6:-}"
  else
    FILTER="$5"
  fi
fi

if [ ! -f "$BRIEF" ]; then
  echo "brief not found: $BRIEF" >&2
  exit 1
fi
BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"

mkdir -p "$ROOT"
MANIFEST="$ROOT/manifest.tsv"
if [ ! -f "$MANIFEST" ]; then
  printf 'slug\tharness\tmodel\tstatus\texit\tinstall_s\tagent_s\tfiles_changed\tinsertions\tdeletions\thas_result\n' > "$MANIFEST"
fi

# Roster: slug | harness | model | launch-template
# Launch template placeholders: {MODEL} and the brief arrives on stdin.
read -r -d '' ROSTER <<'EOF'
fable|claude|fable|claude -p --model {MODEL} --dangerously-skip-permissions
opus5|claude|claude-opus-5|claude -p --model {MODEL} --dangerously-skip-permissions
opus48|claude|claude-opus-4-8|claude -p --model {MODEL} --dangerously-skip-permissions
sonnet5|claude|claude-sonnet-5|claude -p --model {MODEL} --dangerously-skip-permissions
codex-sol|codex|gpt-5.6-sol|codex exec -m {MODEL} --dangerously-bypass-approvals-and-sandbox -
grok46|pi|xai/grok-4.6|pi --print --model {MODEL} --approve
glm53|pi|z-ai/glm-5.3-flash|pi --print --model {MODEL} --approve
kimik3|pi|chutes/moonshotai/Kimi-K3-TEE|pi --print --model {MODEL} --approve
deepseekv4|pi|chutes/deepseek-ai/DeepSeek-V4-Flash-0731-TEE|pi --print --model {MODEL} --approve
EOF

read -r -d '' EXTRA_ROSTER <<'EOF'
luna|pi|openai/gpt-5.6-luna|pi --print --model {MODEL} --approve
terra|pi|openai/gpt-5.6-terra|pi --print --model {MODEL} --approve
EOF

include_extras=0
if [ -n "${BAKEOFF_EXTRAS:-}" ]; then
  include_extras=1
elif [ -n "$FILTER" ]; then
  while IFS='|' read -r extra_slug _; do
    [ -n "$extra_slug" ] || continue
    if [ "$extra_slug" = "$FILTER" ]; then
      include_extras=1
      break
    fi
  done <<< "$EXTRA_ROSTER"
fi

ACTIVE_ROSTER="$ROSTER"
if [ "$include_extras" -eq 1 ]; then
  ACTIVE_ROSTER="${ROSTER}
${EXTRA_ROSTER}"
fi

now() { date +%s; }

# portable timeout: run_timeout <secs> <command-string> (macOS has no `timeout`)
run_timeout() {
  local secs="$1"; shift
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    if ($pid == 0) { exec("/bin/bash","-c",$ARGV[0]) or exit 127; }
    local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 3; kill "KILL", $pid; waitpid($pid,0); exit 124; };
    alarm $t;
    waitpid($pid,0);
    exit($? >> 8);
  ' "$secs" "$1"
}

manifest_has_slug() {
  local slug="$1"
  awk -F '\t' -v s="$slug" 'NR > 1 && $1 == s { found = 1; exit } END { exit !found }' "$MANIFEST"
}

append_manifest_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$MANIFEST"
}

compact_manifest() {
  local tmp
  tmp=$(mktemp)
  awk -F '\t' '
    NR == 1 { print; next }
    $1 == "" { next }
    {
      row[$1] = $0
      if (!seen[$1]++) keys[++n] = $1
    }
    END {
      for (i = 1; i <= n; i++) print row[keys[i]]
    }
  ' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

launch_one() {
  local slug="$1" harness="$2" model="$3" tmpl="$4"
  local wt="$ROOT/$slug"
  local log="$ROOT/$slug.agent.log"
  local branch="bakeoff/$slug"

  # skip a slug that already has a completed worktree (idempotent re-runs)
  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    echo "[$slug] worktree exists, skipping (already run)" >&2
    if ! manifest_has_slug "$slug"; then
      local has_result=no
      [ -f "$wt/RESULT.md" ] && has_result=yes
      append_manifest_row "$slug" "$harness" "$model" "skipped" "-" "-" "-" "-" "-" "-" "$has_result"
    fi
    return
  fi

  echo "[$slug] setting up worktree" >&2
  git -C "$CLONE" worktree add --force -b "$branch" "$wt" "$BASE" >>"$ROOT/$slug.setup.log" 2>&1 || {
    append_manifest_row "$slug" "$harness" "$model" "setup-failed" "-" "-" "-" "-" "-" "-" "no"; return; }

  # install deps (timed separately, not part of the model comparison)
  local i0 i1 istatus
  i0=$(now)
  ( cd "$wt" && pnpm install --prefer-offline >>"$ROOT/$slug.install.log" 2>&1 )
  istatus=$?
  i1=$(now)
  local install_s=$(( i1 - i0 ))
  if [ "$istatus" -ne 0 ]; then
    append_manifest_row "$slug" "$harness" "$model" "install-failed" "-" "$install_s" "-" "-" "-" "-" "no"; return
  fi

  # build launch command
  local cmd="${tmpl//\{MODEL\}/$model}"
  echo "[$slug] launching: $cmd" >&2

  local a0 a1 ex
  a0=$(now)
  # brief on stdin; run inside the worktree; hard timeout (portable)
  ( cd "$wt" && run_timeout "$TIMEOUT" "$cmd < $(printf '%q' "$BRIEF")" ) >>"$log" 2>&1
  ex=$?
  a1=$(now)
  local agent_s=$(( a1 - a0 ))

  local status="done"
  [ "$ex" -eq 124 ] && status="timeout"
  [ "$ex" -ne 0 ] && [ "$ex" -ne 124 ] && status="error"

  # capture diff stats vs the base ref, catching BOTH committed and uncommitted work
  local files ins del stat
  git -C "$wt" add -A >/dev/null 2>&1   # stage any uncommitted edits so they show in the range diff via HEAD
  # range diff: everything between the base and the working tree (committed + staged)
  stat=$(git -C "$wt" diff --shortstat "$BASE" 2>/dev/null)
  files=$(echo "$stat" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' | head -1)
  ins=$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' | head -1)
  del=$(echo "$stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' | head -1)
  [ -z "$files" ] && files=0; [ -z "$ins" ] && ins=0; [ -z "$del" ] && del=0

  # save the full diff vs base for review (committed + uncommitted)
  git -C "$wt" diff "$BASE" > "$ROOT/$slug.diff" 2>/dev/null
  local has_result=no
  [ -f "$wt/RESULT.md" ] && { cp "$wt/RESULT.md" "$ROOT/$slug.RESULT.md"; has_result=yes; }

  append_manifest_row \
    "$slug" "$harness" "$model" "$status" "$ex" "$install_s" "$agent_s" "$files" "$ins" "$del" "$has_result"
  echo "[$slug] DONE status=$status exit=$ex agent_s=$agent_s files=$files +$ins/-$del result=$has_result" >&2
}

# Launch all in parallel background jobs
pids=()
while IFS='|' read -r slug harness model tmpl; do
  [ -z "$slug" ] && continue
  [ -n "$FILTER" ] && [ "$slug" != "$FILTER" ] && continue
  launch_one "$slug" "$harness" "$model" "$tmpl" &
  pids+=("$!")
done <<< "$ACTIVE_ROSTER"

echo "launched ${#pids[@]} agents; waiting..." >&2
for p in "${pids[@]}"; do wait "$p"; done
compact_manifest
echo "ALL DONE. manifest: $MANIFEST" >&2
