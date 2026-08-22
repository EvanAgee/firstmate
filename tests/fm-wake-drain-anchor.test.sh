#!/usr/bin/env bash
# Behavior tests for the heartbeat ANCHOR block and session odometer
# (bin/fm-anchor-lib.sh, wired into bin/fm-wake-drain.sh; items 1 and 2 of
# fm-anti-drift-hardening). The drain owns the wiring; these tests exercise the
# real drain script over crafted wake queues and durable state, asserting its
# printed output and the odometer file, never the anchor library's source.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-anchor-tests)

make_home() {  # <name> -> dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/root"
  printf '# Captain preferences (home-local)\n\n## Working style\n\n- batch updates\n- no fable for scouts\n\n## Other\nx\n' \
    > "$dir/data/captain.md"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:t"
  printf 'working: x\n' > "$dir/state/task.status"
  printf '%s' "$dir"
}

run_drain() {  # <dir> [env...]
  local dir=$1
  shift
  env "$@" \
    FM_ROOT_OVERRIDE="$dir/root" \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    "$DRAIN" 2>/dev/null
}

test_anchor_prints_only_on_heartbeat_wakes() {
  local dir out
  dir=$(make_home heartbeat-only)
  append_wake "$dir/state" heartbeat - "no changes"
  out=$(run_drain "$dir")
  grep -F 'ANCHOR (durable truth re-read on this heartbeat' <<< "$out" >/dev/null \
    || fail "heartbeat drain printed no ANCHOR block"
  grep -F 'standing steers (data/captain.md ## Working style):' <<< "$out" >/dev/null \
    || fail "ANCHOR lost the standing-steers excerpt"
  grep -F '  - batch updates' <<< "$out" >/dev/null \
    || fail "ANCHOR lost the steers content"
  grep -F 'open decisions: 0 | in flight tasks: 1' <<< "$out" >/dev/null \
    || grep -F 'open decisions: 0 | in-flight tasks: 1' <<< "$out" >/dev/null \
    || fail "ANCHOR lost the counts line: $(grep -F 'open decisions' <<< "$out")"

  # A non-heartbeat wake never prints it.
  dir=$(make_home signal-only)
  printf 'blocked [key=creds]: waiting on credits\n' > "$dir/state/task.status"
  append_wake "$dir/state" signal task "task.status"
  out=$(run_drain "$dir")
  if grep -F 'ANCHOR (' <<< "$out" >/dev/null; then
    fail "a signal wake printed the ANCHOR block, which would make every drain bear its cost: $(grep -F 'ANCHOR' <<< "$out")"
  fi
  pass "the ANCHOR block prints only on heartbeat wakes"
}

test_anchor_is_bounded() {
  local dir out lines
  dir=$(make_home bounded)
  {
    printf '# C\n\n## Working style\n\n'
    seq 1 40 | while read -r i; do printf '%s\n' "- steer $i"; done
    printf '\n## Other\nx\n'
  } > "$dir/data/captain.md"
  append_wake "$dir/state" heartbeat - "no changes"
  out=$(run_drain "$dir" FM_ANCHOR_STEERS_MAX_LINES=12)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" -le 25 ] || fail "a 40-steer captain.md burst the ANCHOR bound: $lines lines"
  grep -F 'more lines; full file' <<< "$out" >/dev/null \
    || fail "the bounded excerpt lost its omission pointer"
  pass "a long captain.md yields a bounded excerpt with an omission pointer"
}

test_odometer_starts_on_first_drain_and_counts_wakes() {
  local dir
  dir=$(make_home odometer)
  [ ! -f "$dir/state/.session-odometer" ] || fail "precursor odometer state already present"
  append_wake "$dir/state" heartbeat - "no changes"
  run_drain "$dir" >/dev/null
  [ -f "$dir/state/.session-odometer" ] \
    || fail "the first drain wrote no odometer record"
  grep -F 'wakes=1' "$dir/state/.session-odometer" >/dev/null \
    || fail "the odometer did not count the first wake record: $(cat "$dir/state/.session-odometer")"
  # Acknowledge the presented row (its ack path is drain-owned and is covered
  # by the queue suites; here the fixture just wants a clean second drain).
  : > "$dir/state/.wake-queue"
  append_wake "$dir/state" signal task "task.status"
  run_drain "$dir" >/dev/null
  grep -F 'wakes=2' "$dir/state/.session-odometer" >/dev/null \
    || fail "the odometer did not carry its count across drains: $(cat "$dir/state/.session-odometer")"
  pass "the odometer starts on the first drain and counts handled wake records"
}

test_odometer_prompts_advice_over_threshold_via_next_anchor() {
  local dir out
  dir=$(make_home advice)
  printf 'pid=whatever\nstarted_epoch=1\nwakes=0\n' > "$dir/state/.session-odometer"
  printf 'whatever\n' > "$dir/state/.lock"
  append_wake "$dir/state" heartbeat - "no changes"
  out=$(run_drain "$dir" FM_ODOMETER_MAX_AGE=3600)
  grep -F 'odometer: session over threshold' <<< "$out" >/dev/null \
    || fail "a fresh session over the age threshold produced no advice line"
  grep -iF 'fresh session is recommended' <<< "$out" >/dev/null \
    || fail "the advice line lost its rationale text"

  # And under-threshold sessions don't nag.
  dir=$(make_home under-threshold)
  append_wake "$dir/state" heartbeat - "no changes"
  out=$(run_drain "$dir" FM_ODOMETER_MAX_AGE=999999 FM_ODOMETER_MAX_WAKES=999999)
  if grep -F 'odometer: session over threshold' <<< "$out" >/dev/null; then
    fail "a fresh young session still got restart advice"
  fi
  pass "the ANCHOR prints the restart advice exactly when a configured threshold is exceeded"
}

test_config_file_threshold_binds() {
  local dir out
  dir=$(make_home configfile)
  printf '0 999\n' > "$dir/config/session-odometer"
  append_wake "$dir/state" heartbeat - "no changes"
  out=$(run_drain "$dir")
  grep -F 'odometer: session over threshold' <<< "$out" >/dev/null \
    || fail "config/session-odometer's age-0 threshold produced no advice"
  pass "config/session-odometer thresholds bind the odometer advice"
}

test_heartbeat_drain_touches_last_anchor() {
  local dir before after
  dir=$(make_home last-anchor)
  [ ! -f "$dir/state/.last-anchor" ] || fail "precursor last-anchor state already present"
  append_wake "$dir/state" heartbeat - "no changes"
  run_drain "$dir" >/dev/null
  [ -f "$dir/state/.last-anchor" ] \
    || fail "a heartbeat drain that printed ANCHOR left no .last-anchor stamp"

  dir=$(make_home last-anchor-signal)
  printf 'blocked [key=creds]: waiting on credits\n' > "$dir/state/task.status"
  append_wake "$dir/state" signal task "task.status"
  run_drain "$dir" >/dev/null
  [ ! -f "$dir/state/.last-anchor" ] \
    || fail "a signal drain stamped .last-anchor even though ANCHOR must stay heartbeat-only"

  dir=$(make_home last-anchor-refresh)
  touch "$dir/state/.last-anchor"
  before=$(if [ "$(uname)" = Darwin ]; then stat -f %m "$dir/state/.last-anchor"; else stat -c %Y "$dir/state/.last-anchor"; fi)
  sleep 1
  append_wake "$dir/state" heartbeat - "no changes"
  run_drain "$dir" >/dev/null
  after=$(if [ "$(uname)" = Darwin ]; then stat -f %m "$dir/state/.last-anchor"; else stat -c %Y "$dir/state/.last-anchor"; fi)
  [ "$after" -gt "$before" ] \
    || fail "a later heartbeat drain did not refresh .last-anchor ($before -> $after)"
  pass "heartbeat drains stamp .last-anchor; non-heartbeat drains do not"
}

test_flags_surface_when_present() {
  local dir out
  dir=$(make_home flags)
  printf '2026-08-21T00:00:00Z\n' > "$dir/state/.github-down"
  printf 'guard-key\n' > "$dir/state/.guard-watcher-stale-banner"
  append_wake "$dir/state" heartbeat - "no changes"
  out=$(run_drain "$dir")
  grep -F 'flags:' <<< "$out" >/dev/null || fail "an outage's clone-staleness flag never surfaced in ANCHOR"
  grep -F 'github-down' <<< "$out" >/dev/null || fail "the github-down flag is missing from ANCHOR flags"
  pass "stale-clone and watcher-down flags surface inside the ANCHOR block"
}

test_anchor_prints_only_on_heartbeat_wakes
test_anchor_is_bounded
test_odometer_starts_on_first_drain_and_counts_wakes
test_odometer_prompts_advice_over_threshold_via_next_anchor
test_config_file_threshold_binds
test_flags_surface_when_present
test_heartbeat_drain_touches_last_anchor
