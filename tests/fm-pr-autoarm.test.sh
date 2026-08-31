#!/usr/bin/env bash
# Behavioral tests for announcement and exact-worktree-branch PR auto-arming.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTOARM="$ROOT/bin/fm-pr-autoarm.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-autoarm)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_case() {
  local name=$1 provider=${2:-github} kind=${3:-ship} dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home/state" "$dir/wt"
  fm_git_init_commit "$dir/wt"
  git -C "$dir/wt" checkout -qb actual-feature
  case "$provider" in
    github) git -C "$dir/wt" remote add origin https://github.com/acme/widget.git ;;
    gitlab) git -C "$dir/wt" remote add origin git@gitlab.example:group/subgroup/widget.git ;;
  esac
  git -C "$dir/wt" config branch.actual-feature.remote origin
  git -C "$dir/wt" config branch.actual-feature.merge refs/heads/actual-feature
  fm_write_meta "$dir/home/state/different-task.meta" \
    "worktree=$dir/wt" \
    "kind=$kind" \
    'mode=no-mistakes'

  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_FORGE_LOG"
case "${FM_TEST_FORGE_RESULT:-zero}" in
  zero) ;;
  one) printf '%s\n' 'https://github.com/acme/widget/pull/41' ;;
  two)
    printf '%s\n' 'https://github.com/acme/widget/pull/41'
    printf '%s\n' 'https://github.com/acme/widget/pull/42'
    ;;
  malformed) printf '%s\n' 'https://github.com/other/repo/pull/9' ;;
  fail) exit 1 ;;
esac
SH
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_FORGE_LOG"
case "${FM_TEST_FORGE_RESULT:-zero}" in
  zero) ;;
  one) printf '%s\n' 'https://gitlab.example/group/subgroup/widget/-/merge_requests/17' ;;
  two)
    printf '%s\n' 'https://gitlab.example/group/subgroup/widget/-/merge_requests/17'
    printf '%s\n' 'https://gitlab.example/group/subgroup/widget/-/merge_requests/18'
    ;;
  fail) exit 1 ;;
esac
SH
  cat > "$dir/arm" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FM_TEST_ARM_LOG"
printf 'pr=%s\n' "$2" >> "$FM_STATE_OVERRIDE/$1.meta"
SH
  chmod +x "$fakebin/gh" "$fakebin/glab" "$dir/arm"
  : > "$dir/forge.log"
  : > "$dir/arm.log"
  printf '%s\n' "$dir"
}

run_sweep() {
  local dir=$1 result=$2
  FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PR_CHECK_BIN="$dir/arm" \
    FM_TEST_FORGE_LOG="$dir/forge.log" \
    FM_TEST_ARM_LOG="$dir/arm.log" \
    FM_TEST_FORGE_RESULT="$result" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$AUTOARM" sweep
}

run_real_sweep() {
  local dir=$1 result=$2
  FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_TEST_FORGE_LOG="$dir/forge.log" \
    FM_TEST_FORGE_RESULT="$result" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$AUTOARM" sweep
}

dir=$(make_case single)
out=$(run_sweep "$dir" one)
[ -z "$out" ] || fail "one open PR should arm silently: $out"
grep -qxF 'different-task https://github.com/acme/widget/pull/41' "$dir/arm.log" \
  || fail "one open PR did not use the existing arm path"
grep -q -- '--head actual-feature' "$dir/forge.log" \
  || fail "sweep did not query the worktree branch"
case "$(cat "$dir/forge.log")" in *different-task*) fail "sweep queried by task-name similarity" ;; esac
pass "one open PR arms silently from the exact worktree branch"

dir=$(make_case real-arm)
out=$(run_real_sweep "$dir" one)
[ -z "$out" ] || fail "the real arm path should stay silent: $out"
grep -qxF 'pr=https://github.com/acme/widget/pull/41' "$dir/home/state/different-task.meta" \
  || fail "the sweep did not record the PR through fm-pr-check.sh"
[ -f "$dir/home/state/different-task.check.sh" ] \
  || fail "the sweep did not publish the existing merge poll"
[ -f "$dir/home/state/different-task.pr-poll-registration" ] \
  || fail "the sweep bypassed the existing poll registration"
pass "the sweep reuses fm-pr-check.sh and its registered merge poll"

dir=$(make_case zero)
out=$(run_sweep "$dir" zero)
[ -z "$out" ] || fail "zero open PRs should be silent: $out"
[ ! -s "$dir/arm.log" ] || fail "zero open PRs armed a watch"
pass "zero open PRs is a silent no-op"

dir=$(make_case ambiguous)
out=$(run_sweep "$dir" two)
case "$out" in
  *'task=different-task'*'more than one open PR for branch actual-feature'*) ;;
  *) fail "two open PRs did not name the ambiguous task and branch: $out" ;;
esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "an ambiguous sweep printed more than one wake line"
[ ! -s "$dir/arm.log" ] || fail "an ambiguous branch armed a guessed PR"
pass "two open PRs escalates once without arming"

dir=$(make_case missing)
rm -rf "$dir/wt"
out=$(run_sweep "$dir" zero)
case "$out" in *'task=different-task worktree is missing or unreadable'*) ;; *) fail "missing worktree was not surfaced: $out" ;; esac
[ ! -s "$dir/arm.log" ] || fail "missing worktree armed a PR"
pass "a missing worktree escalates without arming"

dir=$(make_case forge-failure)
out=$(run_sweep "$dir" fail)
[ -z "$out" ] || fail "forge failure should be a silent skip: $out"
[ ! -s "$dir/arm.log" ] || fail "forge failure armed a PR"
pass "forge failure is a silent skip"

dir=$(make_case prearmed)
printf '%s\n' 'pr=https://github.com/acme/widget/pull/40' >> "$dir/home/state/different-task.meta"
out=$(run_sweep "$dir" one)
[ -z "$out" ] || fail "an armed task should be skipped silently: $out"
[ ! -s "$dir/forge.log" ] || fail "an armed task reached the forge"
[ ! -s "$dir/arm.log" ] || fail "an armed task was re-armed"
pass "a task with pr= is skipped entirely"

dir=$(make_case idempotent)
run_sweep "$dir" one >/dev/null
run_sweep "$dir" one >/dev/null
[ "$(wc -l < "$dir/arm.log" | tr -d ' ')" -eq 1 ] || fail "repeat sweeps re-armed the task"
[ "$(wc -l < "$dir/forge.log" | tr -d ' ')" -eq 1 ] || fail "repeat sweeps re-queried an armed task"
pass "arming is idempotent across watcher cycles"

dir=$(make_case scout github scout)
out=$(run_sweep "$dir" one)
[ -z "$out" ] || fail "a scout PR should arm silently: $out"
[ -s "$dir/arm.log" ] || fail "a non-ship in-flight task was skipped"
pass "a non-ship in-flight task is still caught"

dir=$(make_case gitlab gitlab)
out=$(run_sweep "$dir" one)
[ -z "$out" ] || fail "one GitLab MR should arm silently: $out"
grep -qxF 'different-task https://gitlab.example/group/subgroup/widget/-/merge_requests/17' "$dir/arm.log" \
  || fail "GitLab MR did not use the existing arm path"
grep -q -- '--source-branch actual-feature' "$dir/forge.log" \
  || fail "GitLab lookup did not use the exact upstream branch"
pass "GitLab merge requests use the same exact-branch arm path"

dir=$(make_case no-upstream)
git -C "$dir/wt" config --unset branch.actual-feature.remote
git -C "$dir/wt" config --unset branch.actual-feature.merge
out=$(run_sweep "$dir" zero)
case "$out" in *'task=different-task branch actual-feature has no upstream'*) ;; *) fail "missing upstream was not surfaced: $out" ;; esac
[ ! -s "$dir/forge.log" ] || fail "a branch without an upstream reached the forge"
pass "a branch without an upstream escalates without guessing"

dir=$(make_case watcher-cycle)
watch_out="$dir/watch.out"
FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_PR_CHECK_BIN="$dir/arm" \
  FM_TEST_FORGE_LOG="$dir/forge.log" \
  FM_TEST_ARM_LOG="$dir/arm.log" \
  FM_TEST_FORGE_RESULT=one \
  FM_GH_HEALTH_PROBE_CMD=true \
  FM_CHECK_INTERVAL=2 \
  FM_HEARTBEAT=999999 \
  FM_SIGNAL_GRACE=0 \
  FM_POLL=0.1 \
  PATH="$dir/fakebin:$BASE_PATH" \
  "$WATCH" > "$watch_out" &
watch_pid=$!
sleep 0.5
if [ -s "$dir/arm.log" ]; then
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  fail "the branch sweep ran on the watcher hot path"
fi
i=0
while [ "$i" -lt 60 ] && [ ! -s "$dir/arm.log" ] && kill -0 "$watch_pid" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
watch_live=0
kill -0 "$watch_pid" 2>/dev/null && watch_live=1
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
[ "$watch_live" -eq 1 ] || fail "the watcher exited while its silent sweep was due: $(cat "$watch_out")"
[ -s "$dir/arm.log" ] || fail "the watcher never ran the delayed branch sweep"
[ ! -s "$watch_out" ] || fail "a successful watcher sweep printed a wake: $(cat "$watch_out")"
pass "the watcher runs the silent sweep on its delayed check cadence"

dir=$(make_case announcement)
printf '%s\n' 'done: PR https://github.com/acme/widget/pull/88 checks green' > "$dir/home/state/different-task.status"
FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_PR_CHECK_BIN="$dir/arm" \
  FM_TEST_ARM_LOG="$dir/arm.log" \
  PATH="$dir/fakebin:$BASE_PATH" \
  bash -c '. "$1"; autoarm_status_announcements "$2"' _ \
  "$WATCH" "$dir/home/state/different-task.status"
grep -qxF 'different-task https://github.com/acme/widget/pull/88' "$dir/arm.log" \
  || fail "the watcher did not arm a PR announced in worker status"
FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_PR_CHECK_BIN="$dir/arm" \
  FM_TEST_ARM_LOG="$dir/arm.log" \
  PATH="$dir/fakebin:$BASE_PATH" \
  "$AUTOARM" announce different-task \
  'done: PR https://github.com/acme/widget/pull/88 checks green'
[ "$(wc -l < "$dir/arm.log" | tr -d ' ')" -eq 1 ] || fail "an announced PR was re-armed"
pass "worker PR announcements arm once without firstmate intervention"
