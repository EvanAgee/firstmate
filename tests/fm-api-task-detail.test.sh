#!/usr/bin/env bash
# tests/fm-api-task-detail.test.sh - full task detail and worker activity over HTTP.
set -u

# shellcheck source=tests/api-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/api-helpers.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

split_http() {
  HTTP_CODE=
  HTTP_BODY=
  IFS= read -r HTTP_CODE || true
  HTTP_BODY=$(cat)
}

make_task_worktree() {  # <home>
  local home=$1 wt="$1/projects/widget"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" config user.name "API fixture"
  git -C "$wt" config user.email "api-fixture@example.test"
  printf 'alpha\n' > "$wt/first.txt"
  git -C "$wt" add first.txt
  git -C "$wt" commit -qm "base"
  git -C "$wt" update-ref refs/remotes/origin/main HEAD
  git -C "$wt" checkout -qb fm/api-detail
  printf 'alpha\nbeta\n' > "$wt/first.txt"
  git -C "$wt" add first.txt
  git -C "$wt" commit -qm "add beta"
  printf 'second\n' > "$wt/second.txt"
  git -C "$wt" add second.txt
  git -C "$wt" commit -qm "add second file"
  printf 'not committed\n' >> "$wt/first.txt"
  printf '%s\n' "$wt"
}

make_activity_tools() {  # <dir>
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  branch=$(git symbolic-ref --quiet --short HEAD)
  head=$(git rev-parse --short=8 HEAD)
  cat <<EOF
run:
  id: "fixture-run"
  branch: "$branch"
  status: ci
  head: "$head"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,1
    rebase,completed,0,1
    review,completed,0,1
    test,completed,0,1
    document,completed,0,1
    lint,completed,0,1
    push,completed,0,1
    pr,completed,0,1
    ci,running,0,1
EOF
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = logs ]; then
  printf '%s\n' 'all CI checks passed - still monitoring until merged or closed'
  exit 0
fi
exit 1
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    cat <<'EOF'
pull_request:
  number: 77
  state: open
  body: "<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"fixture-head\",\"steps\":[{\"step\":\"review\",\"status\":\"completed\"},{\"step\":\"test\",\"status\":\"completed\"},{\"step\":\"lint\",\"status\":\"completed\"},{\"step\":\"ci\",\"status\":\"pending\"}]} -->"
EOF
    ;;
  "pr checks")
    if [ "${FM_TEST_GH_CHECKS:-}" = skip-mix ]; then
      cat <<'EOF'
summary: "1 passed, 0 failed, 1 skipped, 2 total"
checks[2]{name,conclusion}:
  Build,skip
  Test,pass
EOF
    else
      cat <<'EOF'
summary: "2 passed, 0 failed, 2 total"
checks[2]{name,conclusion}:
  Bash tests,pass
  Lint shell scripts,pass
EOF
    fi
    ;;
  "api POST")
    cat <<'EOF'
data:
  repository:
    pullRequest:
      reviewThreads:
        nodes[3]{isResolved}:
          false
          true
          true
        pageInfo:
          hasNextPage: false
          endCursor: null
EOF
    ;;
  "pr list")
    printf '%s\n' 'pull_requests[1]{url}:' '  "https://github.com/acme/widget/pull/77"'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/gh-axi"
}

test_task_detail_returns_full_worker_activity() {
  local home wt fakebin port resp
  home=$(fm_test_api_home api-task-detail)
  wt=$(make_task_worktree "$home")
  fakebin="$home/fakebin"
  make_activity_tools "$fakebin"
  mkdir -p "$home/data/detail-task"
  cat > "$home/data/detail-task/brief.md" <<'EOF'
# Build the task detail API

Return the whole worker picture.
EOF
  cat > "$home/state/detail-task.meta" <<EOF
window=fixture:fm-detail-task
worktree=$wt
project=widget
harness=codex
kind=ship
mode=no-mistakes
pr=https://github.com/acme/widget/pull/77
EOF
  cat > "$home/state/detail-task.status" <<'EOF'
working: setup complete
working: review passed; test passed; lint passed
done: PR https://github.com/acme/widget/pull/77 checks green
EOF
  printf 'running bash tests\nlatest assertion passed\n' > "$home/state/detail-task.pane-tail"

  port=$(PATH="$fakebin:$PATH" fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/detail-task GET 12000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "task detail status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = true ] || fail "task detail missing ok: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.id')" = detail-task ] || fail "task id: $HTTP_BODY"
  assert_contains "$(fm_test_json "$HTTP_BODY" 'd.task.brief')" "Return the whole worker picture." \
    "full brief: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.timeline.length')" = 3 ] || fail "timeline: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.timeline[0].verb')" = working ] || fail "timeline verb: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.stage.state')" = "done" ] || fail "current stage: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.stage.source')" = run-step ] || fail "stage source: $HTTP_BODY"

  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.worktree.path')" = "$(cd "$wt" && pwd -P)" ] || fail "worktree: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.worktree.branch')" = fm/api-detail ] || fail "branch: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.commits.count')" = 2 ] || fail "commit count: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.commits.items[0].message')" = "add second file" ] || \
    fail "commit message: $HTTP_BODY"
  [ -n "$(fm_test_json "$HTTP_BODY" 'd.task.activity.commits.items[0].time')" ] || fail "commit time absent"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.diff.files_changed')" = 2 ] || fail "files changed: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.diff.additions')" = 2 ] || fail "diff additions: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.diff.deletions')" = 0 ] || fail "diff deletions: $HTTP_BODY"
  assert_contains "$(fm_test_json "$HTTP_BODY" 'd.task.activity.diff.stat')" "2 files changed" "git diff stat: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.uncommitted_file_count')" = 1 ] || \
    fail "uncommitted file count: $HTTP_BODY"

  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.review.status')" = passed ] || fail "review step: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.test.status')" = passed ] || fail "test step: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.lint.status')" = passed ] || fail "lint step: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.ci.status')" = passed ] || fail "ci step: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.ci.source')" = github-checks ] || \
    fail "ci source: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.available')" = true ] || fail "pipeline availability: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.attestation.head_sha')" = fixture-head ] || \
    fail "pipeline attestation: $HTTP_BODY"

  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.url')" = "https://github.com/acme/widget/pull/77" ] || \
    fail "PR URL: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.status')" = passed ] || fail "PR checks: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.review_threads.open')" = 1 ] || fail "open threads: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.review_threads.resolved')" = 2 ] || \
    fail "resolved threads: $HTTP_BODY"
  assert_contains "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pane_tail.text')" "running bash tests" \
    "live pane tail: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pane_tail.available')" = true ] || fail "pane availability: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "task detail returns the brief, timeline, stage, git, pipeline, PR, and live pane activity"
}

test_unknown_task_returns_json_404() {
  local home port resp
  home=$(fm_test_api_home api-task-missing)
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/no-such-task)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 404 ] || fail "unknown task status $HTTP_CODE, wanted 404: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.ok')" = false ] || fail "unknown task body missing ok=false: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.error')" = "task not found" ] || fail "unknown task error: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "unknown task ids return a JSON 404"
}

test_skipped_github_check_is_kept_without_failing_ci() {
  local home wt fakebin port resp
  home=$(fm_test_api_home api-task-skip-check)
  wt=$(make_task_worktree "$home")
  fakebin="$home/fakebin"
  make_activity_tools "$fakebin"
  mkdir -p "$home/data/skip-task"
  printf 'Keep skipped checks.\n' > "$home/data/skip-task/brief.md"
  cat > "$home/state/skip-task.meta" <<EOF
window=fixture:fm-skip-task
worktree=$wt
project=widget
harness=codex
kind=ship
mode=no-mistakes
pr=https://github.com/acme/widget/pull/77
EOF
  printf 'done: PR https://github.com/acme/widget/pull/77 checks green\n' > "$home/state/skip-task.status"

  port=$(PATH="$fakebin:$PATH" FM_TEST_GH_CHECKS=skip-mix fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/skip-task GET 12000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "skip-check status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.status')" = passed ] || \
    fail "skipped check treated as CI failure: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.checks.length')" = 2 ] || \
    fail "skipped check dropped: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.checks[0].name')" = Build ] || \
    fail "skipped check name: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.checks[0].status')" = skip ] || \
    fail "skipped check status: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.checks[1].name')" = Test ] || \
    fail "passing check name: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pull_request.ci.checks[1].status')" = pass ] || \
    fail "passing check status: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "a gh-axi skip conclusion is returned and does not fail CI"
}

test_mixed_status_line_keeps_pipeline_steps_independent() {
  local home port resp
  home=$(fm_test_api_home api-task-mixed-steps)
  mkdir -p "$home/data/mixed-task" "$home/fakebin"
  printf 'Mixed pipeline outcomes stay independent.\n' > "$home/data/mixed-task/brief.md"
  cat > "$home/state/mixed-task.meta" <<'EOF'
window=fixture:fm-mixed-task
project=widget
harness=codex
kind=ship
mode=no-mistakes
EOF
  cat > "$home/state/mixed-task.status" <<'EOF'
working: review passed; test failed; lint passed
EOF
  cat > "$home/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/no-mistakes" "$home/fakebin/gh-axi"

  port=$(PATH="$home/fakebin:$PATH" fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/mixed-task GET 12000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "mixed-step status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.review.status')" = passed ] || \
    fail "review poisoned by sibling failure: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.review.source')" = status-timeline ] || \
    fail "review source: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.test.status')" = failed ] || \
    fail "test step: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.test.source')" = status-timeline ] || \
    fail "test source: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.lint.status')" = passed ] || \
    fail "lint poisoned by sibling failure: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.lint.source')" = status-timeline ] || \
    fail "lint source: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "mixed status-line pipeline steps stay independent"
}

test_pr_url_repo_named_test_is_not_test_step_evidence() {
  local home port resp
  home=$(fm_test_api_home api-task-url-test)
  mkdir -p "$home/data/url-task" "$home/fakebin"
  printf 'A repo named test is not a test step.\n' > "$home/data/url-task/brief.md"
  cat > "$home/state/url-task.meta" <<'EOF'
window=fixture:fm-url-task
project=widget
harness=codex
kind=ship
mode=no-mistakes
EOF
  cat > "$home/state/url-task.status" <<'EOF'
done: PR https://github.com/acme/test/pull/77 checks green
EOF
  cat > "$home/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/no-mistakes" "$home/fakebin/gh-axi"

  port=$(PATH="$home/fakebin:$PATH" fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/url-task GET 12000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "url-test status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.test.status')" = unknown ] || \
    fail "PR repo named test created test-step evidence: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.test.source')" = none ] || \
    fail "test source: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.ci.status')" = passed ] || \
    fail "checks-green CI step: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.activity.pipeline.steps.ci.source')" = status-timeline ] || \
    fail "ci source: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "a PR URL repo named test does not create test-step evidence"
}

test_timeline_carries_times_and_meta_runtime() {
  local home port resp
  home=$(fm_test_api_home api-detail-times)
  cat > "$home/state/timed-task.meta" <<'EOF'
window=fixture:fm-timed-task
spawn_gen=s1756150000.123
harness=codex
model=gpt-5.6-sol
kind=ship
EOF
  cat > "$home/state/timed-task.status" <<'EOF'
spawned: work begins
working: first pass done
done: PR merged
EOF
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/timed-task GET 15000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "timed task status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.harness')" = codex ] || \
    fail "task harness from meta: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.model')" = gpt-5.6-sol ] || \
    fail "task model from meta: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'new Date(d.task.started_at).getTime() === 1756150000000')" = true ] || \
    fail "started_at from spawn_gen epoch: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.timeline.length')" = 3 ] || \
    fail "timeline length: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" \
      'd.task.timeline.every(e => typeof e.observed_at === "string" && !isNaN(Date.parse(e.observed_at)))')" = true ] || \
    fail "every timeline event carries a parseable observed_at: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" \
      'd.task.timeline.every(e => e.time_approximate === true)')" = true ] || \
    fail "timeline times are marked approximate: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" \
      'd.task.timeline.every((e, i, a) => i === 0 || Date.parse(e.observed_at) >= Date.parse(a[i - 1].observed_at))')" = true ] || \
    fail "timeline observed_at should be non-decreasing: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "task detail carries meta runtime, started_at, and per-event observed times"
}

test_started_at_falls_back_to_status_birth() {
  local home port resp
  home=$(fm_test_api_home api-detail-birth)
  printf 'working: no meta for this one\n' > "$home/state/bare-task.status"
  port=$(fm_test_api_start "$home")
  resp=$(fm_test_api_http "$port" /tasks/bare-task GET 15000)
  split_http <<<"$resp"
  [ "$HTTP_CODE" = 200 ] || fail "bare task status $HTTP_CODE, wanted 200: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" \
      'typeof d.task.started_at === "string" && !isNaN(Date.parse(d.task.started_at))')" = true ] || \
    fail "started_at should fall back to the status file birth time: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.harness === ""')" = true ] || \
    fail "absent meta harness should be empty: $HTTP_BODY"
  [ "$(fm_test_json "$HTTP_BODY" 'd.task.model === ""')" = true ] || \
    fail "absent meta model should be empty: $HTTP_BODY"
  fm_test_api_stop "$home"
  pass "started_at falls back to the status file birth time without meta"
}

test_task_detail_returns_full_worker_activity
test_unknown_task_returns_json_404
test_skipped_github_check_is_kept_without_failing_ci
test_mixed_status_line_keeps_pipeline_steps_independent
test_pr_url_repo_named_test_is_not_test_step_evidence
test_timeline_carries_times_and_meta_runtime
test_started_at_falls_back_to_status_birth

echo "# fm-api-task-detail.test.sh: all assertions passed"
