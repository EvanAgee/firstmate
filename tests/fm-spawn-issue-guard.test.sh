#!/usr/bin/env bash
# Behavior tests for the duplicate-issue spawn guardrail in fm-spawn.sh
# (bin/fm-issue-guard-lib.sh).
#
# These tests drive the real fm-spawn with a fake tmux pane, a fake gh-axi
# recorder (via the FM_GH_BIN seam), and a fixture firstmate home. Refusal
# cases assert the spawn exits non-zero with no new meta and no endpoint
# window created; success cases assert the recorded issues= field.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-issue-guard)

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
  # The guard resolves bare #n refs against the project's origin URL, while the
  # spawn's own worktree base freshen still fetches a real (local) origin. The
  # shim serves the GitHub URL for `remote get-url origin` only (including the
  # `git -C <dir> ...` form spawn and the lib actually use); everything else
  # delegates to the real git via its absolute path so PATH cannot recurse.
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

# make_guard_case <name> <task-id>...: fixture home with a GitHub-origin project
# and a brief per task id. Prints "case_dir|home|proj|wt|fakebin".
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

# make_fake_gh <dir> <mode> <pr-file>: fake gh-axi for the guard's calls.
# pr-file lines are "number<TAB>title<TAB>body"; modes: ok | down.
# List rows are indented like real gh-axi so the production parser's trim is
# exercised; body rides on the list line because the guard uses --fields body.
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

# run_guard_spawn <fake-gh> <cmd...>: run fm-spawn against the current fixture.
# The caller must set the guard fixture vars first: HOME_DIR, PROJ_DIR, WT_DIR,
# FAKEBIN_DIR, plus FM_FAKE_GITHUB_ORIGIN and the optional FM_FAKE_WINDOWS /
# FM_FAKE_PANE_COMMAND liveness signals and FM_FAKE_WINDOW_LOG.
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

# seed_live_claim <task> <ref>: write a claimed ship task meta whose window the
# fake tmux reports as running an agent, so fm_backend_agent_alive says alive.
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

test_issue_ref_recorded_and_bare_resolved() {
  local id out status
  id=issue-rec-a1
  make_case_and_env issue-rec "$id"
  printf '%s\n' "$(printf '5\tunrelated\tnothing to see')" > "$CASE_DIR/prs.txt"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --issue acme/other#99 --issue '#7' --issue 8)
  status=$?
  expect_code 0 "$status" "spawn with --issue should succeed"
  assert_grep 'issues=acme/other#99,acme/widget#7,acme/widget#8' "$HOME_DIR/state/$id.meta" \
    "meta must record normalized refs with bare refs resolved against the project repo"
  pass "repeated and bare --issue refs normalize into the meta record"
}

test_no_issue_flag_keeps_meta_unchanged() {
  local id out status
  id=issue-none-a2
  make_case_and_env issue-none "$id"
  printf '%s\n' "$(printf '4\tsome pr\tmentions #7 too')" > "$CASE_DIR/prs.txt"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without --issue should behave as before"
  if grep -q '^issues=' "$HOME_DIR/state/$id.meta"; then
    fail "no-flag spawn must not record an issues= field"
  fi
  pass "no --issue means no issues= meta field and no duplicate check"
}

# make_case_and_env <name> <task-id> [more-ids]: build the fixture and set the
# guard env. Extra ids get briefs so a spawn that names a different task than
# the seeded live claim still has instructions. Tests then create their fake
# gh with make_fake_gh after writing prs.txt.
make_case_and_env() {
  rec=$(make_guard_case "$@")
  read_guard_record "$rec"
  FM_FAKE_GITHUB_ORIGIN="https://github.com/acme/widget.git"
  FM_FAKE_WINDOWS=
  FM_FAKE_PANE_COMMAND=
  FM_FAKE_WINDOW_LOG="$CASE_DIR/window.log"
  : > "$FM_FAKE_WINDOW_LOG"
}

test_local_fleet_claim_refuses() {
  local fake_gh new_id out status
  new_id=issue-dup-a3
  make_case_and_env issue-dup issue-live-a3 "$new_id"
  printf '%s\n' "$(printf '9\tother pr\tno refs')" > "$CASE_DIR/prs.txt"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
  seed_live_claim issue-live-a3 'acme/widget#7'

  out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
  status=$?
  expect_code 1 "$status" "spawn on a locally claimed issue must refuse"
  assert_contains "$out" "issue-live-a3" "refusal must name the claiming task id"
  [ ! -e "$HOME_DIR/state/$new_id.meta" ] || fail "refused spawn must not create the task meta"
  [ ! -s "$FM_FAKE_WINDOW_LOG" ] || fail "refused spawn must not create any endpoint window"
  pass "a live task's recorded issue hard-stops a second spawn, naming the task"
}

test_dead_worker_does_not_claim() {
  local fake_gh new_id out status
  new_id=issue-dead-a4
  make_case_and_env issue-dead issue-gone-a4 "$new_id"
  printf '%s\n' "$(printf '9\tother pr\tno refs')" > "$CASE_DIR/prs.txt"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")
  seed_live_claim issue-gone-a4 'acme/widget#7'
  # With no window in the fake session inventory, the recorded endpoint is
  # authoritatively absent: the worker is gone, so the claim must not block.
  FM_FAKE_WINDOWS=
  FM_FAKE_PANE_COMMAND=

  out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
  status=$?
  expect_code 0 "$status" "a dead worker's claim must not refuse the spawn"
  assert_grep 'issues=acme/widget#7' "$HOME_DIR/state/$new_id.meta" "spawn should record its own claim"
  pass "an authoritatively dead worker does not keep the issue claimed"
}

test_open_pr_claim_refuses() {
  local fake_gh new_id out status
  new_id=issue-pr-a5
  make_case_and_env issue-pr "$new_id"
  printf '%s\n' "$(printf '4\tadd exporter\tFixes #7 by adding the export tool')" > "$CASE_DIR/prs.txt"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue '#7')
  status=$?
  expect_code 1 "$status" "spawn on an issue referenced by an open PR must refuse"
  assert_contains "$out" "https://github.com/acme/widget/pull/4" "refusal must name the claiming PR URL"
  [ ! -e "$HOME_DIR/state/$new_id.meta" ] || fail "refused spawn must not create the task meta"
  pass "an open PR referencing the issue hard-stops the spawn, naming the PR URL"
}

test_unrelated_pr_number_does_not_claim() {
  local fake_gh new_id out status
  new_id=issue-pr-wrong-a6
  make_case_and_env issue-pr-wrong "$new_id"
  printf '%s\n' "$(printf '4\tnearby number\tFixes #70 instead')" > "$CASE_DIR/prs.txt"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue '#7')
  status=$?
  expect_code 0 "$status" "#70 in a PR body must not claim issue #7"
  pass "issue-number matching is exact, not a prefix match"
}

test_github_down_refuses_on_local_match_and_reports_skip() {
  local fake_gh new_id out status
  new_id=issue-down-a7
  make_case_and_env issue-down issue-live-a7 "$new_id"
  fake_gh=$(make_fake_gh "$CASE_DIR" down "$CASE_DIR/prs.txt")
  seed_live_claim issue-live-a7 'acme/widget#7'

  out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
  status=$?
  expect_code 1 "$status" "GitHub unreachability must not override a local fleet match"
  assert_contains "$out" "issue-live-a7" "refusal must still name the claiming task"
  assert_contains "$out" "skipped" "refusal must report the PR check was skipped"
  [ ! -e "$HOME_DIR/state/$new_id.meta" ] || fail "refused spawn must not create the task meta"
  pass "with GitHub down, a local fleet match still refuses and the skip is loud"
}

test_github_down_proceeds_without_local_match_and_reports_skip() {
  local fake_gh new_id out status
  new_id=issue-down-ok-a8
  make_case_and_env issue-down-ok "$new_id"
  fake_gh=$(make_fake_gh "$CASE_DIR" down "$CASE_DIR/prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$new_id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
  status=$?
  expect_code 0 "$status" "GitHub unreachability alone must not hard-fail the spawn"
  assert_contains "$out" "skipped" "proceeding spawn must say the PR check was skipped"
  assert_grep 'issues=acme/widget#7' "$HOME_DIR/state/$new_id.meta" "spawn should record its claim"
  pass "GitHub down with no local match proceeds with a loud skip notice"
}

test_issue_refused_on_scout_and_relaunch() {
  local fake_gh id out status
  id=issue-scout-a9
  make_case_and_env issue-scout "$id"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/no-prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --scout --issue 7)
  status=$?
  expect_code 1 "$status" "scout spawn must refuse --issue"
  assert_contains "$out" "--issue applies only to ship spawns" "scout refusal message"
  out=$(run_guard_spawn "$fake_gh" "$id" --relaunch --issue 7)
  status=$?
  expect_code 1 "$status" "relaunch must refuse --issue"
  assert_contains "$out" "--relaunch keeps the task's recorded issues" "relaunch refusal message"
  pass "--issue is scoped to ship dispatch"
}

test_invalid_ref_refuses() {
  local fake_gh id out status
  id=issue-bad-a10
  make_case_and_env issue-bad "$id"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/no-prs.txt")

  out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 'acme#7')
  status=$?
  expect_code 1 "$status" "a ref without owner/repo or bare form must refuse"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not create the task meta"
  pass "unparseable issue refs refuse the spawn"
}

test_issue_refused_when_no_github_origin() {
  local fake_gh id out status
  id=issue-noorigin-a11
  make_case_and_env issue-noorigin "$id"
  fake_gh=$(make_fake_gh "$CASE_DIR" ok "$CASE_DIR/no-prs.txt")
  # No GitHub URL served for `remote get-url origin`: the shim delegates and
  # the fixture's real origin is a local bare clone, so a bare #n has no repo
  # to resolve against and must refuse rather than guess.
  unset FM_FAKE_GITHUB_ORIGIN

  out=$(run_guard_spawn "$fake_gh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --issue 7)
  status=$?
  expect_code 1 "$status" "a bare ref with no github.com origin must refuse"
  assert_contains "$out" "owner/repo#7 explicitly" "refusal should suggest the explicit form"
  pass "a bare ref that cannot be resolved against the project refuses rather than guessing"
}

test_issue_ref_recorded_and_bare_resolved
test_no_issue_flag_keeps_meta_unchanged
test_local_fleet_claim_refuses
test_dead_worker_does_not_claim
test_open_pr_claim_refuses
test_unrelated_pr_number_does_not_claim
test_github_down_refuses_on_local_match_and_reports_skip
test_github_down_proceeds_without_local_match_and_reports_skip
test_issue_refused_on_scout_and_relaunch
test_invalid_ref_refuses
test_issue_refused_when_no_github_origin

echo "# all fm-spawn-issue-guard tests passed"
