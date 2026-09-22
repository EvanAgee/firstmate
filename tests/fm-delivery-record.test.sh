#!/usr/bin/env bash
# Behavior tests for the private delivery-timing ledger written after a task lands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECORD="$ROOT/bin/fm-delivery-record.sh"
BACKFILL="$ROOT/bin/fm-delivery-backfill.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-record-tests)

make_database() {
  local db=$1 project=$2
  sqlite3 "$db" <<SQL
CREATE TABLE repos (
  id TEXT PRIMARY KEY,
  working_path TEXT NOT NULL UNIQUE
);
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL,
  branch TEXT NOT NULL,
  pr_url TEXT,
  parked_ms INTEGER,
  created_at INTEGER NOT NULL
);
CREATE TABLE step_results (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  step_name TEXT NOT NULL,
  duration_ms INTEGER
);
CREATE TABLE step_rounds (
  id TEXT PRIMARY KEY,
  step_result_id TEXT NOT NULL,
  round INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE agent_invocations (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  purpose TEXT NOT NULL,
  duration_ms INTEGER NOT NULL
);
INSERT INTO repos VALUES ('repo-1', '$project');
INSERT INTO runs VALUES (
  'run-1', 'repo-1', 'fm/task-one',
  'https://github.com/example/widget/pull/88', 30000, 1756150100
);
INSERT INTO step_results VALUES ('review-1', 'run-1', 'review', 180000);
INSERT INTO step_results VALUES ('test-1', 'run-1', 'test', 180000);
INSERT INTO step_results VALUES ('document-1', 'run-1', 'document', 240000);
INSERT INTO step_rounds VALUES ('round-1', 'review-1', 1, 60000, 1756150110);
INSERT INTO step_rounds VALUES ('round-2', 'review-1', 2, 120000, 1756150170);
INSERT INTO agent_invocations VALUES ('fix-1', 'run-1', 'review-fix', 90000);
SQL
}

test_record_shape_and_append() {
  local home project db ledger record
  home="$TMP_ROOT/shape/home"
  project="$home/projects/widget"
  db="$home/state.sqlite"
  ledger="$home/data/delivery-log.jsonl"
  mkdir -p "$home/state" "$home/data" "$project"
  fm_write_meta "$home/state/task-one.meta" \
    "project=$project" \
    'spawn_gen=s1756150000.123.456'
  make_database "$db" "$project"
  printf '%s\n' '{"task_id":"older-task"}' > "$ledger"

  FM_HOME="$home" FM_DELIVERY_DB="$db" \
    "$RECORD" task-one \
      --repo widget \
      --project-path "$project" \
      --branch fm/task-one \
      --pr-url https://github.com/example/widget/pull/88 \
      --pr-opened-at 2025-08-25T12:00:00Z \
      --merged-at 2025-08-25T12:10:00Z \
    || fail "delivery record command failed"

  [ "$(wc -l < "$ledger" | tr -d ' ')" = 2 ] \
    || fail "delivery record replaced the existing ledger or wrote more than one line"
  record=$(tail -n 1 "$ledger")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-one" and
    .repo == "widget" and
    .pr_url == "https://github.com/example/widget/pull/88" and
    .dispatched_at == "2025-08-25T19:26:40Z" and
    .no_mistakes_started_at == "2025-08-25T19:28:20Z" and
    .pr_opened_at == "2025-08-25T12:00:00Z" and
    .merged_at == "2025-08-25T12:10:00Z" and
    .review_rounds == [
      {"round": 1, "minutes": 1},
      {"round": 2, "minutes": 2}
    ] and
    .active_fix_minutes == 1.5 and
    .test_minutes == 3 and
    .document_minutes == 4 and
    .parked_ms == 30000
  ' >/dev/null || fail "delivery record has the wrong shape or values: $record"
  pass "delivery record appends one complete JSON line without replacing history"
}

test_repeated_task_is_not_duplicated() {
  local home project db ledger
  home="$TMP_ROOT/idempotent/home"
  project="$home/projects/widget"
  db="$home/state.sqlite"
  ledger="$home/data/delivery-log.jsonl"
  mkdir -p "$home/state" "$home/data" "$project"
  make_database "$db" "$project"

  FM_HOME="$home" FM_DELIVERY_DB="$db" \
    "$RECORD" task-one \
      --repo widget \
      --project-path "$project" \
      --branch fm/task-one \
      --pr-url https://github.com/example/widget/pull/88 \
      --pr-opened-at 2025-08-25T12:00:00Z \
      --merged-at 2025-08-25T12:10:00Z \
    || fail "first delivery record command failed"
  FM_HOME="$home" FM_DELIVERY_DB="$db" \
    "$RECORD" task-one \
      --repo widget \
      --project-path "$project" \
      --branch fm/task-one \
      --pr-url https://github.com/example/widget/pull/88 \
      --pr-opened-at 2025-08-25T12:00:00Z \
      --merged-at 2025-08-25T12:10:00Z \
    || fail "repeated delivery record command failed"

  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "repeated delivery record duplicated task-one"
  pass "delivery record keeps one line per task when called again"
}

test_partial_record_uses_null_for_unknown_facts() {
  local home ledger record
  home="$TMP_ROOT/partial/home"
  ledger="$home/data/delivery-log.jsonl"
  mkdir -p "$home"

  FM_HOME="$home" FM_DELIVERY_DB="$home/missing-state.sqlite" \
    "$RECORD" task-without-history --repo widget \
    || fail "partial delivery record command failed"

  record=$(cat "$ledger")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-without-history" and
    .repo == "widget" and
    .pr_url == null and
    .dispatched_at == null and
    .no_mistakes_started_at == null and
    .pr_opened_at == null and
    .merged_at == null and
    .review_rounds == null and
    .active_fix_minutes == null and
    .test_minutes == null and
    .document_minutes == null and
    .parked_ms == null
  ' >/dev/null || fail "partial record invented an unavailable fact: $record"
  pass "delivery record keeps every unavailable timing fact as JSON null"
}

test_sqlite_failure_warns_and_records_partial_timing() {
  local home db ledger record rc
  home="$TMP_ROOT/sqlite-failure/home"
  db="$home/broken.sqlite"
  ledger="$home/data/delivery-log.jsonl"
  mkdir -p "$home"
  printf '%s\n' 'not a sqlite database' > "$db"

  set +e
  FM_HOME="$home" FM_DELIVERY_DB="$db" \
    "$RECORD" task-with-broken-history --repo widget \
      > "$home/stdout" 2> "$home/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "sqlite-failure: timing lookup failure must not block the record"
  assert_grep 'warning: could not read no-mistakes timing for task-with-broken-history' \
    "$home/stderr" \
    "sqlite-failure: timing lookup failure was not reported"
  record=$(cat "$ledger")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-with-broken-history" and
    .no_mistakes_started_at == null and
    .review_rounds == null and
    .active_fix_minutes == null and
    .test_minutes == null and
    .document_minutes == null and
    .parked_ms == null
  ' >/dev/null || fail "sqlite-failure: partial timing record has the wrong values: $record"
  pass "delivery record reports a SQLite failure and keeps partial timing"
}

test_dispatch_conversion_failure_warns_and_records_null() {
  local home fakebin ledger record rc
  home="$TMP_ROOT/dispatch-conversion-failure/home"
  fakebin="$home/fakebin"
  ledger="$home/data/delivery-log.jsonl"
  mkdir -p "$home/state" "$fakebin"
  fm_write_meta "$home/state/task-with-bad-dispatch.meta" \
    'spawn_gen=s1756150000.123.456'
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/date"

  set +e
  FM_HOME="$home" FM_DELIVERY_DB="$home/missing-state.sqlite" PATH="$fakebin:$PATH" \
    "$RECORD" task-with-bad-dispatch --repo widget \
      > "$home/stdout" 2> "$home/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dispatch-conversion-failure: conversion failure must keep a partial record"
  assert_grep 'warning: could not convert dispatch timestamp for task-with-bad-dispatch' \
    "$home/stderr" \
    "dispatch-conversion-failure: conversion failure was not reported"
  record=$(cat "$ledger")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-with-bad-dispatch" and .dispatched_at == null
  ' >/dev/null || fail "dispatch-conversion-failure: record did not preserve a null timestamp: $record"
  pass "delivery record reports dispatch conversion failure and records null"
}

test_backfill_uses_merged_limit_and_is_idempotent() {
  local home project db ledger fakebin record
  home="$TMP_ROOT/backfill/home"
  project="$home/projects/aos"
  db="$home/state.sqlite"
  ledger="$home/data/delivery-log.jsonl"
  fakebin="$home/fakebin"
  mkdir -p "$project" "$fakebin"
  make_database "$db" "$project"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "$*" in
  *'repo:SuperDuperIT/aos is:pr is:merged sort:updated-desc'*'first: 10'*)
    printf '%s\n' '[1]: "88\tfm/task-one\t2025-08-25T12:00:00Z\t2025-08-25T12:10:00Z\thttps://github.com/example/widget/pull/88"'
    ;;
  *'is:pr is:merged sort:updated-desc'*'first: 10'*)
    printf '%s\n' '[]'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh-axi"

  FM_HOME="$home" FM_DELIVERY_DB="$db" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
    PATH="$fakebin:$PATH" \
    "$BACKFILL" --limit 10 || fail "first delivery backfill failed"
  FM_HOME="$home" FM_DELIVERY_DB="$db" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
    PATH="$fakebin:$PATH" \
    "$BACKFILL" --limit 10 || fail "repeated delivery backfill failed"

  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "repeated backfill duplicated an existing task"
  record=$(cat "$ledger")
  printf '%s\n' "$record" | jq -e '
    .task_id == "task-one" and
    .repo == "aos" and
    .dispatched_at == null and
    .no_mistakes_started_at == "2025-08-25T19:28:20Z" and
    (.review_rounds | length) == 2
  ' >/dev/null || fail "backfill record has the wrong values: $record"
  [ "$(wc -l < "$home/gh-axi.log" | tr -d ' ')" = 6 ] \
    || fail "backfill did not query each repository on both runs"
  pass "delivery backfill limits merged pull requests and remains idempotent"
}

test_record_shape_and_append
test_repeated_task_is_not_duplicated
test_partial_record_uses_null_for_unknown_facts
test_sqlite_failure_warns_and_records_partial_timing
test_dispatch_conversion_failure_warns_and_records_null
test_backfill_uses_merged_limit_and_is_idempotent
