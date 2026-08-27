#!/usr/bin/env bash
# Evidence runner for the duplicate-issue spawn guard. Drives real fm-spawn.sh
# with the same fake tmux/gh-axi seams as the colocated tests, and writes
# captain-visible transcripts plus recorded meta.
set -u
EVIDENCE_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M12NBH8H1CBZ578P9NHCS4NW
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
OUT="$EVIDENCE_DIR/transcripts"
META_OUT="$EVIDENCE_DIR/meta"
mkdir -p "$OUT" "$META_OUT"
TMP_ROOT=$(fm_test_tmproot fm-spawn-issue-guard-evidence)

make_guard_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  case "$a" in
    *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
    *pane_tty*) exit 0 ;;
    *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-}"; exit 0 ;;
  esac
done
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    for w in ${FM_FAKE_WINDOWS:-}; do printf '%s\n' "$w"; done
    exit 0 ;;
  has-session|new-session|new-window|kill-window)
    if [ -n "${FM_FAKE_WINDOW_LOG:-}" ]; then printf '%s\n' "$1" >> "$FM_FAKE_WINDOW_LOG"; fi
    exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
while [ "\${1:-}" = -C ]; do
  [ "\$#" -ge 2 ] || break
  shift 2
done
if [ "\${1:-}" = remote ] && [ "\${2:-}" = get-url ] && [ "\${3:-}" = origin ] \\
   && [ -n "\${FM_FAKE_GITHUB_ORIGIN:-}" ]; then
  printf '%s\n' "\$FM_FAKE_GITHUB_ORIGIN"
  exit 0
fi
exec "$real_git" "\${args[@]}"
SH
  chmod +x "$fakebin/git"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

make_guard_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_guard_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_guard_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

make_fake_gh() {
  local dir=$1 mode=$2 prfile=$3 path="$1/gh-axi"
  [ -f "$prfile" ] || : > "$prfile"
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
if [ "$mode" = down ]; then
  echo "gh-axi: connection to api.github.com failed" >&2
  exit 1
fi
case "\$*" in
  *"pr list"*)
    count=0
    [ -s "$prfile" ] && count=\$(wc -l < "$prfile" | tr -d ' ')
    printf '%s\n' "count: \$count of \$count total"
    printf '%s\n' 'pull_requests[]{number,title,state,author,draft,review,url,body}:'
    while IFS=\$(printf '\t') read -r n title body; do
      [ -n "\$n" ] || continue
      printf '  %s\n' "\$n,\"\$title\",open,octocat,no,none,\"https://github.com/acme/widget/pull/\$n\",\"\$body\""
    done < "$prfile"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

run_guard_spawn() {
  local fake_gh=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_GITHUB_ORIGIN="${FM_FAKE_GITHUB_ORIGIN:-}" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-}" \
    FM_FAKE_WINDOW_LOG="${FM_FAKE_WINDOW_LOG:-}" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$HOME_DIR/grok-home" \
    FM_GH_BIN="$fake_gh" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

seed_live_claim() {
  local task=$1 ref=$2
  fm_write_meta "$HOME_DIR/state/$task.meta" \
    "window=mysession:fm-$task" \
    "endpoint_task_id=$task" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "issues=$ref"
  FM_FAKE_WINDOWS="fm-$task"
  FM_FAKE_PANE_COMMAND=claude
}

make_case_and_env() {
  rec=$(make_guard_case "$@")
  read_guard_record "$rec"
  FM_FAKE_GITHUB_ORIGIN="https://github.com/acme/widget.git"
  FM_FAKE_WINDOWS=
  FM_FAKE_PANE_COMMAND=
  FM_FAKE_WINDOW_LOG="$CASE_DIR/window.log"
  : > "$FM_FAKE_WINDOW_LOG"
}

record_case() {
  local name=$1 cmd=$2 status=$3 out=$4
  {
    echo "=== $name ==="
    echo "command: $cmd"
    echo "exit: $status"
    echo "--- output ---"
    printf '%s\n' "$out"
    echo "--- meta ---"
    if [ -d "$HOME_DIR/state" ]; then
      for f in "$HOME_DIR/state"/*.meta; do
        [ -f "$f" ] || continue
        echo "# $(basename "$f")"
        cat "$f"
        echo
      done
    fi
    echo "--- window.log ---"
    if [ -f "${FM_FAKE_WINDOW_LOG:-}" ]; then
      cat "$FM_FAKE_WINDOW_LOG"
    else
      echo "(none)"
    fi
    echo
  } > "$OUT/$name.txt"
  if [ -d "$HOME_DIR/state" ]; then
    mkdir -p "$META_OUT/$name"
    cp "$HOME_DIR/state"/*.meta "$META_OUT/$name/" 2>/dev/null || true
  fi
}

# 1. Record normalized refs
id=issue-rec-a1
make_case_and_env issue-rec "$id"
printf '%s\n' "$(printf '5\tunrelated\tnothing to see')" > "$CASE_DIR/prs.txt"
fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
cmd="$SPAWN $id <project> --mode no-mistakes --yolo off --issue acme/other#99 --issue '#7' --issue 8"
out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
  --issue acme/other#99 --issue '#7' --issue 8)
status=$?
record_case 01-record-normalized-refs "$cmd" "$status" "$out"

# 2. No --issue leaves meta without issues=
id=issue-none-a2
make_case_and_env issue-none "$id"
printf '%s\n' "$(printf '4\tsome pr\tmentions #7 too')" > "$CASE_DIR/prs.txt"
fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
cmd="$SPAWN $id <project> --mode no-mistakes --yolo off"
out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
status=$?
record_case 02-no-issue-flag "$cmd" "$status" "$out"

# 3. Local fleet claim refuses
new_id=issue-dup-a3
make_case_and_env issue-dup issue-live-a3 "$new_id"
printf '%s\n' "$(printf '9\tother pr\tno refs')" > "$CASE_DIR/prs.txt"
fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
seed_live_claim issue-live-a3 'acme/widget#7'
cmd="$SPAWN $new_id <project> --mode no-mistakes --yolo off --issue 7"
out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
status=$?
record_case 03-local-fleet-refusal "$cmd" "$status" "$out"

# 4. Open PR claim refuses
new_id=issue-pr-a5
make_case_and_env issue-pr "$new_id"
printf '%s\n' "$(printf '4\tadd exporter\tFixes #7 by adding the export tool')" > "$CASE_DIR/prs.txt"
fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
cmd="$SPAWN $new_id <project> --mode no-mistakes --yolo off --issue '#7'"
out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue '#7')
status=$?
record_case 04-open-pr-refusal "$cmd" "$status" "$out"

# 5. Cross-repo hash does not claim
new_id=issue-pr-xrepo-a12
make_case_and_env issue-pr-xrepo "$new_id"
printf '%s\n' "$(printf '4\tblocked on infra\tDepends on acme/infra#7')" > "$CASE_DIR/prs.txt"
fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
cmd="$SPAWN $new_id <project> --mode no-mistakes --yolo off --issue '#7'"
out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue '#7')
status=$?
record_case 05-cross-repo-hash-does-not-claim "$cmd" "$status" "$out"

# 6. Same-repo slug#n still claims
new_id=issue-pr-slug-a13
make_case_and_env issue-pr-slug "$new_id"
printf '%s\n' "$(printf '4\tadd exporter\tCloses acme/widget#7 without a bare hash')" > "$CASE_DIR/prs.txt"
fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
cmd="$SPAWN $new_id <project> --mode no-mistakes --yolo off --issue '#7'"
out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue '#7')
status=$?
record_case 06-same-repo-slug-claims "$cmd" "$status" "$out"

# 7. GitHub down + local match
new_id=issue-down-a7
make_case_and_env issue-down issue-live-a7 "$new_id"
fake_gh=$(make_fake_gh "$CASE_DIR" down "$CASE_DIR/prs.txt")
seed_live_claim issue-live-a7 'acme/widget#7'
cmd="$SPAWN $new_id <project> --mode no-mistakes --yolo off --issue 7"
out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
status=$?
record_case 07-github-down-local-match "$cmd" "$status" "$out"

# 8. GitHub down, no local match proceeds
new_id=issue-down-ok-a8
make_case_and_env issue-down-ok "$new_id"
fake_gh=$(make_fake_gh "$CASE_DIR" down "$CASE_DIR/prs.txt")
cmd="$SPAWN $new_id <project> --mode no-mistakes --yolo off --issue 7"
out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
status=$?
record_case 08-github-down-no-local-match "$cmd" "$status" "$out"

# Combined captain-facing digest
{
  echo "Duplicate-issue spawn guard — captain-visible CLI evidence"
  echo "Generated by driving real bin/fm-spawn.sh with fake tmux/gh-axi."
  echo
  for f in "$OUT"/*.txt; do
    cat "$f"
    echo
  done
} > "$EVIDENCE_DIR/cli-transcript.md"

echo "wrote $EVIDENCE_DIR/cli-transcript.md"
