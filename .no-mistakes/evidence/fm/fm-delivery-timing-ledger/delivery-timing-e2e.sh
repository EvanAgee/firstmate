#!/usr/bin/env bash
set -eu

ROOT=/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M1CS6VW1MTCG8E0NW73WNG7R
EVIDENCE=/Users/evanagee/.no-mistakes/evidence/01M1CS6VW1MTCG8E0NW73WNG7R
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-delivery-evidence.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

chmod +x "$EVIDENCE/mock-gh-axi" "$EVIDENCE/mock-gh" "$EVIDENCE/mock-guard"

LEDGER_HOME="$FIXTURE/ledger-home"
LEDGER_PROJECT="$LEDGER_HOME/projects/widget"
LEDGER_DB="$LEDGER_HOME/state.sqlite"
LEDGER="$LEDGER_HOME/data/delivery-log.jsonl"
mkdir -p "$LEDGER_HOME/state" "$LEDGER_HOME/data" "$LEDGER_PROJECT"
printf '%s\n' \
  "project=$LEDGER_PROJECT" \
  'spawn_gen=s1756150000.123.456' \
  > "$LEDGER_HOME/state/task-one.meta"
printf '%s\n' '{"task_id":"older-task","repo":"archive"}' > "$LEDGER"

sqlite3 "$LEDGER_DB" <<SQL
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, pr_url TEXT, parked_ms INTEGER, created_at INTEGER NOT NULL);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, duration_ms INTEGER);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL, duration_ms INTEGER NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, purpose TEXT NOT NULL, duration_ms INTEGER NOT NULL);
INSERT INTO repos VALUES ('repo-1', '$LEDGER_PROJECT');
INSERT INTO runs VALUES ('run-1', 'repo-1', 'fm/task-one', 'https://github.com/example/widget/pull/88', 30000, 1756150100);
INSERT INTO step_results VALUES ('review-1', 'run-1', 'review', 180000);
INSERT INTO step_results VALUES ('test-1', 'run-1', 'test', 180000);
INSERT INTO step_results VALUES ('document-1', 'run-1', 'document', 240000);
INSERT INTO step_rounds VALUES ('round-1', 'review-1', 1, 60000, 1756150110);
INSERT INTO step_rounds VALUES ('round-2', 'review-1', 2, 120000, 1756150170);
INSERT INTO agent_invocations VALUES ('fix-1', 'run-1', 'review-fix', 90000);
SQL

record_full() {
  FM_HOME="$LEDGER_HOME" FM_DELIVERY_DB="$LEDGER_DB" \
    "$ROOT/bin/fm-delivery-record.sh" task-one \
      --repo widget \
      --project-path "$LEDGER_PROJECT" \
      --branch fm/task-one \
      --pr-url https://github.com/example/widget/pull/88 \
      --pr-opened-at 2025-08-25T12:00:00Z \
      --merged-at 2025-08-25T12:10:00Z
}

record_full
record_full
FM_HOME="$LEDGER_HOME" FM_DELIVERY_DB="$LEDGER_HOME/missing.sqlite" \
  "$ROOT/bin/fm-delivery-record.sh" task-partial --repo widget

jq -e -s '
  length == 3 and
  (map(select(.task_id == "older-task")) | length) == 1 and
  (map(select(.task_id == "task-one")) | length) == 1 and
  (map(select(.task_id == "task-partial")) | length) == 1 and
  (map(select(.task_id == "task-one"))[0] | keys | sort) == ([
    "active_fix_minutes", "dispatched_at", "document_minutes", "merged_at",
    "no_mistakes_started_at", "parked_ms", "pr_opened_at", "pr_url", "repo",
    "review_rounds", "task_id", "test_minutes"
  ] | sort) and
  (map(select(.task_id == "task-partial"))[0] |
    .pr_url == null and .dispatched_at == null and
    .no_mistakes_started_at == null and .pr_opened_at == null and
    .merged_at == null and .review_rounds == null and
    .active_fix_minutes == null and .test_minutes == null and
    .document_minutes == null and .parked_ms == null)
' "$LEDGER" >/dev/null
cp "$LEDGER" "$EVIDENCE/delivery-ledger.jsonl"

BACKFILL_HOME="$FIXTURE/backfill-home"
BACKFILL_PROJECT="$BACKFILL_HOME/projects/aos"
BACKFILL_DB="$BACKFILL_HOME/state.sqlite"
BACKFILL_LOG="$BACKFILL_HOME/gh-axi.log"
mkdir -p "$BACKFILL_PROJECT" "$BACKFILL_HOME/fakebin"
ln -s "$EVIDENCE/mock-gh-axi" "$BACKFILL_HOME/fakebin/gh-axi"
sqlite3 "$BACKFILL_DB" <<SQL
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, pr_url TEXT, parked_ms INTEGER, created_at INTEGER NOT NULL);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, duration_ms INTEGER);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL, duration_ms INTEGER NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, purpose TEXT NOT NULL, duration_ms INTEGER NOT NULL);
INSERT INTO repos VALUES ('repo-aos', '$BACKFILL_PROJECT');
INSERT INTO runs VALUES ('run-backfill', 'repo-aos', 'fm/task-backfill', 'https://github.com/SuperDuperIT/aos/pull/91', 15000, 1756238500);
INSERT INTO step_results VALUES ('review-backfill', 'run-backfill', 'review', 60000);
INSERT INTO step_rounds VALUES ('round-backfill', 'review-backfill', 1, 60000, 1756238510);
SQL
FM_HOME="$BACKFILL_HOME" FM_DELIVERY_DB="$BACKFILL_DB" \
  FM_EVIDENCE_GH_MODE=backfill FM_EVIDENCE_GH_LOG="$BACKFILL_LOG" \
  PATH="$BACKFILL_HOME/fakebin:$PATH" \
  "$ROOT/bin/fm-delivery-backfill.sh" --limit 10
FM_HOME="$BACKFILL_HOME" FM_DELIVERY_DB="$BACKFILL_DB" \
  FM_EVIDENCE_GH_MODE=backfill FM_EVIDENCE_GH_LOG="$BACKFILL_LOG" \
  PATH="$BACKFILL_HOME/fakebin:$PATH" \
  "$ROOT/bin/fm-delivery-backfill.sh" --limit 10
[ "$(wc -l < "$BACKFILL_HOME/data/delivery-log.jsonl" | tr -d ' ')" = 1 ]
cp "$BACKFILL_HOME/data/delivery-log.jsonl" "$EVIDENCE/backfill-ledger.jsonl"

PR_CASE="$FIXTURE/pr-failure"
mkdir -p "$PR_CASE/state" "$PR_CASE/data" "$PR_CASE/fakebin" "$PR_CASE/wt" "$PR_CASE/project"
printf '%s\n' \
  'window=fm-task-pr-failure' \
  "worktree=$PR_CASE/wt" \
  "project=$PR_CASE/project" \
  'kind=ship' \
  'mode=no-mistakes' \
  > "$PR_CASE/state/task-pr-failure.meta"
ln -s /dev/null "$PR_CASE/data/delivery-log.jsonl"
ln -s "$EVIDENCE/mock-gh-axi" "$PR_CASE/fakebin/gh-axi"
ln -s "$EVIDENCE/mock-gh" "$PR_CASE/fakebin/gh"
set +e
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PR_CASE" \
  FM_STATE_OVERRIDE="$PR_CASE/state" FM_DATA_OVERRIDE="$PR_CASE/data" \
  FM_EVIDENCE_GH_MODE=pr FM_EVIDENCE_GH_LOG="$PR_CASE/gh-axi.log" \
  PATH="$PR_CASE/fakebin:$PATH" \
  "$ROOT/bin/fm-pr-merge.sh" task-pr-failure \
    https://github.com/example/repo/pull/58 \
    > "$PR_CASE/stdout" 2> "$PR_CASE/stderr"
PR_RC=$?
set -e
[ "$PR_RC" -eq 0 ]
grep -qxF 'pr merge 58 --repo example/repo --squash' "$PR_CASE/gh-axi.log"
grep -qF 'warning: delivery timing was not recorded for task-pr-failure' "$PR_CASE/stderr"

LOCAL_CASE="$FIXTURE/local-failure"
LOCAL_PROJECT="$LOCAL_CASE/project"
mkdir -p "$LOCAL_CASE/state" "$LOCAL_CASE/data" "$LOCAL_CASE/bin" "$LOCAL_PROJECT"
cp "$EVIDENCE/mock-guard" "$LOCAL_CASE/bin/fm-guard.sh"
git -C "$LOCAL_PROJECT" init -q
git -C "$LOCAL_PROJECT" -c user.name='Evidence' -c user.email='evidence@example.invalid' commit -q --allow-empty -m initial
git -C "$LOCAL_PROJECT" branch -M main
git -C "$LOCAL_PROJECT" checkout -q -b fm/task-local-failure
git -C "$LOCAL_PROJECT" -c user.name='Evidence' -c user.email='evidence@example.invalid' commit -q --allow-empty -m delivery
git -C "$LOCAL_PROJECT" checkout -q main
LOCAL_BEFORE=$(git -C "$LOCAL_PROJECT" rev-parse main)
printf '%s\n' \
  "project=$LOCAL_PROJECT" \
  'mode=local-only' \
  > "$LOCAL_CASE/state/task-local-failure.meta"
ln -s /dev/null "$LOCAL_CASE/data/delivery-log.jsonl"
set +e
FM_ROOT_OVERRIDE="$LOCAL_CASE" FM_STATE_OVERRIDE="$LOCAL_CASE/state" \
  FM_DATA_OVERRIDE="$LOCAL_CASE/data" \
  "$ROOT/bin/fm-merge-local.sh" task-local-failure \
    > "$LOCAL_CASE/stdout" 2> "$LOCAL_CASE/stderr"
LOCAL_RC=$?
set -e
LOCAL_AFTER=$(git -C "$LOCAL_PROJECT" rev-parse main)
[ "$LOCAL_RC" -eq 0 ]
[ "$LOCAL_BEFORE" != "$LOCAL_AFTER" ]
git -C "$LOCAL_PROJECT" merge-base --is-ancestor fm/task-local-failure main
grep -qF 'warning: delivery timing was not recorded for task-local-failure' "$LOCAL_CASE/stderr"

{
  printf '%s\n' 'DELIVERY LEDGER AFTER APPEND, DUPLICATE RETRY, AND PARTIAL RECORD'
  jq -c . "$LEDGER"
  printf '\n%s\n' 'TASK COUNTS'
  jq -s -c 'group_by(.task_id) | map({task_id: .[0].task_id, records: length})' "$LEDGER"
  printf '\n%s\n' 'COMPLETE TIMING RECORD'
  jq -c 'select(.task_id == "task-one")' "$LEDGER"
  printf '\n%s\n' 'BACKFILL RUN TWICE'
  printf 'ledger_lines=%s github_queries=%s\n' \
    "$(wc -l < "$BACKFILL_HOME/data/delivery-log.jsonl" | tr -d ' ')" \
    "$(wc -l < "$BACKFILL_LOG" | tr -d ' ')"
  jq -c . "$BACKFILL_HOME/data/delivery-log.jsonl"
  printf '\n%s\n' 'PULL REQUEST MERGE WITH UNWRITABLE LEDGER'
  printf 'exit_code=%s\n' "$PR_RC"
  grep -F 'pr merge ' "$PR_CASE/gh-axi.log"
  grep -F 'delivery timing was not recorded' "$PR_CASE/stderr"
  printf '\n%s\n' 'LOCAL FAST-FORWARD WITH UNWRITABLE LEDGER'
  printf 'exit_code=%s main_before=%s main_after=%s\n' "$LOCAL_RC" "$LOCAL_BEFORE" "$LOCAL_AFTER"
  cat "$LOCAL_CASE/stdout"
  grep -F 'delivery timing was not recorded' "$LOCAL_CASE/stderr"
} > "$EVIDENCE/delivery-timing-e2e.txt"

cat "$EVIDENCE/delivery-timing-e2e.txt"
