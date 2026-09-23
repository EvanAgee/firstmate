#!/usr/bin/env bash
# Tests for bin/fm-issue-close-after-merge.sh: the path that closes a shipped
# task's linked issues once its PR has merged, so a merged PR that carries no
# "Closes #n" line still retires the issue it fixed.
#
# Matrix:
#   (a) an already-closed issue is reported and never touched
#   (b) an open issue is closed with the merged-PR comment and the
#       agent-in-progress label is removed
#   (c) an open issue without the agent-in-progress label is closed anyway and
#       no label edit is attempted
#   (d) several linked issues are each handled in order
#   (e) a task with no issues= field is a silent no-op
#   (f) a task with no meta at all is refused
#   (g) a forge read error prints issue-close-failed, exits non-zero, and stops
#       before touching any later issue
#   (h) a forge close error prints issue-close-failed and exits non-zero
#   (i) a failed label removal only warns: the close already landed, so its
#       receipt still prints and every later linked issue is still handled
#   (j) a PR that is not merged is refused before any issue is read
#   (k) an issue in a repo other than the PR's own repository is refused
#   (l) a malformed PR URL is refused before any forge call
#   (m) a merged GitLab request on a task with no linked issues is a silent
#       no-op, so an ordinary GitLab task never makes its caller log a warning
#   (n) a merged GitLab request on a task that does record issues is refused
#   (o) a landed commit on the default branch closes each open linked issue
#       with a comment naming the commit, and never reads a PR
#   (p) a landed commit that GitHub does not report on the default branch is
#       refused before any issue is read
#   (q) a malformed landed SHA is refused before any forge call
#   (r) a landed commit whose linked issues span two repositories is refused
#       before any forge call
#   (s) an issue listed in issues_keep_open= stays open on both forms and is
#       reported as kept open, while every other linked issue still closes
#   (t) a malformed issues_keep_open= list is refused before any forge call
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOSER="$ROOT/bin/fm-issue-close-after-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-close-after-merge-tests)
URL=https://github.com/acme/widgets/pull/42
SHA=0123456789abcdef0123456789abcdef01234567
COMMIT_URL=https://github.com/acme/widgets/commit/$SHA

# One sandbox: a state dir with a task meta, a gh-axi mock for the PR read and
# the write calls, and a plain-gh mock that answers the issue read. Both record
# every invocation.
#
# The issue read is mocked on plain gh because that is what the helper uses: it
# asks for --json state,labels and gets back one line of JSON, with the state
# uppercase, exactly as the real gh prints it.
#
# The mock's issue state lives in <case>/issue-<number>.state (first line the
# state, second line the comma-separated labels), so a case scripts exactly
# what the forge reports without the helper knowing how it was produced.
#
# Plain gh also answers the landed form's compare read, printing the status
# GitHub reports for <sha>...HEAD (identical, ahead, behind, or diverged).
make_case() {  # <name> [issues=<refs>]
  local name=$1 issues=${2-} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  local -a meta=(
    "window=fm-task-x1"
    "worktree=$case_dir/wt"
    "project=$case_dir/project"
    "kind=ship"
    "mode=no-mistakes"
  )
  [ -z "$issues" ] || meta+=("issues=$issues")
  fm_write_meta "$case_dir/state/task-x1.meta" "${meta[@]}"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_PR_STATE:-merged}"
    exit "${FM_TEST_PR_VIEW_RC:-0}"
    ;;
  "issue close") exit "${FM_TEST_CLOSE_RC:-0}" ;;
  "issue edit") exit "${FM_TEST_EDIT_RC:-0}" ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  # Plain gh answers only the issue read, in the real --json shape: one line of
  # JSON with an uppercase state and a labels array.
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-}" = api ]; then
  [ "${FM_TEST_COMPARE_RC:-0}" -eq 0 ] || exit "$FM_TEST_COMPARE_RC"
  printf '%s\n' "${FM_TEST_COMPARE_STATUS:-identical}"
  exit 0
fi
case "${1:-} ${2:-}" in
  "issue view")
    number=$3
    file="$FM_TEST_CASE_DIR/issue-$number.state"
    [ -f "$file" ] || exit 1
    [ "${FM_TEST_VIEW_RC:-0}" -eq 0 ] || exit "$FM_TEST_VIEW_RC"
    state=$(sed -n 1p "$file" | tr '[:lower:]' '[:upper:]')
    labels=""
    raw=$(sed -n 2p "$file")
    if [ -n "$raw" ]; then
      IFS=, read -r -a names <<< "$raw"
      for name in "${names[@]}"; do
        [ -n "$name" ] || continue
        [ -z "$labels" ] || labels="$labels,"
        labels="$labels\"$name\""
      done
    fi
    printf '{"labels":[%s],"state":"%s"}\n' "$labels" "$state"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

set_issue() {  # <case-dir> <number> <state> [labels]
  printf '%s\n%s\n' "$3" "${4-}" > "$1/issue-$2.state"
}

run_closer() {  # <case-dir> <args...>
  local case_dir=$1; shift
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_PR_STATE="${FM_TEST_PR_STATE:-merged}" \
  FM_TEST_PR_VIEW_RC="${FM_TEST_PR_VIEW_RC:-0}" \
  FM_TEST_VIEW_RC="${FM_TEST_VIEW_RC:-0}" \
  FM_TEST_CLOSE_RC="${FM_TEST_CLOSE_RC:-0}" \
  FM_TEST_EDIT_RC="${FM_TEST_EDIT_RC:-0}" \
  FM_TEST_COMPARE_STATUS="${FM_TEST_COMPARE_STATUS:-identical}" \
  FM_TEST_COMPARE_RC="${FM_TEST_COMPARE_RC:-0}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CLOSER" "$@"
}

test_already_closed_issue_is_reported_and_untouched() {
  local case_dir rc
  case_dir=$(make_case already-closed acme/widgets#7)
  set_issue "$case_dir" 7 closed

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "already-closed: an already-closed issue is not a failure"
  assert_grep 'already-closed: acme/widgets#7' "$case_dir/out" \
    "already-closed: the already-closed line was not printed"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "already-closed: a closed issue was closed again"
  assert_no_grep 'issue edit' "$case_dir/gh-axi.log" \
    "already-closed: a closed issue had its labels edited"
  pass "an already-closed issue is reported and left alone"
}

test_open_issue_is_closed_with_comment_and_label_removed() {
  local case_dir rc
  case_dir=$(make_case open-closed acme/widgets#7)
  set_issue "$case_dir" 7 open agent-in-progress,bug

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "open-closed: closing an open issue should succeed"
  assert_grep "closed: acme/widgets#7 $URL" "$case_dir/out" \
    "open-closed: the closed line did not name the issue and merged PR"
  grep -qF "issue close 7 -R acme/widgets --reason completed --comment Fixed by $URL, merged to main." \
    "$case_dir/gh-axi.log" \
    || fail "open-closed: the issue was not closed with the merged-PR comment (log: $(cat "$case_dir/gh-axi.log"))"
  grep -qF 'issue edit 7 -R acme/widgets --remove-label agent-in-progress' \
    "$case_dir/gh-axi.log" \
    || fail "open-closed: the agent-in-progress label was not removed"
  pass "an open issue is closed with the merged-PR comment and loses its label"
}

test_open_issue_without_label_skips_the_label_edit() {
  local case_dir rc
  case_dir=$(make_case open-no-label acme/widgets#8)
  set_issue "$case_dir" 8 open bug

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "open-no-label: closing should succeed without the label"
  assert_grep "closed: acme/widgets#8 $URL" "$case_dir/out" \
    "open-no-label: the closed line was not printed"
  assert_no_grep 'issue edit' "$case_dir/gh-axi.log" \
    "open-no-label: a label edit ran for an issue that never carried the label"
  pass "an open issue without the label is closed with no label edit"
}

test_every_linked_issue_is_handled() {
  local case_dir rc
  case_dir=$(make_case several-issues 'acme/widgets#7,acme/widgets#8')
  set_issue "$case_dir" 7 closed
  set_issue "$case_dir" 8 open agent-in-progress

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "several-issues: handling every linked issue should succeed"
  assert_grep 'already-closed: acme/widgets#7' "$case_dir/out" \
    "several-issues: the already-closed issue was not reported"
  assert_grep "closed: acme/widgets#8 $URL" "$case_dir/out" \
    "several-issues: the open issue was not closed"
  pass "every issue in the task's issues= list is handled"
}

test_zero_padded_issue_numbers_are_normalized() {
  local case_dir rc expected
  case_dir=$(make_case zero-padded 'acme/widgets#8,acme/widgets#007,acme/widgets#0009')
  set_issue "$case_dir" 8 open
  set_issue "$case_dir" 7 open agent-in-progress
  set_issue "$case_dir" 9 closed

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "zero-padded: positive issue numbers should be accepted"
  expected=$(printf 'closed: acme/widgets#8 %s\nclosed: acme/widgets#7 %s\nalready-closed: acme/widgets#9\n' "$URL" "$URL")
  [ "$(cat "$case_dir/out")" = "$expected" ] \
    || fail "zero-padded: receipts did not preserve order and normalize issue numbers"
  assert_grep "issue close 7 -R acme/widgets --reason completed --comment Fixed by $URL, merged to main." \
    "$case_dir/gh-axi.log" "zero-padded: the normalized issue was not closed"
  assert_grep 'issue edit 7 -R acme/widgets --remove-label agent-in-progress' \
    "$case_dir/gh-axi.log" "zero-padded: the normalized issue label was not removed"
  assert_no_grep 'issue close 9 ' "$case_dir/gh-axi.log" \
    "zero-padded: an already-closed issue was mutated"
  pass "positive zero-padded issue numbers are normalized before forge calls and receipts"
}

test_missing_issues_field_is_a_silent_no_op() {
  local case_dir rc
  case_dir=$(make_case no-issues)

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-issues: a task with no linked issues is not a failure"
  [ ! -s "$case_dir/out" ] \
    || fail "no-issues: a task with no linked issues printed output"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "no-issues: a task with no linked issues called the forge"
  pass "a task with no issues= field is a silent no-op"
}

test_missing_meta_is_refused() {
  local case_dir rc
  case_dir=$(make_case no-meta)
  rm -f "$case_dir/state/task-x1.meta"

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "no-meta: a task with no metadata should be refused"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "no-meta: the forge was called for a task with no metadata"
  pass "a task with no metadata is refused"
}

test_forge_read_error_fails_and_stops() {
  local case_dir rc
  case_dir=$(make_case view-error 'acme/widgets#7,acme/widgets#8')
  set_issue "$case_dir" 7 open
  set_issue "$case_dir" 8 open
  FM_TEST_VIEW_RC=1

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  unset FM_TEST_VIEW_RC

  [ "$rc" -ne 0 ] || fail "view-error: an unreadable issue should exit non-zero"
  assert_grep 'issue-close-failed: acme/widgets#7 ' "$case_dir/err" \
    "view-error: the failure line did not name the issue"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "view-error: an issue was closed after the read failed"
  assert_no_grep 'issue view 8' "$case_dir/gh.log" \
    "view-error: the run continued to a later issue after a failure"
  pass "a forge read error reports the issue and stops without touching anything else"
}

test_forge_close_error_fails() {
  local case_dir rc
  case_dir=$(make_case close-error acme/widgets#7)
  set_issue "$case_dir" 7 open
  FM_TEST_CLOSE_RC=1

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  unset FM_TEST_CLOSE_RC

  [ "$rc" -ne 0 ] || fail "close-error: a failed close should exit non-zero"
  assert_grep 'issue-close-failed: acme/widgets#7 ' "$case_dir/err" \
    "close-error: the failure line did not name the issue"
  assert_no_grep "closed: acme/widgets#7 $URL" "$case_dir/out" \
    "close-error: a failed close was reported as closed"
  pass "a forge close error reports the issue and exits non-zero"
}

test_label_removal_failure_still_reports_and_continues() {
  local case_dir rc
  case_dir=$(make_case edit-error 'acme/widgets#7,acme/widgets#8')
  set_issue "$case_dir" 7 open agent-in-progress
  set_issue "$case_dir" 8 open
  FM_TEST_EDIT_RC=1

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  unset FM_TEST_EDIT_RC

  expect_code 0 "$rc" "edit-error: a stuck label must not fail a close that landed"
  assert_grep "closed: acme/widgets#7 $URL" "$case_dir/out" \
    "edit-error: the receipt for an issue that was closed went missing"
  assert_grep 'warning: acme/widgets#7 was closed but its agent-in-progress label' \
    "$case_dir/err" "edit-error: the stuck label was not warned about"
  assert_grep "closed: acme/widgets#8 $URL" "$case_dir/out" \
    "edit-error: a stuck label on one issue skipped the next linked issue"
  grep -qF 'issue close 8 -R acme/widgets' "$case_dir/gh-axi.log" \
    || fail "edit-error: the later linked issue was never closed (log: $(cat "$case_dir/gh-axi.log"))"
  pass "a failed label removal warns, keeps the receipt, and handles later issues"
}

test_unmerged_pr_is_refused_before_reading_issues() {
  local case_dir rc
  case_dir=$(make_case not-merged acme/widgets#7)
  set_issue "$case_dir" 7 open
  FM_TEST_PR_STATE=open

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  unset FM_TEST_PR_STATE

  [ "$rc" -ne 0 ] || fail "not-merged: an unmerged PR should be refused"
  assert_no_grep 'issue view' "$case_dir/gh.log" \
    "not-merged: an issue was read for an unmerged PR"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "not-merged: an issue was closed for an unmerged PR"
  pass "an unmerged PR is refused before any issue is read"
}

test_issue_outside_the_pr_repo_is_refused() {
  local case_dir rc
  case_dir=$(make_case foreign-repo 'acme/widgets#7,other/repo#9')
  set_issue "$case_dir" 7 open
  set_issue "$case_dir" 9 open

  set +e
  run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "foreign-repo: an issue outside the PR repo should be refused"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "foreign-repo: an issue was closed despite a foreign linked repo"
  pass "an issue outside the PR's own repository is refused"
}

test_malformed_issue_references_are_refused_before_forge_calls() {
  local case_dir rc refs i=0
  for refs in 'acme/widgets#55#66' 'acme/widgets#7,acme/widgets#55#66' \
    'acme/widgets#55#66,acme/widgets#7' 'acme/widgets#0' 'acme/widgets#000' \
    'acme/widgets#7,,acme/widgets#8' 'acme/widgets#7,'; do
    i=$((i + 1))
    case_dir=$(make_case "malformed-issue-$i" "$refs")
    set_issue "$case_dir" 7 open
    set_issue "$case_dir" 66 open

    set +e
    run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "malformed issue list was accepted: $refs"
    assert_grep 'not a GitHub issue ref list' "$case_dir/err" \
      "malformed issue list did not report its refusal: $refs"
    [ -f "$case_dir/gh-axi.log" ] && [ ! -s "$case_dir/gh-axi.log" ] \
      || fail "malformed issue list reached the forge: $refs"
    [ -f "$case_dir/gh.log" ] && [ ! -s "$case_dir/gh.log" ] \
      || fail "malformed issue list read an issue: $refs"
    [ ! -s "$case_dir/out" ] || fail "malformed issue list printed a receipt: $refs"
  done
  pass "malformed issue lists are refused before any forge call"
}

test_malformed_pr_url_is_refused() {
  local case_dir rc
  case_dir=$(make_case bad-url acme/widgets#7)
  set_issue "$case_dir" 7 open

  set +e
  run_closer "$case_dir" task-x1 'https://github.com/acme/widgets/pull/not-a-number' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "bad-url: a malformed PR URL should be refused"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "bad-url: the forge was called for a malformed PR URL"
  pass "a malformed PR URL is refused before any forge call"
}

test_gitlab_url_without_linked_issues_is_a_silent_no_op() {
  local case_dir rc
  case_dir=$(make_case gitlab-no-issues)

  set +e
  run_closer "$case_dir" task-x1 'https://gitlab.com/acme/widgets/-/merge_requests/42' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" \
    "gitlab-no-issues: an ordinary GitLab task should exit 0, not make its caller warn"
  [ ! -s "$case_dir/out" ] || fail "gitlab-no-issues: the no-op printed output"
  [ ! -s "$case_dir/err" ] || fail "gitlab-no-issues: the no-op reported an error"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "gitlab-no-issues: the forge was called for a task with no linked issues"
  pass "a merged GitLab request without linked issues is a silent no-op"
}

test_gitlab_url_with_linked_issues_is_refused() {
  local case_dir rc
  case_dir=$(make_case gitlab-with-issues acme/widgets#7)

  set +e
  run_closer "$case_dir" task-x1 'https://gitlab.com/acme/widgets/-/merge_requests/42' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] \
    || fail "gitlab-with-issues: a GitLab request naming GitHub issues should be refused"
  assert_grep 'not a GitHub pull request' "$case_dir/err" \
    "gitlab-with-issues: the refusal did not say why it stopped"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "gitlab-with-issues: the forge was called despite the refusal"
  pass "a merged GitLab request that records linked issues is refused"
}

test_landed_commit_closes_open_issues_naming_the_commit() {
  local case_dir rc
  case_dir=$(make_case landed 'acme/widgets#7,acme/widgets#8')
  set_issue "$case_dir" 7 open agent-in-progress
  set_issue "$case_dir" 8 closed

  set +e
  run_closer "$case_dir" task-x1 --landed "$SHA" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "landed: closing after a landed commit should succeed ($(cat "$case_dir/err"))"
  assert_grep "api repos/acme/widgets/compare/$SHA...HEAD --jq .status" "$case_dir/gh.log" \
    "landed: the landed commit was not checked against the default branch"
  grep -qF "issue close 7 -R acme/widgets --reason completed --comment Fixed by $COMMIT_URL, landed on the default branch." \
    "$case_dir/gh-axi.log" \
    || fail "landed: the issue was not closed with the landed-commit comment (log: $(cat "$case_dir/gh-axi.log"))"
  assert_grep 'issue edit 7 -R acme/widgets --remove-label agent-in-progress' \
    "$case_dir/gh-axi.log" "landed: the agent-in-progress label was not removed"
  assert_grep "closed: acme/widgets#7 $COMMIT_URL" "$case_dir/out" \
    "landed: the receipt did not name the issue and the landed commit"
  assert_grep 'already-closed: acme/widgets#8' "$case_dir/out" \
    "landed: the already-closed issue was not reported"
  assert_no_grep 'pr view' "$case_dir/gh-axi.log" \
    "landed: a landed commit read a pull request"
  pass "a landed commit closes each open linked issue with a comment naming the commit"
}

test_landed_commit_off_the_default_branch_is_refused() {
  local case_dir rc status i=0
  for status in behind diverged unreachable; do
    i=$((i + 1))
    case_dir=$(make_case "landed-off-main-$i" acme/widgets#7)
    set_issue "$case_dir" 7 open
    if [ "$status" = unreachable ]; then
      FM_TEST_COMPARE_RC=1
    else
      FM_TEST_COMPARE_STATUS=$status
    fi

    set +e
    run_closer "$case_dir" task-x1 --landed "$SHA" > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    unset FM_TEST_COMPARE_RC FM_TEST_COMPARE_STATUS

    [ "$rc" -ne 0 ] || fail "landed-off-main: a $status commit should be refused"
    assert_grep "refusing to close any issue" "$case_dir/err" \
      "landed-off-main: the $status refusal did not say why it stopped"
    assert_no_grep 'issue view' "$case_dir/gh.log" \
      "landed-off-main: an issue was read for a $status commit"
    assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
      "landed-off-main: an issue was closed for a $status commit"
  done
  pass "a landed commit GitHub does not report on the default branch is refused"
}

test_malformed_landed_sha_is_refused_before_forge_calls() {
  local case_dir rc sha i=0
  for sha in '' 1234567 "${SHA}0" 0123456789ABCDEF0123456789ABCDEF01234567 \
    'zz23456789abcdef0123456789abcdef01234567'; do
    i=$((i + 1))
    case_dir=$(make_case "landed-bad-sha-$i" acme/widgets#7)
    set_issue "$case_dir" 7 open

    set +e
    run_closer "$case_dir" task-x1 --landed "$sha" > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "landed-bad-sha: '$sha' was accepted"
    assert_grep 'not a full commit SHA' "$case_dir/err" \
      "landed-bad-sha: the refusal for '$sha' did not say why it stopped"
    [ ! -s "$case_dir/gh.log" ] && [ ! -s "$case_dir/gh-axi.log" ] \
      || fail "landed-bad-sha: '$sha' reached the forge"
  done
  pass "a malformed landed SHA is refused before any forge call"
}

test_landed_issues_in_two_repositories_are_refused() {
  local case_dir rc
  case_dir=$(make_case landed-two-repos 'acme/widgets#7,other/repo#9')
  set_issue "$case_dir" 7 open
  set_issue "$case_dir" 9 open

  set +e
  run_closer "$case_dir" task-x1 --landed "$SHA" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "landed-two-repos: issues in two repositories should be refused"
  assert_grep 'more than one repository' "$case_dir/err" \
    "landed-two-repos: the refusal did not say why it stopped"
  [ ! -s "$case_dir/gh.log" ] && [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "landed-two-repos: the forge was called despite the refusal"
  pass "a landed commit whose linked issues span two repositories is refused"
}

test_keep_open_issues_stay_open_on_both_forms() {
  local case_dir rc form receipt
  for form in pr landed; do
    case_dir=$(make_case "keep-open-$form" 'acme/widgets#7,acme/widgets#8')
    printf 'issues_keep_open=acme/widgets#08\n' >> "$case_dir/state/task-x1.meta"
    set_issue "$case_dir" 7 open
    set_issue "$case_dir" 8 open agent-in-progress

    set +e
    if [ "$form" = pr ]; then
      run_closer "$case_dir" task-x1 "$URL" > "$case_dir/out" 2> "$case_dir/err"
      rc=$?
      receipt=$URL
    else
      run_closer "$case_dir" task-x1 --landed "$SHA" > "$case_dir/out" 2> "$case_dir/err"
      rc=$?
      receipt=$COMMIT_URL
    fi
    set -e

    expect_code 0 "$rc" "keep-open-$form: a kept-open issue is not a failure ($(cat "$case_dir/err"))"
    assert_grep "closed: acme/widgets#7 $receipt" "$case_dir/out" \
      "keep-open-$form: the other linked issue was not closed"
    assert_grep 'kept-open: acme/widgets#8' "$case_dir/out" \
      "keep-open-$form: the kept-open issue was not reported"
    assert_no_grep 'issue close 8 ' "$case_dir/gh-axi.log" \
      "keep-open-$form: a kept-open issue was closed"
    assert_no_grep 'issue edit 8 ' "$case_dir/gh-axi.log" \
      "keep-open-$form: a kept-open issue lost its label"
  done
  pass "an issue in issues_keep_open= stays open on both forms while the rest close"
}

test_malformed_keep_open_list_is_refused_before_forge_calls() {
  local case_dir rc
  case_dir=$(make_case keep-open-bad acme/widgets#7)
  printf 'issues_keep_open=acme/widgets#7,,\n' >> "$case_dir/state/task-x1.meta"
  set_issue "$case_dir" 7 open

  set +e
  run_closer "$case_dir" task-x1 --landed "$SHA" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "keep-open-bad: a malformed keep-open list was accepted"
  assert_grep 'issues_keep_open' "$case_dir/err" \
    "keep-open-bad: the refusal did not name the malformed field"
  [ ! -s "$case_dir/gh.log" ] && [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "keep-open-bad: a malformed keep-open list reached the forge"
  pass "a malformed issues_keep_open= list is refused before any forge call"
}

test_already_closed_issue_is_reported_and_untouched
test_open_issue_is_closed_with_comment_and_label_removed
test_open_issue_without_label_skips_the_label_edit
test_every_linked_issue_is_handled
test_zero_padded_issue_numbers_are_normalized
test_missing_issues_field_is_a_silent_no_op
test_missing_meta_is_refused
test_forge_read_error_fails_and_stops
test_forge_close_error_fails
test_label_removal_failure_still_reports_and_continues
test_unmerged_pr_is_refused_before_reading_issues
test_issue_outside_the_pr_repo_is_refused
test_malformed_issue_references_are_refused_before_forge_calls
test_malformed_pr_url_is_refused
test_gitlab_url_without_linked_issues_is_a_silent_no_op
test_gitlab_url_with_linked_issues_is_refused
test_landed_commit_closes_open_issues_naming_the_commit
test_landed_commit_off_the_default_branch_is_refused
test_malformed_landed_sha_is_refused_before_forge_calls
test_landed_issues_in_two_repositories_are_refused
test_keep_open_issues_stay_open_on_both_forms
test_malformed_keep_open_list_is_refused_before_forge_calls
