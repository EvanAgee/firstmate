#!/usr/bin/env bash
# tests/fm-api-events.test.sh - GET /events typed stream against a throwaway home.
#
# Speaks real HTTP. Touches fixture files and asserts SSE frames. Does not
# inspect server source.
set -u

# shellcheck source=tests/api-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/api-helpers.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
node -e 'process.stdout.write("fm-api-node-ok")' >/dev/null 2>&1 \
  || { echo "skip: node is not a usable Node.js"; exit 0; }

event_field() {
  local line=$1 field=$2
  LINE=$line FIELD=$field node -e '
const obj = JSON.parse(process.env.LINE);
const data = obj.data || {};
if (!Object.prototype.hasOwnProperty.call(data, process.env.FIELD)) process.exit(1);
const v = data[process.env.FIELD];
if (v === null || v === undefined) process.exit(1);
process.stdout.write(String(v));
'
}

iso_timestamp() {
  local value=$1
  DATE=$value node -e '
const v = process.env.DATE;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(v)) process.exit(1);
' || fail "timestamp was not ISO-8601: $value"
}

start_stream_home() {
  local prefix=$1
  home=$(fm_test_api_home "$prefix")
  printf 'working: seed\n' > "$home/state/demo.status"
  printf '# queue\n' > "$home/data/backlog.md"
  port=$(fm_test_api_start "$home")
}

open_events() {
  local port=$1 out=$2 line status
  fm_test_api_sse_start "$port" "$out"
  sse_pid=$FM_TEST_API_SSE_PID
  line=$(fm_test_api_sse_wait "$out" open "" 5) \
    || fail "GET /events did not open: $(cat "$out" 2>/dev/null || true)"
  status=$(fm_test_json_field "$line" status) || fail "GET /events had no status: $line"
  [ "$status" = 200 ] || fail "GET /events returned $status, wanted 200"
  sleep 0.15
}

established_count() {
  local port=$1
  command -v lsof >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1 { n++ } END { print n+0 }'
}

test_status_append_emits_task_status() {
  local home port out sse_pid line task ts
  export FM_API_EVENT_QUIET_MS=80 FM_API_EVENT_DEADLINE_MS=400 FM_API_HEARTBEAT_MS=30000
  start_stream_home api-events-status
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  printf 'working: append\n' >> "$home/state/demo.status"
  line=$(fm_test_api_sse_wait "$out" event task-status 5) \
    || fail "status append produced no task-status event: $(cat "$out")"
  task=$(event_field "$line" task) || fail "task-status missing task: $line"
  ts=$(event_field "$line" timestamp) || fail "task-status missing timestamp: $line"
  [ "$task" = demo ] || fail "task-status task $task, wanted demo"
  iso_timestamp "$ts"
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "appending a fixture status log emits task-status for that task"
}

test_backlog_edit_emits_captain_queue() {
  local home port out sse_pid line type
  export FM_API_EVENT_QUIET_MS=80 FM_API_EVENT_DEADLINE_MS=400 FM_API_HEARTBEAT_MS=30000
  start_stream_home api-events-queue
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  printf '%s\n' '- parked: demo' >> "$home/data/backlog.md"
  line=$(fm_test_api_sse_wait "$out" event captain-queue 5) \
    || fail "backlog edit produced no captain-queue event: $(cat "$out")"
  type=$(event_field "$line" type) || fail "captain-queue missing type: $line"
  [ "$type" = captain-queue ] || fail "type $type, wanted captain-queue"
  if event_field "$line" task >/dev/null 2>&1; then
    fail "captain-queue should not name a task: $line"
  fi
  iso_timestamp "$(event_field "$line" timestamp)"
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "editing the fixture captain queue emits captain-queue"
}

test_burst_coalesces_to_one_event() {
  local home port out sse_pid count
  export FM_API_EVENT_QUIET_MS=200 FM_API_EVENT_DEADLINE_MS=800 FM_API_HEARTBEAT_MS=30000
  start_stream_home api-events-burst
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  printf 'working: one\n' >> "$home/state/demo.status"
  sleep 0.05
  printf 'working: two\n' >> "$home/state/demo.status"
  sleep 0.05
  printf 'working: three\n' >> "$home/state/demo.status"
  fm_test_api_sse_wait "$out" event task-status 5 >/dev/null \
    || fail "burst produced no task-status event: $(cat "$out")"
  sleep 0.4
  count=$(fm_test_api_sse_count "$out" event task-status)
  [ "$count" = 1 ] || fail "burst emitted $count task-status events, wanted 1: $(cat "$out")"
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "a burst of writes emits one coalesced event"
}

test_continuous_burst_flushes_at_deadline() {
  local home port out sse_pid writer i
  export FM_API_EVENT_QUIET_MS=200 FM_API_EVENT_DEADLINE_MS=350 FM_API_HEARTBEAT_MS=30000
  start_stream_home api-events-deadline
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  (
    for i in $(seq 1 20); do
      printf 'working: %s\n' "$i" >> "$home/state/demo.status"
      sleep 0.08
    done
  ) &
  writer=$!
  fm_test_api_sse_wait "$out" event task-status 2 >/dev/null \
    || fail "continuous burst did not flush by its deadline: $(cat "$out")"
  kill -0 "$writer" 2>/dev/null \
    || fail "continuous burst ended before the deadline event arrived"
  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "a continuous burst flushes by its deadline"
}

test_hidden_bookkeeping_emits_nothing() {
  local home port out sse_pid count
  export FM_API_EVENT_QUIET_MS=80 FM_API_EVENT_DEADLINE_MS=400 FM_API_HEARTBEAT_MS=30000
  start_stream_home api-events-hidden
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  printf 'x\n' > "$home/state/.hash-xyz"
  printf 'x\n' > "$home/state/.watch.lock"
  printf 'x\n' > "$home/data/.hidden"
  sleep 0.7
  count=$(fm_test_api_sse_count "$out" event)
  [ "$count" = 0 ] || fail "hidden files emitted events: $(cat "$out")"
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "hidden bookkeeping files emit nothing"
}

test_mapped_unmapped_and_created_types() {
  local home port out sse_pid line task
  export FM_API_EVENT_QUIET_MS=80 FM_API_EVENT_DEADLINE_MS=400 FM_API_HEARTBEAT_MS=30000
  start_stream_home api-events-types
  out="$home/../events.ndjson"
  open_events "$port" "$out"

  fm_write_meta "$home/state/new-task.meta" "project=demo" "mode=direct-PR"
  line=$(fm_test_api_sse_wait "$out" event task-created 5) \
    || fail "new meta produced no task-created event: $(cat "$out")"
  task=$(event_field "$line" task) || fail "task-created missing task: $line"
  [ "$task" = new-task ] || fail "task-created task $task, wanted new-task"

  printf '{}\n' > "$home/config/crew-dispatch.json"
  fm_test_api_sse_wait "$out" event rig-config 5 >/dev/null \
    || fail "rig config write produced no rig-config event: $(cat "$out")"

  printf 'note\n' > "$home/data/learnings.md"
  fm_test_api_sse_wait "$out" event changed 5 >/dev/null \
    || fail "unmapped write produced no changed event: $(cat "$out")"

  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "task-created, rig-config, and unmapped changed events fire"
}

test_absent_data_dir_then_backlog_emits_captain_queue() {
  local home port out sse_pid line type
  export FM_API_EVENT_QUIET_MS=80 FM_API_EVENT_DEADLINE_MS=400 FM_API_HEARTBEAT_MS=30000
  home=$(fm_test_api_home api-events-late-data)
  rmdir "$home/data"
  [ ! -e "$home/data" ] || fail "fixture data/ was still present before start"
  port=$(fm_test_api_start "$home")
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  mkdir -p "$home/data"
  printf '%s\n' '- parked: demo' > "$home/data/backlog.md"
  line=$(fm_test_api_sse_wait "$out" event captain-queue 5) \
    || fail "late data/backlog.md produced no captain-queue event: $(cat "$out")"
  type=$(event_field "$line" type) || fail "captain-queue missing type: $line"
  [ "$type" = captain-queue ] || fail "type $type, wanted captain-queue"
  if event_field "$line" task >/dev/null 2>&1; then
    fail "captain-queue should not name a task: $line"
  fi
  iso_timestamp "$(event_field "$line" timestamp)"
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "creating data/backlog.md after start emits captain-queue"
}

test_heartbeat_and_disconnect_leaks_nothing() {
  local home port out sse_pid line n i resp
  export FM_API_EVENT_QUIET_MS=80 FM_API_EVENT_DEADLINE_MS=400 FM_API_HEARTBEAT_MS=200
  start_stream_home api-events-heartbeat
  out="$home/../events.ndjson"
  open_events "$port" "$out"
  line=$(fm_test_api_sse_wait "$out" comment heartbeat 3) \
    || fail "no heartbeat comment on the interval: $(cat "$out")"
  assert_contains "$line" heartbeat "heartbeat frame: $line"

  fm_test_api_sse_stop "$sse_pid"
  i=0
  n=$(established_count "$port")
  while [ "$n" != unknown ] && [ "$n" != 0 ] && [ "$i" -lt 20 ]; do
    sleep 0.1
    n=$(established_count "$port")
    i=$((i + 1))
  done
  if [ "$n" != unknown ]; then
    [ "$n" = 0 ] || fail "client disconnect left $n established connections on $port"
  fi
  resp=$(fm_test_api_http "$port" /health)
  code=${resp%%$'\n'*}
  [ "$code" = 200 ] || fail "health died after SSE disconnect: $resp"

  out="$home/../events-reopen.ndjson"
  open_events "$port" "$out"
  printf 'working: after-disconnect\n' >> "$home/state/demo.status"
  fm_test_api_sse_wait "$out" event task-status 5 >/dev/null \
    || fail "new client after disconnect got no event: $(cat "$out")"
  fm_test_api_sse_stop "$sse_pid"
  fm_test_api_stop "$home"
  pass "heartbeats arrive on an interval and disconnecting leaks nothing"
}

test_status_append_emits_task_status
test_backlog_edit_emits_captain_queue
test_burst_coalesces_to_one_event
test_continuous_burst_flushes_at_deadline
test_hidden_bookkeeping_emits_nothing
test_mapped_unmapped_and_created_types
test_absent_data_dir_then_backlog_emits_captain_queue
test_heartbeat_and_disconnect_leaks_nothing

echo "# fm-api-events.test.sh: all assertions passed"
