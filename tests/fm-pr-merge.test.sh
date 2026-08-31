#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a PR with unresolved review threads is refused before merging
#   (j) a PR with every thread resolved merges normally
#   (k) an unreadable thread-query result fails closed (no merge)
#   (l) a failed thread query fails closed (no merge)
#   (m) --allow-unresolved-threads bypasses the gate, is logged, and merges
#   (n) --allow-unresolved-threads still forwards extra args after --
#   (o) more than 100 review threads is refused before merging
#   (p) --allow-unresolved-threads after -- does not bypass the gate
#   (q) captain-merge refuses before recording or checking a PR without approval
#   (r) --captain-approved refuses when its URL does not match the merged PR
#   (s) a matching --captain-approved bypass is logged to stderr and merges
#   (t) a project without the exact captain-merge token merges normally
#   (u) a project absent from an existing registry merges normally
#   (v) brackets in a legacy description do not enable captain-merge
#   (w) a registry parser failure refuses before checking or merging
#   (x) a mismatched approval still refuses for an unguarded project
#   (y) project metadata must contain one nonempty project identity
#   (z) duplicate captain approval flags refuse before policy lookup
#   (aa) a successful merge appends its delivery-timing record
#   (ab) pull request timestamp failures are logged without failing the merge
#   (ac) auto-merge does not record a task until the pull request lands
#   (ad) a delivery-ledger failure is logged without failing the merge
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
#
# The gh-axi stub also answers the review-thread gate's GraphQL call: it returns
# FM_TEST_THREADS_TOTAL for the totalCount query and FM_TEST_THREADS_UNRESOLVED
# for the unresolved-count query, matching on the jq expression the gate passes.
# Both default to 0 (all threads resolved) so a case that does not set them keeps
# merging as before. It records only non-graphql calls to the log so existing
# `pr merge` assertions are unaffected by the added thread reads.
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${3:-}" = /graphql ]; then
  printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_API_LOG"
  # The query body carries both totalCount and isResolved, so match on the jq
  # expression instead: only the unresolved-count call carries "length".
  case "$*" in
    *length*) printf '%s\n' "${FM_TEST_THREADS_UNRESOLVED:-0}" ;;
    *totalCount*) printf '%s\n' "${FM_TEST_THREADS_TOTAL:-0}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = GET ]; then
  if [ "${FM_TEST_PR_LOOKUP_FAIL:-0}" -eq 1 ]; then
    echo 'error: pull request lookup failed' >&2
    exit 1
  fi
  if [ "${FM_TEST_PR_FACTS_GARBLED:-0}" -eq 1 ]; then
    printf '%s\n' 'unreadable pull request facts'
    exit 0
  fi
  printf '%s\t%s\t%s\n' \
    "${FM_TEST_PR_MERGED:-true}" \
    "${FM_TEST_PR_OPENED_AT:-2025-08-25T12:00:00Z}" \
    "${FM_TEST_PR_MERGED_AT-2025-08-25T12:10:00Z}"
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${3:-}" = /graphql ]; then
  case "$*" in
    *length*) printf '%s\n' "${FM_TEST_THREADS_UNRESOLVED:-0}" ;;
    *totalCount*) printf '%s\n' "${FM_TEST_THREADS_TOTAL:-0}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock whose review-thread query fails: the GraphQL call exits non-zero
# (a network or API error). Everything else, including pr merge, would succeed,
# so a merge that still happens proves the gate did not fail closed.
add_gh_mocks_thread_query_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${3:-}" = /graphql ]; then
  echo "error: graphql request failed" >&2
  exit 1
fi
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock whose review-thread query returns garbage instead of an integer,
# as a mangled or enveloped response would. The gate must refuse rather than
# treat unreadable output as zero unresolved threads.
add_gh_mocks_thread_query_garbled() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${3:-}" = /graphql ]; then
  printf '%s\n' "api_response:"
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_API_LOG="$case_dir/gh-axi-api.log" \
  FM_TEST_THREADS_TOTAL="${FM_TEST_THREADS_TOTAL:-0}" \
  FM_TEST_THREADS_UNRESOLVED="${FM_TEST_THREADS_UNRESOLVED:-0}" \
  FM_TEST_PR_OPENED_AT="${FM_TEST_PR_OPENED_AT:-2025-08-25T12:00:00Z}" \
  FM_TEST_PR_MERGED_AT="${FM_TEST_PR_MERGED_AT-2025-08-25T12:10:00Z}" \
  FM_TEST_PR_MERGED="${FM_TEST_PR_MERGED:-true}" \
  FM_TEST_PR_LOOKUP_FAIL="${FM_TEST_PR_LOOKUP_FAIL:-0}" \
  FM_TEST_PR_FACTS_GARBLED="${FM_TEST_PR_FACTS_GARBLED:-0}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_captain_merge_refuses_without_approval() {
  local case_dir project registry_line rc
  case_dir=$(make_case captain-merge-refusal)
  project=project
  registry_line="- $project [no-mistakes,captain-merge(explicit approval required),evidence-required] - fixture (added 2026-08-29)"
  printf '%s\n' "$registry_line" > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-api.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/47 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "captain-merge-refusal: merge should require explicit approval"
  assert_grep "captain-merge project \"$project\"" "$case_dir/stderr" \
    "captain-merge-refusal: refusal did not name the project"
  assert_grep "$registry_line" "$case_dir/stderr" \
    "captain-merge-refusal: refusal did not show the registry line"
  assert_grep 'https://github.com/example/repo/pull/47' "$case_dir/stderr" \
    "captain-merge-refusal: refusal did not name the PR URL"
  [ ! -s "$case_dir/gh-axi-api.log" ] \
    || fail "captain-merge-refusal: review threads were checked before refusal"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "captain-merge-refusal: gh-axi pr merge was invoked without approval"
  assert_no_grep 'pr=https://github.com/example/repo/pull/47' "$case_dir/state/task-x1.meta" \
    "captain-merge-refusal: PR state was recorded before refusal"
  pass "fm-pr-merge requires explicit approval for a captain-merge project"
}

test_captain_approval_refuses_a_different_pr() {
  local case_dir project registry_line rc
  case_dir=$(make_case captain-approval-mismatch)
  project=project
  registry_line="- $project [no-mistakes captain-merge] - fixture (added 2026-08-29)"
  printf '%s\n' "$registry_line" > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1212121212121212121212121212121212121212
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-api.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/48 \
    --captain-approved https://github.com/example/repo/pull/47 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "captain-approval-mismatch: a different PR URL should refuse"
  assert_grep "captain-merge project \"$project\"" "$case_dir/stderr" \
    "captain-approval-mismatch: refusal did not name the project"
  assert_grep "$registry_line" "$case_dir/stderr" \
    "captain-approval-mismatch: refusal did not show the registry line"
  assert_grep 'error: PR: https://github.com/example/repo/pull/48' "$case_dir/stderr" \
    "captain-approval-mismatch: refusal did not name the canonical PR URL"
  [ ! -s "$case_dir/gh-axi-api.log" ] \
    || fail "captain-approval-mismatch: review threads were checked before refusal"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "captain-approval-mismatch: gh-axi pr merge was invoked for a different approval URL"
  pass "fm-pr-merge rejects a captain approval for a different PR"
}

test_matching_captain_approval_bypasses_and_logs() {
  local case_dir project rc
  case_dir=$(make_case captain-approval-match)
  project=project
  printf '%s\n' \
    "- $project [no-mistakes captain-merge] - fixture (added 2026-08-29)" \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1313131313131313131313131313131313131313
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-api.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/49 \
    --captain-approved https://github.com/example/repo/pull/49 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "captain-approval-match: matching approval should merge"
  assert_grep '--captain-approved matched https://github.com/example/repo/pull/49' "$case_dir/stderr" \
    "captain-approval-match: bypass was not logged to stderr"
  grep -qxF 'pr merge 49 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "captain-approval-match: gh-axi pr merge was not invoked"
  pass "fm-pr-merge logs and accepts a matching captain approval"
}

test_project_without_captain_merge_token_merges() {
  local case_dir project rc
  case_dir=$(make_case no-captain-merge-token)
  project=project
  printf '%s\n' \
    "- $project [no-mistakes captain-merge-later] - captain-merge appears only outside the bracket token list (added 2026-08-29)" \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1414141414141414141414141414141414141414
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/50 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-captain-merge-token: project should merge normally"
  grep -qxF 'pr merge 50 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-captain-merge-token: gh-axi pr merge was not invoked"
  pass "fm-pr-merge ignores similar text that is not the exact bracket-list token"
}

test_project_absent_from_registry_merges() {
  local case_dir rc
  case_dir=$(make_case project-absent-from-registry)
  printf '%s\n' \
    '- another-project [no-mistakes captain-merge] - fixture (added 2026-08-29)' \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1515151515151515151515151515151515151515
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "project-absent-from-registry: project should merge normally"
  grep -qxF 'pr merge 51 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "project-absent-from-registry: gh-axi pr merge was not invoked"
  pass "fm-pr-merge does not require the flag for a project absent from the registry"
}

test_legacy_description_brackets_do_not_enable_captain_merge() {
  local case_dir rc
  case_dir=$(make_case legacy-description-brackets)
  printf '%s\n' \
    '- project - legacy description [captain-merge] (added 2026-08-29)' \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1616161616161616161616161616161616161616
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "legacy-description-brackets: description text should not require approval"
  grep -qxF 'pr merge 52 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "legacy-description-brackets: gh-axi pr merge was not invoked"
  pass "fm-pr-merge ignores captain-merge brackets outside the posture annotation"
}

test_registry_parser_failure_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case registry-parser-failure)
  printf '%s\n' \
    '- project [no-mistakes captain-merge] - fixture (added 2026-08-29)' \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1717171717171717171717171717171717171717
  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$case_dir/fakebin/awk"
  chmod +x "$case_dir/fakebin/awk"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-api.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "registry-parser-failure: policy read failure should refuse"
  assert_grep 'could not read captain-merge policy for project "project"' "$case_dir/stderr" \
    "registry-parser-failure: refusal did not name the policy read failure"
  [ ! -s "$case_dir/gh-axi-api.log" ] \
    || fail "registry-parser-failure: review threads were checked after a policy read failure"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "registry-parser-failure: gh-axi pr merge was invoked after a policy read failure"
  pass "fm-pr-merge fails closed when the registry parser fails"
}

test_unguarded_project_refuses_mismatched_approval() {
  local case_dir rc
  case_dir=$(make_case unguarded-approval-mismatch)
  printf '%s\n' \
    '- project [no-mistakes] - fixture (added 2026-08-29)' \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 1818181818181818181818181818181818181818
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-api.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    --captain-approved https://github.com/example/repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unguarded-approval-mismatch: a different PR URL should refuse"
  assert_grep 'must exactly match https://github.com/example/repo/pull/54' "$case_dir/stderr" \
    "unguarded-approval-mismatch: refusal did not name the canonical PR URL"
  [ ! -s "$case_dir/gh-axi-api.log" ] \
    || fail "unguarded-approval-mismatch: review threads were checked before refusal"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unguarded-approval-mismatch: gh-axi pr merge was invoked"
  pass "fm-pr-merge keeps generic mismatch refusal for unguarded projects"
}

test_project_metadata_requires_one_nonempty_identity() {
  local case_dir variant rc
  for variant in missing empty duplicate; do
    case_dir=$(make_case "project-metadata-$variant")
    case "$variant" in
      missing)
        fm_write_meta "$case_dir/state/task-x1.meta" \
          'window=fm-task-x1' \
          "worktree=$case_dir/wt" \
          'kind=ship' \
          'mode=no-mistakes'
        ;;
      empty)
        fm_write_meta "$case_dir/state/task-x1.meta" \
          'window=fm-task-x1' \
          "worktree=$case_dir/wt" \
          'project=' \
          'kind=ship' \
          'mode=no-mistakes'
        ;;
      duplicate)
        fm_write_meta "$case_dir/state/task-x1.meta" \
          'window=fm-task-x1' \
          "worktree=$case_dir/wt" \
          "project=$case_dir/project" \
          "project=$case_dir/other-project" \
          'kind=ship' \
          'mode=no-mistakes'
        ;;
    esac
    add_gh_mocks "$case_dir" 1919191919191919191919191919191919191919
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh-axi-api.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "project-metadata-$variant: invalid project identity should refuse"
    assert_grep 'missing, empty, or ambiguous project identity' "$case_dir/stderr" \
      "project-metadata-$variant: refusal did not explain the invalid project identity"
    [ ! -s "$case_dir/gh-axi-api.log" ] \
      || fail "project-metadata-$variant: review threads were checked"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "project-metadata-$variant: gh-axi pr merge was invoked"
  done
  pass "fm-pr-merge requires one nonempty project identity"
}

test_duplicate_captain_approval_refuses() {
  local case_dir rc
  case_dir=$(make_case duplicate-captain-approval)
  printf '%s\n' \
    '- project [no-mistakes captain-merge] - fixture (added 2026-08-29)' \
    > "$case_dir/data/projects.md"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-api.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    --captain-approved https://github.com/example/repo/pull/55 \
    --captain-approved https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "duplicate-captain-approval: repeated approval flags should refuse"
  assert_grep '--captain-approved may be supplied only once' "$case_dir/stderr" \
    "duplicate-captain-approval: refusal did not explain the duplicate flag"
  [ ! -s "$case_dir/gh-axi-api.log" ] \
    || fail "duplicate-captain-approval: review threads were checked"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "duplicate-captain-approval: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses duplicate captain approval flags"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_unresolved_threads_refuse_before_merge() {
  local case_dir rc
  case_dir=$(make_case unresolved-threads)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_THREADS_TOTAL=13 FM_TEST_THREADS_UNRESOLVED=13 \
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/39 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unresolved-threads: fm-pr-merge should refuse an open-thread PR"
  assert_grep '13 unresolved review thread(s)' "$case_dir/stderr" \
    "unresolved-threads: refusal did not name the unresolved count"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unresolved-threads: gh-axi pr merge was invoked despite open review threads"
  pass "fm-pr-merge refuses to merge a PR with unresolved review threads"
}

test_resolved_threads_merge_normally() {
  local case_dir rc
  case_dir=$(make_case resolved-threads)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_THREADS_TOTAL=13 FM_TEST_THREADS_UNRESOLVED=0 \
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "resolved-threads: fm-pr-merge should merge when all threads are resolved"
  grep -qxF 'pr merge 40 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "resolved-threads: gh-axi pr merge was not invoked for an all-resolved PR"
  pass "fm-pr-merge merges normally when every review thread is resolved"
}

test_garbled_thread_query_refuses() {
  local case_dir rc
  case_dir=$(make_case garbled-threads)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_thread_query_garbled "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "garbled-threads: fm-pr-merge should fail closed on an unreadable thread query"
  assert_grep 'could not read the PR' "$case_dir/stderr" \
    "garbled-threads: refusal did not explain the unreadable thread query"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "garbled-threads: gh-axi pr merge was invoked despite an unreadable thread query"
  pass "fm-pr-merge fails closed when the review-thread query is unreadable"
}

test_failed_thread_query_refuses() {
  local case_dir rc
  case_dir=$(make_case failed-thread-query)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_thread_query_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-thread-query: fm-pr-merge should fail closed when the thread query errors"
  assert_grep 'could not read the PR' "$case_dir/stderr" \
    "failed-thread-query: refusal did not explain the failed thread query"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "failed-thread-query: gh-axi pr merge was invoked despite a failed thread query"
  pass "fm-pr-merge fails closed when the review-thread query itself errors"
}

test_allow_unresolved_threads_bypasses_and_logs() {
  local case_dir rc
  case_dir=$(make_case allow-unresolved)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_THREADS_TOTAL=13 FM_TEST_THREADS_UNRESOLVED=13 \
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 --allow-unresolved-threads \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "allow-unresolved: override should let the merge through"
  assert_grep '--allow-unresolved-threads set' "$case_dir/stdout" \
    "allow-unresolved: the override bypass was not logged"
  grep -qxF 'pr merge 43 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "allow-unresolved: gh-axi pr merge was not invoked under the override"
  pass "fm-pr-merge bypasses the review-thread gate under --allow-unresolved-threads and logs it"
}

test_allow_unresolved_threads_still_forwards_extra_args() {
  local case_dir rc
  case_dir=$(make_case allow-unresolved-extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_THREADS_UNRESOLVED=5 \
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
    --allow-unresolved-threads -- --merge --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "allow-unresolved-extra-args: override with extra args should merge"
  grep -qxF 'pr merge 44 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "allow-unresolved-extra-args: extra gh-axi flags were not forwarded after the override"
  pass "fm-pr-merge keeps forwarding extra flags when --allow-unresolved-threads precedes the -- separator"
}

test_over_page_size_threads_refuse_before_merge() {
  local case_dir rc
  case_dir=$(make_case over-page-size-threads)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_THREADS_TOTAL=101 FM_TEST_THREADS_UNRESOLVED=0 \
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/45 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "over-page-size-threads: fm-pr-merge should refuse a PR past the 100-thread page"
  assert_grep 'more than the 100 this check reads' "$case_dir/stderr" \
    "over-page-size-threads: refusal did not explain the 100-thread bound"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "over-page-size-threads: gh-axi pr merge was invoked despite a thread page overflow"
  pass "fm-pr-merge refuses to merge when reviewThreads.totalCount exceeds 100"
}

test_allow_flag_after_separator_does_not_bypass() {
  local case_dir rc
  case_dir=$(make_case allow-flag-after-separator)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_THREADS_TOTAL=4 FM_TEST_THREADS_UNRESOLVED=4 \
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/46 -- --allow-unresolved-threads \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "allow-flag-after-separator: flag after -- must not bypass the gate"
  assert_grep '4 unresolved review thread(s)' "$case_dir/stderr" \
    "allow-flag-after-separator: unresolved threads were not refused"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "allow-flag-after-separator: gh-axi pr merge was invoked when the override was only after --"
  pass "fm-pr-merge does not treat --allow-unresolved-threads after -- as a gate bypass"
}

test_successful_merge_appends_delivery_record() {
  local case_dir record
  case_dir=$(make_case delivery-record)
  mkdir -p "$case_dir/wt"
  printf '%s\n' 'spawn_gen=s1756150000.123.456' >> "$case_dir/state/task-x1.meta"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "delivery-record: successful merge failed"

  record=$(cat "$case_dir/data/delivery-log.jsonl")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-x1" and
    .repo == "project" and
    .pr_url == "https://github.com/example/repo/pull/57" and
    .dispatched_at == "2025-08-25T19:26:40Z" and
    .pr_opened_at == "2025-08-25T12:00:00Z" and
    .merged_at == "2025-08-25T12:10:00Z"
  ' >/dev/null || fail "delivery-record: merge wrote the wrong record: $record"
  pass "fm-pr-merge appends delivery timing after a successful merge"
}

test_timestamp_lookup_failure_warns_and_records_partial_timing() {
  local case_dir record rc
  case_dir=$(make_case timestamp-lookup-failure)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222220
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_PR_LOOKUP_FAIL=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "timestamp-lookup-failure: lookup failure must not fail the merge"
  assert_grep 'warning: could not read pull request timestamps' "$case_dir/stderr" \
    "timestamp-lookup-failure: lookup failure was not reported"
  record=$(cat "$case_dir/data/delivery-log.jsonl")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-x1" and
    .pr_opened_at == null and
    .merged_at == null
  ' >/dev/null || fail "timestamp-lookup-failure: partial record has the wrong values: $record"
  pass "fm-pr-merge reports timestamp lookup failure and records partial timing"
}

test_timestamp_parse_failure_warns_and_records_partial_timing() {
  local case_dir record rc
  case_dir=$(make_case timestamp-parse-failure)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_PR_FACTS_GARBLED=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "timestamp-parse-failure: parse failure must not fail the merge"
  assert_grep 'warning: could not parse pull request timestamps' "$case_dir/stderr" \
    "timestamp-parse-failure: parse failure was not reported"
  record=$(cat "$case_dir/data/delivery-log.jsonl")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-x1" and
    .pr_opened_at == null and
    .merged_at == null
  ' >/dev/null || fail "timestamp-parse-failure: partial record has the wrong values: $record"
  pass "fm-pr-merge reports timestamp parse failure and records partial timing"
}

test_auto_merge_waits_for_pull_request_to_land() {
  local case_dir rc
  case_dir=$(make_case auto-merge-pending)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222223
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_PR_MERGED=false FM_TEST_PR_MERGED_AT= \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/60 --auto \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "auto-merge-pending: enabling auto-merge should remain successful"
  assert_absent "$case_dir/data/delivery-log.jsonl" \
    "auto-merge-pending: an unlanded task was recorded"
  assert_grep 'is not merged; delivery timing was deferred until it lands' \
    "$case_dir/stderr" \
    "auto-merge-pending: deferred timing was not reported"
  pass "fm-pr-merge waits for auto-merge to land before recording delivery timing"
}

test_delivery_failure_does_not_block_pr_merge() {
  local case_dir rc
  case_dir=$(make_case delivery-record-failure)
  mkdir -p "$case_dir/wt"
  ln -s /dev/null "$case_dir/data/delivery-log.jsonl"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222221
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "delivery-record-failure: ledger failure must not fail the merge"
  grep -qxF 'pr merge 58 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "delivery-record-failure: gh-axi merge did not succeed"
  assert_grep 'warning: delivery timing was not recorded for task-x1' "$case_dir/stderr" \
    "delivery-record-failure: ledger failure was not logged"
  pass "fm-pr-merge logs a ledger failure without changing merge success"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_unresolved_threads_refuse_before_merge
test_resolved_threads_merge_normally
test_garbled_thread_query_refuses
test_failed_thread_query_refuses
test_allow_unresolved_threads_bypasses_and_logs
test_allow_unresolved_threads_still_forwards_extra_args
test_over_page_size_threads_refuse_before_merge
test_allow_flag_after_separator_does_not_bypass
test_captain_merge_refuses_without_approval
test_captain_approval_refuses_a_different_pr
test_matching_captain_approval_bypasses_and_logs
test_project_without_captain_merge_token_merges
test_project_absent_from_registry_merges
test_legacy_description_brackets_do_not_enable_captain_merge
test_registry_parser_failure_refuses_before_merge
test_unguarded_project_refuses_mismatched_approval
test_project_metadata_requires_one_nonempty_identity
test_duplicate_captain_approval_refuses
test_successful_merge_appends_delivery_record
test_timestamp_lookup_failure_warns_and_records_partial_timing
test_timestamp_parse_failure_warns_and_records_partial_timing
test_auto_merge_waits_for_pull_request_to_land
test_delivery_failure_does_not_block_pr_merge
