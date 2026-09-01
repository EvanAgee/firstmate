#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

sha256_value() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

base64_value() {  # <text>
  printf '%s' "$1" | node -e '
    const chunks = [];
    process.stdin.on("data", (chunk) => { chunks.push(chunk); });
    process.stdin.on("end", () => {
      process.stdout.write(Buffer.concat(chunks).toString("base64"));
    });
  '
}

# The last recorded value of one origin metadata field, read the way the script
# itself reads it: the record is append-only, so the final line wins.
meta_value_in() {  # <home> <id> <field>
  grep "^$3=" "$1/state/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# A captain who declines a held decision leaves no follow-up work to route, so the
# routed close path cannot express the answer. The unrouted close path must record
# that answer durably while still refusing to release work the hold blocks.
test_declined_decision_closes_without_routed_work() {
  local home id hold routed_hold json show
  home=$(make_home declined-decision)
  id=sample-benchmark-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample benchmarks" --kind scout --repo sample --start >/dev/null \
    || fail "could not create declined-decision origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample benchmark review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" half-run \
    --title "Choose the sample half run" --reason "captain half-run choice pending" --repo sample) \
    || fail "could not register the declinable hold"
  run_decisions "$home" complete "$id" half-run >/dev/null \
    || fail "completion failed for the declinable hold"

  printf '' > "$home/empty-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/empty-decision.txt" \
    > "$home/empty-decline.out" 2> "$home/empty-decline.err"; then
    fail "decline accepted an empty captain decision"
  fi
  if run_decisions "$home" decline "$id" half-run > "$home/bare-decline.out" 2> "$home/bare-decline.err"; then
    fail "decline accepted a close with no captain decision file at all"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused decline closed the hold"
  assert_contains "$show" "held: yes" "a refused decline released the hold"

  printf 'Declined: do not run the sample half benchmark.\n' > "$home/half-run-decision.txt"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "decline could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "declined hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "declined hold lost the decision record"
  assert_contains "$show" "Resolution mode: declined" "declined hold did not record its close path"
  assert_contains "$show" "Declined: do not run the sample half benchmark." \
    "declined hold did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a declined decision did not satisfy the completion gate"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "identical decline retry was not idempotent"
  printf 'Declined for a different reason.\n' > "$home/drifted-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/drifted-decision.txt" \
    > "$home/drifted-decline.out" 2> "$home/drifted-decline.err"; then
    fail "decline retry accepted a different captain decision"
  fi
  json=$(run_bearings "$home") || fail "Bearings failed after a declined decision"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    (.decisions_open | any(.id == $hold) | not)
  ' >/dev/null || fail "a declined decision remained an open Captain's Call: $json"

  routed_hold=$(run_decisions "$home" hold "$id" upstream \
    --title "Choose the sample upstream target" --reason "captain upstream choice pending" --repo sample) \
    || fail "could not register the routed-work hold"
  tasks_in "$home" add sample-upstream-work "Apply the sample upstream choice" \
    --kind ship --repo sample --blocked-by "$routed_hold" >/dev/null \
    || fail "could not route work behind the second hold"
  if run_decisions "$home" decline "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/routed-decline.out" 2> "$home/routed-decline.err"; then
    fail "decline released work that was still routed behind the hold"
  fi
  assert_grep "still blocks routed work" "$home/routed-decline.err" \
    "decline must name the routed work it refuses to release"
  show=$(tasks_in "$home" show "$routed_hold" --full)
  assert_contains "$show" "state: queued" "refused routed decline closed the hold"
  show=$(tasks_in "$home" show sample-upstream-work --full)
  assert_contains "$show" "blocked: yes" "refused routed decline released dependent work"
  if run_decisions "$home" resolve "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/unrouted-resolve.out" 2> "$home/unrouted-resolve.err"; then
    fail "the routed close path accepted a resolution with no routed work"
  fi
  pass "a declined decision closes with a recorded answer and no routed work"
}

# A captain deferral answers the current question without closing the work item.
# The same identity must leave the active captain queue with its reason and the
# captain's exact decision preserved for the later revisit.
test_parked_decision_keeps_identity_and_clears_captain_action() {
  local home id parked future expired inactive show today help before invalid_until
  local park_text park_payload expired_text expired_digest expired_body
  home=$(make_home parked-decision)
  id=sample-park-review
  today=$(date +%F)
  help=$(run_decisions "$home" --help) || fail "could not read decision-hold help"
  assert_contains "$help" "fm-decision-hold.sh park <origin-id> <decision-key>" \
    "decision-hold help does not list park beside the answer paths"
  assert_contains "$help" "--decision-file <path> [--until <date>]" \
    "decision-hold help does not document park's flags"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample parking choices" --kind scout --repo sample --start >/dev/null \
    || fail "could not create parked-decision origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample parking review\n\nTwo captain choices can be revisited later.\n' > "$home/data/$id/report.md"
  parked=$(run_decisions "$home" hold "$id" revisit-later \
    --title "Revisit the sample choice" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the parkable hold"
  future=$(run_decisions "$home" hold "$id" revisit-on-date \
    --title "Revisit the dated sample choice" --reason "captain dated choice pending" --repo sample) \
    || fail "could not register the future hold"
  run_decisions "$home" complete "$id" revisit-later revisit-on-date >/dev/null \
    || fail "completion failed before parking the decisions"

  printf 'Leave the sample choice unchanged and revisit it later.\n' > "$home/park-decision.txt"
  park_text=$(cat "$home/park-decision.txt")
  park_payload=$(base64_value "$park_text")
  run_decisions "$home" park "$id" revisit-later --decision-file "$home/park-decision.txt" >/dev/null \
    || fail "park could not defer an active captain hold"
  show=$(tasks_in "$home" show "$parked" --full)
  assert_contains "$show" "state: queued" "park closed the held item"
  assert_contains "$show" "held: yes" "park released the held item"
  assert_contains "$show" "hold_kind: parked" "park left the item in the captain hold category"
  assert_contains "$show" "hold_reason: \"$today: captain sample choice pending\"" \
    "park did not preserve and date-prefix the hold reason"
  assert_contains "$show" "Deferral recorded by fm-decision-hold" \
    "park did not record durable decision provenance"
  assert_contains "$show" "Captain decision encoding: base64" \
    "park did not frame the captain's exact deferral"
  assert_contains "$show" "Captain decision payload: $park_payload" \
    "park did not retain the captain's exact deferral payload"
  before=$show
  run_decisions "$home" park "$id" revisit-later --decision-file "$home/park-decision.txt" >/dev/null \
    || fail "an exact parked-decision retry failed"
  show=$(tasks_in "$home" show "$parked" --full)
  [ "$show" = "$before" ] || fail "an exact parked-decision retry changed the hold"
  run_decisions "$home" hold "$id" revisit-later \
    --title "Revisit the sample choice" --reason "captain sample choice pending" --repo sample >/dev/null \
    || fail "an exact hold replay rejected the parked decision"
  show=$(tasks_in "$home" show "$parked" --full)
  [ "$show" = "$before" ] || fail "an exact hold replay reactivated the parked decision"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a parked decision did not satisfy the completion gate"

  printf 'Leave the dated choice unchanged until the review date.\n' > "$home/future-decision.txt"
  before=$(tasks_in "$home" show "$future" --full)
  for invalid_until in "$today" 2000-01-01; do
    if run_decisions "$home" park "$id" revisit-on-date --decision-file "$home/future-decision.txt" \
      --until "$invalid_until" > "$home/invalid-until.out" 2> "$home/invalid-until.err"; then
      fail "park accepted a revisit date that was not later than today: $invalid_until"
    fi
    assert_grep "until must be later than today: $invalid_until" "$home/invalid-until.err" \
      "park did not explain why it refused a non-future revisit date"
    show=$(tasks_in "$home" show "$future" --full)
    [ "$show" = "$before" ] \
      || fail "refusing a non-future revisit date changed the active captain hold"
  done
  run_decisions "$home" park "$id" revisit-on-date --decision-file "$home/future-decision.txt" \
    --until 2099-12-31 >/dev/null \
    || fail "park could not defer a captain hold until a date"
  show=$(tasks_in "$home" show "$future" --full)
  assert_contains "$show" "state: queued" "dated park closed the held item"
  assert_contains "$show" "hold_kind: future" "dated park did not use the future hold category"
  assert_contains "$show" "hold_until: 2099-12-31" "dated park lost its revisit date"
  assert_contains "$show" "hold_reason: \"$today: captain dated choice pending\"" \
    "dated park did not preserve and date-prefix the hold reason"
  before=$show
  run_decisions "$home" park "$id" revisit-on-date --decision-file "$home/future-decision.txt" \
    --until 2099-12-31 >/dev/null \
    || fail "an exact future-decision retry failed"
  show=$(tasks_in "$home" show "$future" --full)
  [ "$show" = "$before" ] || fail "an exact future-decision retry changed the hold"
  run_decisions "$home" hold "$id" revisit-on-date \
    --title "Revisit the dated sample choice" --reason "captain dated choice pending" --repo sample >/dev/null \
    || fail "an exact hold replay rejected the future decision"
  show=$(tasks_in "$home" show "$future" --full)
  [ "$show" = "$before" ] || fail "an exact hold replay reactivated the future decision"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a future decision did not satisfy the completion gate"

  expired=$(run_decisions "$home" hold "$id" expired-revisit \
    --title "Revisit the expired sample choice" --reason "captain expired choice pending" --repo sample) \
    || fail "could not register the expired future-hold fixture"
  printf 'Keep the expired choice deferred exactly as recorded.\n' > "$home/expired-decision.txt"
  expired_text=$(cat "$home/expired-decision.txt")
  expired_digest=$(sha256_value "$expired_text")
  expired_body=$(printf 'Deferral recorded by fm-decision-hold.\nDecision digest: %s\nDeferral mode: future\nDeferred on: %s\nDeferred until: %s\nOriginal hold reason: captain expired choice pending\n\nCaptain decision:\n%s' \
    "$expired_digest" "$today" "$today" "$expired_text")
  tasks_in "$home" update "$expired" --body "$expired_body" >/dev/null \
    || fail "could not persist the expired future-hold fixture"
  tasks_in "$home" hold "$expired" --reason "$today: captain expired choice pending" \
    --kind future --until "$today" >/dev/null \
    || fail "could not expire the future-hold fixture"
  before=$(tasks_in "$home" show "$expired" --full)
  assert_contains "$before" "held: no" "the exact-retry fixture did not expire"
  run_decisions "$home" park "$id" expired-revisit --decision-file "$home/expired-decision.txt" \
    --until "$today" >/dev/null \
    || fail "an exact expired future-decision retry failed"
  show=$(tasks_in "$home" show "$expired" --full)
  [ "$show" = "$before" ] || fail "an exact expired future-decision retry changed the hold"

  inactive=$(run_decisions "$home" hold "$id" inactive-choice \
    --title "Inactive sample choice" --reason "captain inactive choice pending" --repo sample) \
    || fail "could not register the inactive-hold fixture"
  tasks_in "$home" "done" "$inactive" >/dev/null || fail "could not make the hold inactive"
  if run_decisions "$home" park "$id" inactive-choice --decision-file "$home/park-decision.txt" \
    > "$home/inactive-park.out" 2> "$home/inactive-park.err"; then
    fail "park accepted an inactive captain hold"
  fi
  assert_grep "not queued" "$home/inactive-park.err" "park did not report why the inactive hold was refused"
  show=$(tasks_in "$home" show "$inactive" --full)
  assert_contains "$show" "state: done" "a refused park reopened the inactive hold"
  assert_not_contains "$show" "Deferral recorded by fm-decision-hold" \
    "a refused park wrote a captain deferral"

  pass "park records deferrals, preserves reasons, supports dates, and keeps the completion gate green"
}

test_reactivated_decision_appends_deferral_cycle() {
  local home origin hold first_text first_digest first_payload second_text second_digest second_payload
  local second show before today
  home=$(make_home repeated-park)
  origin=sample-repeated-park-review
  today=$(date +%F)
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review repeated parking" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the repeated-park origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Repeated park review\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" repeated-choice \
    --title "Revisit the repeated choice" --reason "captain first review pending" --repo sample) \
    || fail "could not register the repeated-park hold"

  printf 'Keep the first version parked.\n' > "$home/first-park.txt"
  first_text=$(cat "$home/first-park.txt")
  first_digest=$(sha256_value "$first_text")
  first_payload=$(base64_value "$first_text")
  run_decisions "$home" park "$origin" repeated-choice --decision-file "$home/first-park.txt" >/dev/null \
    || fail "could not record the first deferral cycle"
  tasks_in "$home" hold "$hold" --reason "captain revised review pending" --kind captain >/dev/null \
    || fail "could not explicitly reactivate the parked decision"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "reactivation did not restore the captain hold kind"

  printf 'Keep the revised version parked too.\n' > "$home/second-park.txt"
  second_text=$(cat "$home/second-park.txt")
  second_digest=$(sha256_value "$second_text")
  second_payload=$(base64_value "$second_text")
  second=$(run_decisions "$home" park "$origin" repeated-choice \
    --decision-file "$home/second-park.txt") \
    || fail "could not record the second deferral cycle"
  [ "$second" = "parked: $hold" ] || fail "the second deferral changed the durable identity"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: parked" "the second deferral stayed active for the captain"
  assert_contains "$show" "hold_reason: \"$today: captain revised review pending\"" \
    "the second deferral lost its reactivation reason"
  assert_contains "$show" "Decision digest: $first_digest" \
    "the second deferral did not retain the first decision digest"
  assert_contains "$show" "Decision digest: $second_digest" \
    "the second deferral did not append its decision digest"
  assert_contains "$show" "Captain decision payload: $first_payload" \
    "the second deferral did not retain the first exact decision payload"
  assert_contains "$show" "Captain decision payload: $second_payload" \
    "the second deferral did not append its exact decision payload"
  assert_contains "$show" "Deferral cycle: 1" "the first deferral cycle is absent"
  assert_contains "$show" "Deferral cycle: 2" "the second deferral cycle is absent"
  before=$show
  run_decisions "$home" park "$origin" repeated-choice --decision-file "$home/second-park.txt" >/dev/null \
    || fail "an exact second-cycle retry failed"
  show=$(tasks_in "$home" show "$hold" --full)
  [ "$show" = "$before" ] || fail "an exact second-cycle retry appended another record"
  pass "reactivated decisions append a new deferral cycle on one identity"
}

test_park_retry_edges_preserve_state() {
  local home origin empty escaped partial spoofed before show today escaped_reason
  local partial_text partial_digest partial_body
  home=$(make_home park-retry-edges)
  origin=sample-park-edge-review
  today=$(date +%F)
  escaped_reason='captain says "wait" at C:\review'
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review park retry edges" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the park-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Park retry edge review\n' > "$home/data/$origin/report.md"

  empty=$(run_decisions "$home" hold "$origin" empty-date \
    --title "Revisit an empty date" --reason "captain empty date pending" --repo sample) \
    || fail "could not register the empty-date hold"
  printf 'Keep the empty-date choice parked.\n' > "$home/empty-date.txt"
  before=$(tasks_in "$home" show "$empty" --full)
  if run_decisions "$home" park "$origin" empty-date --decision-file "$home/empty-date.txt" \
    --until "" > "$home/empty-date.out" 2> "$home/empty-date.err"; then
    fail "park accepted an explicitly empty revisit date"
  fi
  assert_grep "until must not be empty" "$home/empty-date.err" \
    "park did not explain the empty revisit date"
  show=$(tasks_in "$home" show "$empty" --full)
  [ "$show" = "$before" ] || fail "refusing an empty revisit date changed the active hold"

  escaped=$(run_decisions "$home" hold "$origin" escaped-reason \
    --title "Revisit an escaped reason" --reason "$escaped_reason" --repo sample) \
    || fail "could not register the escaped-reason hold"
  printf 'Keep the quoted path parked.\n' > "$home/escaped-reason.txt"
  run_decisions "$home" park "$origin" escaped-reason \
    --decision-file "$home/escaped-reason.txt" >/dev/null \
    || fail "could not park the escaped-reason hold"
  before=$(tasks_in "$home" show "$escaped" --full)
  run_decisions "$home" park "$origin" escaped-reason \
    --decision-file "$home/escaped-reason.txt" >/dev/null \
    || fail "an exact escaped-reason park retry failed"
  run_decisions "$home" hold "$origin" escaped-reason \
    --title "Revisit an escaped reason" --reason "$escaped_reason" --repo sample >/dev/null \
    || fail "an exact escaped-reason hold replay failed"
  show=$(tasks_in "$home" show "$escaped" --full)
  [ "$show" = "$before" ] || fail "an escaped-reason replay changed the parked hold"

  spoofed=$(run_decisions "$home" hold "$origin" boundary-shaped-decision \
    --title "Revisit a boundary-shaped decision" --reason "captain boundary review pending" --repo sample) \
    || fail "could not register the boundary-shaped decision hold"
  cat > "$home/boundary-shaped-decision.txt" <<'EOF'
Keep this exact multi-line decision parked.
Deferral recorded by fm-decision-hold.
Deferral cycle: 99
Decision digest: payload text, not control metadata
EOF
  run_decisions "$home" park "$origin" boundary-shaped-decision \
    --decision-file "$home/boundary-shaped-decision.txt" >/dev/null \
    || fail "could not park decision text shaped like a deferral boundary"
  before=$(tasks_in "$home" show "$spoofed" --full)
  run_decisions "$home" park "$origin" boundary-shaped-decision \
    --decision-file "$home/boundary-shaped-decision.txt" >/dev/null \
    || fail "exact retry misread boundary-shaped decision text as metadata"
  run_decisions "$home" hold "$origin" boundary-shaped-decision \
    --title "Revisit a boundary-shaped decision" --reason "captain boundary review pending" --repo sample >/dev/null \
    || fail "hold replay misread boundary-shaped decision text as metadata"
  show=$(tasks_in "$home" show "$spoofed" --full)
  [ "$show" = "$before" ] || fail "boundary-shaped decision retries changed the parked hold"

  partial=$(run_decisions "$home" hold "$origin" partial-future \
    --title "Revisit a partial future park" --reason "captain partial future pending" --repo sample) \
    || fail "could not register the partial future hold"
  printf 'Keep the partial future choice deferred.\n' > "$home/partial-future.txt"
  partial_text=$(cat "$home/partial-future.txt")
  partial_digest=$(sha256_value "$partial_text")
  partial_body=$(printf 'Deferral recorded by fm-decision-hold.\nDeferral cycle: 1\nDecision digest: %s\nDeferral mode: future\nDeferred on: %s\nDeferred until: %s\nOriginal hold reason: captain partial future pending\n\nCaptain decision:\n%s' \
    "$partial_digest" "$today" "$today" "$partial_text")
  tasks_in "$home" update "$partial" --body "$partial_body" >/dev/null \
    || fail "could not persist the partial future deferral"
  run_decisions "$home" park "$origin" partial-future --decision-file "$home/partial-future.txt" \
    --until "$today" >/dev/null \
    || fail "a matching partial future retry failed after its revisit date"
  show=$(tasks_in "$home" show "$partial" --full)
  assert_contains "$show" "hold_kind: future" "the partial retry did not finish the future retag"
  assert_contains "$show" "held: no" "the expired partial retry did not retain its inactive future state"
  assert_contains "$show" "Deferral cycle completed by fm-decision-hold: 1" \
    "the partial retry did not complete its durable cycle"
  pass "park retries preserve empty, escaped, framed, and partial-transition state"
}

test_concurrent_park_and_answer_keep_one_decision() {
  local home id hold park_pid answer_pid park_rc answer_rc show i
  home=$(make_home concurrent-park-answer)
  id=sample-concurrent-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review concurrent decision handling" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the concurrent-decision origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Concurrent decision review\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" concurrent-choice \
    --title "Choose the concurrent outcome" --reason "captain concurrent choice pending" --repo sample) \
    || fail "could not register the concurrent-decision hold"
  printf 'Revisit the concurrent choice later.\n' > "$home/park-concurrent.txt"
  printf 'Apply the concurrent choice now.\n' > "$home/answer-concurrent.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FM_TEST_PAUSE_PARK_UPDATE:-}" ] && [ "${1:-}" = update ]; then
  case "$*" in
    *"Deferral recorded by fm-decision-hold."*)
      : > "$FM_TEST_PAUSE_PARK_UPDATE"
      while [ ! -f "$FM_TEST_RELEASE_PARK_UPDATE" ]; do sleep 0.01; done
      ;;
  esac
fi
"$REAL_TASKS_AXI" "$@"
rc=$?
if [ -n "${FM_TEST_MARK_ANSWER_DONE:-}" ] && [ "${1:-}" = done ]; then
  : > "$FM_TEST_MARK_ANSWER_DONE"
fi
exit "$rc"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  FM_TEST_PAUSE_PARK_UPDATE="$home/park-update-ready" \
    FM_TEST_RELEASE_PARK_UPDATE="$home/release-park-update" \
    run_decisions "$home" park "$id" concurrent-choice \
      --decision-file "$home/park-concurrent.txt" > "$home/concurrent-park.out" \
      2> "$home/concurrent-park.err" &
  park_pid=$!
  i=0
  while [ ! -f "$home/park-update-ready" ] && kill -0 "$park_pid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -f "$home/park-update-ready" ]; then
    : > "$home/release-park-update"
    wait "$park_pid" || true
    fail "park did not reach the staged deferral write"
  fi

  FM_TEST_MARK_ANSWER_DONE="$home/answer-done" \
    run_decisions "$home" answer "$id" concurrent-choice \
      --decision-file "$home/answer-concurrent.txt" > "$home/concurrent-answer.out" \
      2> "$home/concurrent-answer.err" &
  answer_pid=$!
  i=0
  while [ ! -f "$home/answer-done" ] && kill -0 "$answer_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  : > "$home/release-park-update"
  set +e
  wait "$park_pid"
  park_rc=$?
  wait "$answer_pid"
  answer_rc=$?
  set +e

  [ "$park_rc" -eq 0 ] || fail "serialized park failed: $(cat "$home/concurrent-park.err")"
  [ "$answer_rc" -ne 0 ] || fail "a concurrent answer replaced the serialized deferral"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the concurrent answer closed the parked decision"
  assert_contains "$show" "hold_kind: parked" "the concurrent answer replaced the parked hold kind"
  assert_contains "$show" "Deferral recorded by fm-decision-hold" \
    "the concurrent answer erased the durable deferral"
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the parked decision retained a losing concurrent resolution"
  pass "concurrent park and answer keep one serialized decision"
}

# The exact incident: two declined captain decisions were closed with a direct
# tasks-axi done, so the durable resolution attestation this gate reads was never
# written and the investigation could no longer be cleaned up.
test_out_of_band_close_is_repairable_before_teardown() {
  local home id hold show
  home=$(make_home out-of-band-close)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band-close origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" submission \
    --title "Choose the sample submission" --reason "captain submission choice pending" --repo sample) \
    || fail "could not register the out-of-band hold"
  run_decisions "$home" complete "$id" submission >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not reproduce the direct out-of-band close"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the out-of-band close shape was not reproduced"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "the out-of-band close must leave no durable resolution record"
  if run_decisions "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain decision closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain decision had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  if run_decisions "$home" repair "$id" submission > "$home/bare-repair.out" 2> "$home/bare-repair.err"; then
    fail "repair recorded a resolution with no captain decision file"
  fi
  printf '' > "$home/empty-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/empty-repair.txt" \
    > "$home/empty-repair.out" 2> "$home/empty-repair.err"; then
    fail "repair recorded a resolution from an empty captain decision file"
  fi
  if run_decisions "$home" verify "$id" > "$home/still-broken.out" 2> "$home/still-broken.err"; then
    fail "a refused repair still satisfied the completion gate"
  fi

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission-decision.txt"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "repair could not record the missing durable resolution"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "repair reopened a closed captain decision"
  assert_contains "$show" "Resolution mode: repaired" "repair did not record its close path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "repair did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "the repaired decision did not satisfy the completion gate"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "identical repair retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/drifted-repair.txt" \
    > "$home/drifted-repair.out" 2> "$home/drifted-repair.err"; then
    fail "repair retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the decision was repaired: $(cat "$home/teardown.err")"
  pass "a decision closed outside the script is repairable and then clears teardown"
}

# The unrouted close paths must not become a way past the gate. An unanswered
# decision keeps blocking cleanup, and neither new path can manufacture an answer.
test_unanswered_decision_still_blocks_completion_and_teardown() {
  local home id hold show
  home=$(make_home unanswered-decision)
  id=sample-open-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate an open sample choice" --kind scout --repo sample --start >/dev/null \
    || fail "could not create unanswered-decision origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=open-choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample open review\n\nThe captain has not chosen yet.\n' > "$home/data/$id/report.md"
  printf 'An answer the captain never gave.\n' > "$home/invented-decision.txt"

  if run_decisions "$home" complete "$id" open-choice > "$home/open-complete.out" 2> "$home/open-complete.err"; then
    fail "completion accepted an unresolved decision with no captain hold"
  fi
  if run_decisions "$home" verify "$id" > "$home/open-verify.out" 2> "$home/open-verify.err"; then
    fail "verification accepted an unresolved decision with no captain hold"
  fi
  if run_teardown "$home" "$id" > "$home/open-teardown.out" 2> "$home/open-teardown.err"; then
    fail "teardown erased an investigation whose decision was never inventoried"
  fi
  assert_grep "REFUSED" "$home/open-teardown.err" "teardown refusal must be explicit"
  if run_decisions "$home" decline "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-decline.out" 2> "$home/absent-decline.err"; then
    fail "decline invented a resolution for a decision that has no hold"
  fi
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-repair.out" 2> "$home/absent-repair.err"; then
    fail "repair invented a resolution for a decision that has no hold"
  fi

  tasks_in "$home" add "$id-decision-never-held" "An ordinary captain-kind task" \
    --kind captain --repo sample >/dev/null \
    || fail "could not create the never-held captain-kind fixture"
  tasks_in "$home" "done" "$id-decision-never-held" >/dev/null \
    || fail "could not close the never-held captain-kind fixture"
  if run_decisions "$home" repair "$id" never-held --decision-file "$home/invented-decision.txt" \
    > "$home/never-held-repair.out" 2> "$home/never-held-repair.err"; then
    fail "repair turned an ordinary captain-kind task into a resolved captain decision"
  fi
  assert_grep "never held for the captain" "$home/never-held-repair.err" \
    "repair must say the identity carries no captain-hold provenance"
  show=$(tasks_in "$home" show "$id-decision-never-held" --full)
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "a refused never-held repair wrote a resolution record"

  hold=$(run_decisions "$home" hold "$id" open-choice \
    --title "Choose the sample option" --reason "captain option choice pending" --repo sample) \
    || fail "could not register the unanswered hold"
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/held-repair.out" 2> "$home/held-repair.err"; then
    fail "repair closed a decision that is still actively held and unanswered"
  fi
  assert_grep "still open" "$home/held-repair.err" "repair must say the hold is still open"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused repair closed the live hold"
  assert_contains "$show" "held: yes" "a refused repair released the live hold"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "a refused repair wrote a resolution record"
  run_decisions "$home" complete "$id" open-choice >/dev/null \
    || fail "an inventoried unanswered decision could not complete its review"
  pass "an unanswered decision still blocks completion and resists both unrouted close paths"
}

# The exact anchor of the loss this closure exists to prevent, reproduced end to
# end through the channel that actually carried it. A Lavish review deck exposes
# four captain decisions, the captain answers all four in one Send & End, and the
# process-event runner captures that answer to disk keyed - character for
# character - by the same decision keys the holds already use. Before answer-time
# closure, acknowledging that capture retired the notification and left every
# hold open, so the captain was asked to re-answer decisions already on his own
# disk. Capturing the answer must now BE closing the hold.
test_bound_channel_answers_close_their_holds_at_answer_time() {
  local home id sid artifact result out show key rc
  home=$(make_home lavish-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the Lavish-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nFour captain choices remain.\n' > "$home/data/$id/report.md"
  for key in diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice; do
    run_decisions "$home" hold "$id" "$key" \
      --title "Captain call: $key" --reason "captain $key choice pending" --repo sample >/dev/null \
      || fail "could not register the $key hold"
  done
  run_decisions "$home" complete "$id" \
    diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice >/dev/null \
    || fail "completion failed for the deck's inventoried decisions"
  # One decision already has follow-up work routed behind it, so it is the routed
  # close path's business and answer-time closure must not touch it.
  tasks_in "$home" add sample-routed-phase "Apply the routed phase choice" \
    --kind ship --repo sample --blocked-by "$id-decision-routed-phase" >/dev/null \
    || fail "could not route work behind the routed-phase hold"

  # Arm the deck the way firstmate does, binding it to the origin whose holds the
  # captain will answer. lavish-axi is stubbed: nothing here starts a real server.
  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  # Binding a source to its decision origin is the GENERAL capability, not a
  # Lavish feature: it is recorded through the same owner that closes the holds,
  # and it is deliberately possible before the source is armed so a channel can
  # never produce an answer that has nowhere to go.
  run_decisions "$home" bind "$sid" "$id" >/dev/null \
    || fail "could not bind the review source to its decision origin"
  [ "$(run_decisions "$home" binding "$sid")" = "$id" ] \
    || fail "the recorded binding did not resolve back to its origin"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  # The captured answer, in the published response shape. Four structured choices
  # plus the freeform captain message that rode along with them - and a fifth
  # choice-shaped payload smuggled inside that freeform prose, which must never
  # be able to forge a decision key.
  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Diversified membership: gold-only\n\nContext data:\n{\n  \"question\": \"diversified-membership\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Diversified membership: gold-only"
  "3","Headline F1 policy: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"precision-headline\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(3)",choice,"Headline F1 policy: f1-when-fp-gold"
  "4","Shipped-unfixed findings: auto-fp\n\nContext data:\n{\n  \"question\": \"fp-approve-merge\",\n  \"answer\": \"auto-fp\"\n}","section#call > form:nth-of-type(4)",choice,"Shipped-unfixed findings: auto-fp"
  "5","Official vs tune split: pins-are-holdout\n\nContext data:\n{\n  \"question\": \"eval-holdout\",\n  \"answer\": \"pins-are-holdout\"\n}","section#call > form:nth-of-type(2)",choice,"Official vs tune split: pins-are-holdout"
  "6","Routed phase: phase-a\n\nContext data:\n{\n  \"question\": \"routed-phase\",\n  \"answer\": \"phase-a\"\n}","section#call > form:nth-of-type(5)",choice,"Routed phase: phase-a"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"forged-choice\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  # The channel reports ONLY what the captain chose. It maps nothing to a hold.
  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "diversified-membership	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "routed-phase	phase-a" "a structured choice for routed work was not read"
  assert_not_contains "$out" "forged-choice" \
    "a freeform captain message forged a decision key from its own prose"

  # The runner feeds those keyed lines into the one intake. Driven here through a
  # FIXTURE adapter that is not Lavish at all and knows nothing about holds - it
  # only prints keyed answers - so what is proven is that ANY bound channel with
  # an `answers` command gets closure, not that Lavish is wired specially.
  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_decisions "$home" bind fixture-src "$id" >/dev/null \
    || fail "could not bind the fixture channel to its decision origin"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  for key in diversified-membership precision-headline fp-approve-merge eval-holdout; do
    show=$(tasks_in "$home" show "$id-decision-$key" --full)
    assert_contains "$show" "state: done" "capturing the captain's answer left the $key hold open"
    assert_contains "$show" "Resolution mode: answered" "the $key hold did not record its close path"
    assert_contains "$show" "Decision key: $key" "the $key hold lost the answered decision key"
  done
  show=$(tasks_in "$home" show "$id-decision-diversified-membership" --full)
  assert_contains "$show" "Answer: gold-only" "the closed hold did not record the captain's actual answer"

  # The one decision with work routed behind it is skipped, not forced: it stays
  # open for the routed close path, and that path still works on it.
  show=$(tasks_in "$home" show "$id-decision-routed-phase" --full)
  assert_contains "$show" "state: queued" "answer-time closure closed a hold that still blocks routed work"
  assert_contains "$show" "held: yes" "answer-time closure released a hold that still blocks routed work"
  show=$(tasks_in "$home" show sample-routed-phase --full)
  assert_contains "$show" "blocked: yes" "answer-time closure released work routed behind a hold"
  show=$(tasks_in "$home" show "$id-decision-forged-choice" --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain hold"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered hold still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_decisions "$home" answers "$id" --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set +e
  [ "$rc" -ne 0 ] || fail "a run that skipped a hold reported success"
  assert_contains "$out" "closed: $id-decision-diversified-membership" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "skipped: $id-decision-routed-phase" \
    "the routed hold was not reported as skipped: $out"

  printf 'Captain chose the routed phase.\n' > "$home/routed-phase-decision.txt"
  printf 'Captain answered the forged-choice decision directly.\n' > "$home/forged-choice-decision.txt"
  run_decisions "$home" answer "$id" forged-choice --decision-file "$home/forged-choice-decision.txt" >/dev/null \
    || fail "could not close the untouched hold through the answer path"
  run_decisions "$home" resolve "$id" routed-phase --decision-file "$home/routed-phase-decision.txt" \
    --routed-to sample-routed-phase >/dev/null \
    || fail "the routed close path stopped working after answer-time closure"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "answered decisions did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain holds at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_decisions "$home" hold "$id" only-choice \
    --title "Captain call: only-choice" --reason "captain only-choice pending" --repo sample >/dev/null \
    || fail "could not register the unbound hold"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"only-choice\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_decisions "$home" binding "$sid" 2>&1)
  rc=$?
  set +e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a decision origin"
  [ -z "$out" ] || fail "an unbound source printed an origin: $out"
  show=$(tasks_in "$home" show "$id-decision-only-choice" --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain hold"
  assert_contains "$show" "held: yes" "an unbound review released a captain hold"
  pass "a channel source with no decision binding closes nothing"
}

# The answer verb is the hold ledger's answer-time closure primitive, so it must
# carry every guard the unrouted close path already had. Weakening any of them to
# reach closure would trade the loss this fixes for a worse one.
test_answer_preserves_every_unrouted_close_guard() {
  local home id hold show
  home=$(make_home answer-guards)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" guard-choice \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample) \
    || fail "could not register the guarded hold"
  run_decisions "$home" complete "$id" guard-choice >/dev/null \
    || fail "completion failed for the guarded hold"

  printf '' > "$home/empty.txt"
  if run_decisions "$home" answer "$id" guard-choice --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_decisions "$home" answer "$id" guard-choice > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  if run_decisions "$home" answer "$id" absent-choice --decision-file "$home/empty.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a decision that has no hold"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused answer closed the hold"
  assert_contains "$show" "held: yes" "a refused answer released the hold"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_decisions "$home" answer "$id" guard-choice --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "an answered hold did not close"
  assert_contains "$show" "Resolution mode: answered" "an answered hold did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "an answered hold did not record the captain decision text"
  run_decisions "$home" answer "$id" guard-choice --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_decisions "$home" answer "$id" guard-choice --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "an answered decision did not satisfy the completion gate"
  pass "the answer path keeps every guard the unrouted close path already had"
}


# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does. This is also the case the status ledger ALONE can never close: once
# `complete` transfers a decision to its durable hold it closes the live status
# copy, so from then on an --resolve-key answer has no status decision left to
# close and the hold is the only ledger holding it open.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id hold fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample) \
    || fail "could not register the chat hold"
  run_decisions "$home" complete "$id" chat-choice >/dev/null \
    || fail "completion failed for the chat hold"
  # The transfer really did close the live status copy, so only the hold is open.
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its hold"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred decision was refused by the chat channel"
  assert_contains "$(cat "$home/send.log")" "go with option A" "the answer text never reached the worker"

  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "a chat answer left its captain hold open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered hold did not record its close path"
  assert_contains "$show" "Answer: go with option A" "the chat-answered hold lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered hold lost its channel provenance"
  # The real fm-send flow routed through the hold-close path, so the durable proof
  # the archival gate reads is the origin's answered_keys, not any status line.
  assert_contains "$(meta_value_in "$home" "$id" answered_keys)" "chat-choice" \
    "the real fm-send answer did not durably record answered_keys"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a chat-answered decision did not satisfy the completion gate"

  # Retention trims the answered Done hold; the fm-send-answered decision must still
  # clear the gate end to end, on the durable answered_keys record alone.
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "the archival step did not remove the fm-send-answered hold from the backlog"
  fi
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/chat-archived.err" \
    || fail "verify rejected an fm-send-answered hold after archival: $(cat "$home/chat-archived.err")"
  pass "the chat channel feeds the same keyed-answer intake and clears the gate after archival"
}

# Done history is trimmed to a bounded recent window, so a captain hold that was
# answered and marked Done is eventually dropped from the backlog. The answer was
# durably attested when it was recorded and the status log's resolved line proves
# it, so verify must treat the archived hold as satisfied. A hold that is absent
# while its decision is still open (never answered) must still fail.
test_verify_tolerates_answered_hold_archived_out_of_backlog() {
  local home id hold
  home=$(make_home archived-answered)
  id=sample-archived-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the archived sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-answered origin"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=choice]: choose sample option A or option B
resolved [key=choice]: answered: captain chose option A
done: report complete
EOF
  printf '# Sample archived review\n\nOne choice remained and was answered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the archived-answered hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed before the hold was answered"
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the sample choice"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify failed while the answered hold was still in the backlog"

  # Reproduce retention archival: the answered Done hold is trimmed out of the backlog.
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "the archival step did not remove the answered hold from the backlog"
  fi
  run_decisions "$home" verify "$id" > "$home/archived-verify.out" 2> "$home/archived-verify.err" \
    || fail "verify rejected an answered hold that retention archived: $(cat "$home/archived-verify.err")"
  run_teardown "$home" "$id" >/dev/null 2> "$home/archived-teardown.err" \
    || fail "teardown refused after the answered hold was archived: $(cat "$home/archived-teardown.err")"

  # An absent hold whose decision is still open (never answered) must still fail.
  local open_home open_id
  open_home=$(make_home archived-open)
  open_id=sample-open-archived
  mkdir -p "$open_home/data/$open_id"
  tasks_in "$open_home" add "$open_id" "Investigate an open sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-open origin"
  write_origin_meta "$open_home" "$open_id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$open_home/state/$open_id.status"
  printf '# Sample open review\n\nThe captain has not chosen yet.\n' > "$open_home/data/$open_id/report.md"
  fm_write_meta "$open_home/state/$open_id.meta" \
    "window=firstmate:fm-$open_id" "worktree=$open_home/projects/missing-$open_id" \
    "project=$open_home/projects/sample" "harness=codex" "kind=scout" "mode=scout" \
    "decisions_reviewed=1" "decision_keys=choice"
  if run_decisions "$open_home" verify "$open_id" \
    > "$open_home/open-verify.out" 2> "$open_home/open-verify.err"; then
    fail "verify accepted an unanswered open decision with no backlog hold"
  fi

  # No answer line at all: a reviewed key whose status log never records an
  # explicit resolved or captain-held line, and whose hold is absent, has no
  # positive evidence it was answered. Absence of the key from the open set is
  # not proof of an answer, so verify must still fail.
  local silent_home silent_id
  silent_home=$(make_home archived-no-evidence)
  silent_id=sample-silent-archived
  mkdir -p "$silent_home/data/$silent_id"
  tasks_in "$silent_home" add "$silent_id" "Investigate a silent sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-no-evidence origin"
  write_origin_meta "$silent_home" "$silent_id"
  printf 'done: report complete\n' > "$silent_home/state/$silent_id.status"
  printf '# Sample silent review\n\nNo answer was ever recorded.\n' > "$silent_home/data/$silent_id/report.md"
  fm_write_meta "$silent_home/state/$silent_id.meta" \
    "window=firstmate:fm-$silent_id" "worktree=$silent_home/projects/missing-$silent_id" \
    "project=$silent_home/projects/sample" "harness=codex" "kind=scout" "mode=scout" \
    "decisions_reviewed=1" "decision_keys=choice"
  if run_decisions "$silent_home" verify "$silent_id" \
    > "$silent_home/silent-verify.out" 2> "$silent_home/silent-verify.err"; then
    fail "verify accepted an absent hold with no answer line in the status log"
  fi

  # `complete` appends its own captain-held transfer line for every reviewed key
  # that is still open, before the captain has answered anything. That line says
  # where the decision now lives, not that it was answered, so an unanswered hold
  # that later leaves the backlog must still fail.
  local held_home held_id held_hold
  held_home=$(make_home archived-held-only)
  held_id=sample-held-archived
  mkdir -p "$held_home/data/$held_id"
  tasks_in "$held_home" add "$held_id" "Investigate a held sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-held-only origin"
  write_origin_meta "$held_home" "$held_id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$held_home/state/$held_id.status"
  printf '# Sample held review\n\nOne choice remained unanswered.\n' > "$held_home/data/$held_id/report.md"
  held_hold=$(run_decisions "$held_home" hold "$held_id" choice \
    --title "Choose the held sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the held-only hold"
  run_decisions "$held_home" complete "$held_id" choice >/dev/null \
    || fail "completion failed for the held-only origin"
  grep -q "captain-held \[key=choice\]" "$held_home/state/$held_id.status" \
    || fail "complete did not append its captain-held transfer line"
  grep -v "$held_hold" "$held_home/data/backlog.md" > "$held_home/data/backlog.md.trimmed"
  mv "$held_home/data/backlog.md.trimmed" "$held_home/data/backlog.md"
  if run_decisions "$held_home" verify "$held_id" \
    > "$held_home/held-verify.out" 2> "$held_home/held-verify.err"; then
    fail "verify accepted an unanswered hold whose only status evidence was the captain-held transfer"
  fi

  # A decision key is stable and reusable, so the same hold id can be answered in
  # round one and opened again for round two. The stale round-one resolved line is
  # not evidence for round two. The origin status ends in done, which empties the
  # open set, so the reviewed-key check is the only gate left and it must fail.
  local reopen_home reopen_id reopen_hold reopen_open
  reopen_home=$(make_home archived-reopened)
  reopen_id=sample-reopened-archived
  mkdir -p "$reopen_home/data/$reopen_id"
  tasks_in "$reopen_home" add "$reopen_id" "Investigate a re-opened sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-reopened origin"
  write_origin_meta "$reopen_home" "$reopen_id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$reopen_home/state/$reopen_id.status"
  printf '# Sample re-opened review\n\nRound two is still unanswered.\n' > "$reopen_home/data/$reopen_id/report.md"
  reopen_hold=$(run_decisions "$reopen_home" hold "$reopen_id" choice \
    --title "Choose the re-opened sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the re-opened hold"
  run_decisions "$reopen_home" complete "$reopen_id" choice >/dev/null \
    || fail "completion failed for the re-opened origin"
  printf 'Captain chose option A.\n' > "$reopen_home/choice-decision.txt"
  run_decisions "$reopen_home" answer "$reopen_id" choice --decision-file "$reopen_home/choice-decision.txt" >/dev/null \
    || fail "could not answer round one of the re-opened choice"
  # bin/fm-send.sh appends this resolved line when the captain's answer is delivered.
  {
    printf 'resolved [key=choice]: answered: captain picked A\n'
    printf 'needs-decision [key=choice]: now choose option C or option D\n'
    printf 'done: report complete\n'
  } >> "$reopen_home/state/$reopen_id.status"
  reopen_open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$reopen_home/state/$reopen_id.status")
  assert_contains "$reopen_open" "choice" \
    "the re-opened fixture did not leave the key open in the status fold: $reopen_open"
  grep -v "$reopen_hold" "$reopen_home/data/backlog.md" > "$reopen_home/data/backlog.md.trimmed"
  mv "$reopen_home/data/backlog.md.trimmed" "$reopen_home/data/backlog.md"
  if run_decisions "$reopen_home" verify "$reopen_id" \
    > "$reopen_home/reopen-verify.out" 2> "$reopen_home/reopen-verify.err"; then
    fail "verify accepted a re-opened unanswered decision on a stale round-one resolved line"
  fi
  assert_contains "$(cat "$reopen_home/reopen-verify.err")" "$reopen_hold" \
    "the re-open refusal did not name the absent hold, so a different gate refused it"
  pass "verify tolerates an answered hold archived out of the backlog but still fails one with no answer evidence"
}

# Absence has to be proven, not inferred from a failed read. Retention trimming a
# Done hold reports NOT_FOUND; a backlog that cannot be read reports a different
# error. Only the first is archival. Treating a broken read as archival would let a
# recorded answer wave through a gate that no longer knows what is in the backlog,
# right before teardown deletes the source.
test_verify_refuses_when_the_backlog_cannot_be_read() {
  local home id hold answered_out unreadable_err
  home=$(make_home unreadable-backlog)
  id=sample-unreadable-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the unreadable sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create unreadable-backlog origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample unreadable review\n\nOne choice was answered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the unreadable sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the unreadable-backlog hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the unreadable-backlog origin"
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the unreadable-backlog choice"
  # bin/fm-send.sh appends this resolved line when the captain's answer is delivered.
  printf 'resolved [key=choice]: answered: captain picked A\n' >> "$home/state/$id.status"

  # Real archival: retention trims the answered hold and tasks-axi reports NOT_FOUND.
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  cp "$home/data/backlog.md" "$home/backlog.intact.md"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  answered_out=$(tasks_in "$home" show "$hold" --full 2>&1) && \
    fail "the archival step left the answered hold readable in the backlog"
  assert_contains "$answered_out" "code: NOT_FOUND" \
    "archival did not surface as a not-found: $answered_out"
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/archived-ok.err" \
    || fail "verify rejected a genuinely archived answered hold: $(cat "$home/archived-ok.err")"

  # A backlog that cannot be read is a different failure, and it must not pass.
  cp "$home/backlog.intact.md" "$home/data/backlog.md"
  chmod 000 "$home/data/backlog.md"
  unreadable_err=$(tasks_in "$home" show "$hold" --full 2>&1)
  case "$unreadable_err" in
    *"code: NOT_FOUND"*)
      chmod 644 "$home/data/backlog.md"
      fail "an unreadable backlog reported not-found, so this case cannot tell the two apart"
      ;;
  esac
  if run_decisions "$home" verify "$id" > "$home/unreadable.out" 2> "$home/unreadable.err"; then
    chmod 644 "$home/data/backlog.md"
    fail "verify passed while the backlog could not be read at all"
  fi
  chmod 644 "$home/data/backlog.md"
  # The refusal has to name the real cause. Calling an unreadable backlog a deleted
  # hold sends the operator hunting for a missing item that was never removed.
  assert_contains "$(cat "$home/unreadable.err")" "could not be read" \
    "the unreadable-backlog refusal did not say the hold could not be read"
  case "$(cat "$home/unreadable.err")" in
    *"is absent from"*)
      fail "the unreadable-backlog refusal claimed the hold was absent"
      ;;
  esac
  pass "verify treats only a real not-found as archival and refuses when the backlog cannot be read"
}

# tasks-axi answers "not found in this backlog" for a hold retention trimmed AND for a
# backlog that is missing, empty, or no longer a backlog. Only the first is archival.
# A destroyed backlog means the durable record is gone, not retired, so treating it as
# archival would clear the last gate before teardown erases the source too.
test_verify_refuses_when_the_backlog_was_destroyed() {
  local home id hold mode err
  home=$(make_home wiped-backlog)
  id=sample-wiped-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the wiped sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create wiped-backlog origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample wiped review\n\nOne choice was answered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the wiped sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the wiped-backlog hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the wiped-backlog origin"
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the wiped-backlog choice"
  # bin/fm-send.sh appends this delivered-answer line when the answer reaches the mate.
  printf 'resolved [key=choice]: answered: captain chose option A\n' >> "$home/state/$id.status"
  cp "$home/data/backlog.md" "$home/backlog.intact.md"

  # Real archival first: the answered Done hold is trimmed out of an intact backlog.
  grep -v "$hold" "$home/backlog.intact.md" > "$home/data/backlog.md"
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/trimmed.err" \
    || fail "verify rejected a genuinely archived answered hold: $(cat "$home/trimmed.err")"

  # Each destroyed backlog still lists the hold, so nothing was retired. tasks-axi
  # reports the same not-found for all of them, and every one must refuse.
  for mode in deleted empty junk; do
    cp "$home/backlog.intact.md" "$home/data/backlog.md"
    case "$mode" in
      deleted) rm -f "$home/data/backlog.md" ;;
      empty) : > "$home/data/backlog.md" ;;
      junk) printf 'not a backlog at all\n' > "$home/data/backlog.md" ;;
    esac
    if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
      fail "the $mode backlog still resolved the hold, so this case proves nothing"
    fi
    if run_decisions "$home" verify "$id" > "$home/$mode.out" 2> "$home/$mode.err"; then
      fail "verify accepted a $mode backlog as proof the hold was archived"
    fi
    err=$(cat "$home/$mode.err")
    case "$err" in
      *"is absent from"*)
        fail "the $mode-backlog refusal claimed the hold was absent: $err"
        ;;
    esac
    assert_contains "$err" "$hold" \
      "the $mode-backlog refusal did not name the hold it could not confirm"
  done
  pass "verify refuses a deleted, empty, or unstructured backlog instead of reading it as archival"
}

# tasks-axi treats any level-2 heading whose text starts with "done" as the Done
# section, and it writes back whichever heading the file already had. So a real home
# may spell it "## Done (last 10)". The archival tolerance has to recognise that file
# as a backlog, or such a home can never finish teardown.
test_verify_accepts_archival_under_a_custom_done_heading() {
  local home id hold
  home=$(make_home custom-done-heading)
  id=sample-custom-heading-review
  # Re-spell the Done heading the way tasks-axi allows, before any task exists.
  printf '## In flight\n\n## Queued\n\n## Done (last 10)\n' > "$home/data/backlog.md"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the custom-heading sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create custom-heading origin"
  grep -qx -- '## Done (last 10)' "$home/data/backlog.md" \
    || fail "tasks-axi did not preserve the custom Done heading, so this case proves nothing"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample custom-heading review\n\nOne choice was answered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the custom-heading sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the custom-heading hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the custom-heading origin"
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the custom-heading choice"
  # bin/fm-send.sh appends this delivered-answer line when the answer reaches the mate.
  printf 'resolved [key=choice]: answered: captain chose option A\n' >> "$home/state/$id.status"

  # Retention trims the answered Done hold out of the otherwise intact backlog.
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/custom-heading.err" \
    || fail "verify rejected an archived answered hold because the Done heading is spelled '## Done (last 10)': $(cat "$home/custom-heading.err")"
  pass "verify accepts archival in a backlog whose Done heading carries trailing text"
}

# bin/fm-brief.sh tells a mate to append its own `resolved [key=<slug>]: <why it is no
# longer active>` line when a keyed phase fizzles or a blocker clears without anyone
# answering, into the very status file this gate reads. That line closes the key for
# the fold but proves nothing about a captain answer, so an archived hold backed only
# by a self-close must still fail before teardown erases the source.
test_verify_refuses_a_mate_self_close_as_an_answer() {
  local home id hold
  home=$(make_home self-close-answer)
  id=sample-selfclose-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the self-close sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create self-close origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample self-close review\n\nThe phase ended with no captain answer.\n' \
    > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the self-close sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the self-close hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the self-close origin"
  # The mate closes its own keyed phase. No captain answer, no answer/resolve/decline.
  {
    printf 'resolved [key=choice]: no longer active, that branch was abandoned\n'
    printf 'done: report complete\n'
  } >> "$home/state/$id.status"
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  if run_decisions "$home" verify "$id" > "$home/selfclose.out" 2> "$home/selfclose.err"; then
    fail "verify accepted a mate's own self-close as proof the captain answered"
  fi
  assert_contains "$(cat "$home/selfclose.err")" "$hold" \
    "the self-close refusal did not name the absent hold, so a different gate refused it"

  # Even hand-writing the exact delivered-answer marker a mate could forge does not
  # rescue it: the status-log route was removed as forgeable, so only a real close
  # path's answered_keys record counts, and this origin never went through one.
  printf 'resolved [key=choice]: answered: captain chose option A\n' >> "$home/state/$id.status"
  if run_decisions "$home" verify "$id" > "$home/selfclose-forged.out" 2> "$home/selfclose-forged.err"; then
    fail "verify accepted a forged answered marker that no close path ever recorded"
  fi
  assert_contains "$(cat "$home/selfclose-forged.err")" "$hold" \
    "the forged-marker refusal did not name the absent hold, so a different gate refused it"
  pass "verify refuses a mate's own self-close and a forged answered marker with no durable record"
}

# tasks-axi reports the same not-found for a hold retention trimmed and a hold that
# was never written at all, and a captain can answer a keyed status decision through
# fm-send without any hold existing. So an answered status line alone cannot stand in
# for a durable backlog record. The origin's recorded decision_keys is what tells the
# two apart: `complete` writes a key there only after finding its hold durable.
test_completion_refuses_a_key_that_was_never_held() {
  local home id
  home=$(make_home never-held)
  id=sample-never-held-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the never-held sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create never-held origin"
  write_origin_meta "$home" "$id"
  printf '# Sample never-held review\n\nA choice was answered but never held.\n' \
    > "$home/data/$id/report.md"
  # The captain answered in the status channel. bin/fm-send.sh writes this line
  # whenever --resolve-key closes a keyed decision, with no hold involved.
  {
    printf 'needs-decision [key=choice]: choose sample option A or option B\n'
    printf 'resolved [key=choice]: answered: captain picked A\n'
    printf 'done: report complete\n'
  } > "$home/state/$id.status"
  if tasks_in "$home" show "$id-decision-choice" --full >/dev/null 2>&1; then
    fail "the never-held fixture already has a hold, so it proves nothing"
  fi

  if run_decisions "$home" complete "$id" choice \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "complete accepted a key whose hold was never registered"
  fi
  assert_contains "$(cat "$home/never-held.err")" "$id-decision-choice" \
    "the never-held refusal did not name the missing hold"
  if grep -q '^decision_keys=' "$home/state/$id.meta"; then
    fail "a refused completion still recorded the never-held key as inventoried"
  fi

  # Registering the hold first is what makes the same call succeed, so the refusal
  # above is about the missing hold and not about the fixture being malformed.
  run_decisions "$home" hold "$id" choice \
    --title "Choose the sample option" --reason "captain sample choice pending" --repo sample >/dev/null \
    || fail "could not register the hold for the never-held origin"
  run_decisions "$home" complete "$id" choice >/dev/null 2> "$home/held.err" \
    || fail "complete refused a key whose hold was registered: $(cat "$home/held.err")"
  pass "completion refuses a key whose hold was never registered, and accepts it once held"
}

# A decision key is an ordinary slug, so nothing stops one from being named after the
# answer marker itself. Such a key must clear the archival tolerance like any other, or
# its origin can never finish teardown.
# The real captain-answer ordering, end to end through the actual scripts. `complete`
# transfers the still-open decision to its hold with a captain-held line, which closes
# the live status copy, so a later captain answer is routed to the hold-close path and
# writes NO status line at all. The only durable proof left after Done-history
# retention trims the hold is the origin's answered_keys record, so this is the case
# that decides whether scout teardown can ever proceed on a genuinely answered
# decision. Nothing here hand-writes an answer marker or an answered_keys line.
test_verify_tolerates_archival_on_the_real_answer_ordering() {
  local home id hold
  home=$(make_home real-order-archived)
  id=sample-real-order
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the real-order sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create real-order origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample real-order review\n\nOne choice was answered after completion.\n' \
    > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the real-order sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the real-order hold"

  # Completion first, exactly as the documented order runs it. Its captain-held
  # transfer closes the key in the status fold before any answer exists.
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the real-order origin"
  grep -q "captain-held \[key=choice\]" "$home/state/$id.status" \
    || fail "precondition: complete did not transfer the decision to its hold"
  case "$(meta_value_in "$home" "$id" answered_keys)" in
    *choice*) fail "an unanswered decision was already recorded as answered" ;;
  esac

  # The captain answers through the real hold-close path, which is where fm-send.sh
  # routes a key the captain-held transfer already closed.
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the real-order choice through the close path"
  assert_contains "$(tasks_in "$home" show "$hold" --full)" "state: done" \
    "the real-order answer left its captain hold open"
  assert_contains "$(meta_value_in "$home" "$id" answered_keys)" "choice" \
    "the close path did not durably record the captain answer"
  # The close path writes no status line at all, so the status log carries no answer
  # evidence here; the durable answered_keys record above is the only proof there is.
  if grep -q "answered:" "$home/state/$id.status"; then
    fail "precondition: the close path wrote a status answer marker, so this is not the real ordering"
  fi
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify failed while the answered hold was still in the backlog"

  # Retention trims the answered Done hold out of the backlog.
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "the archival step did not remove the answered hold from the backlog"
  fi
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/real-order.err" \
    || fail "verify rejected a hold answered on the real ordering and then archived: $(cat "$home/real-order.err")"
  run_teardown "$home" "$id" >/dev/null 2> "$home/real-order-teardown.err" \
    || fail "teardown refused after the real-order answer was archived: $(cat "$home/real-order-teardown.err")"
  pass "verify tolerates archival of a hold answered on the real completion-then-answer ordering"
}

# The durable answered_keys record must come from a real close, never from the mere
# fact that a hold once existed. `resolve` and `decline` are the other two close
# paths, so each has to leave the same proof; a hold nobody closed must leave none
# and must keep failing after archival.
test_every_close_path_records_the_captain_answer() {
  local home id hold routed
  home=$(make_home close-path-records)
  id=sample-close-paths
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the close-path sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create close-path origin"
  write_origin_meta "$home" "$id"
  {
    printf 'needs-decision [key=routed]: choose the sample route\n'
    printf 'needs-decision [key=dropped]: choose whether to drop the sample\n'
    printf 'needs-decision [key=stalled]: choose the stalled sample option\n'
  } > "$home/state/$id.status"
  printf '# Sample close-path review\n\nThree choices remained.\n' > "$home/data/$id/report.md"

  routed=sample-followup
  tasks_in "$home" add "$routed" "Do the routed sample work" --repo sample >/dev/null \
    || fail "could not create the routed follow-up task"
  hold=$(run_decisions "$home" hold "$id" routed \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the routed hold"
  tasks_in "$home" block "$routed" --by "$hold" >/dev/null \
    || fail "could not block the follow-up on the routed hold"
  run_decisions "$home" hold "$id" dropped \
    --title "Choose whether to drop the sample" --reason "captain drop choice pending" --repo sample >/dev/null \
    || fail "could not register the dropped hold"
  run_decisions "$home" hold "$id" stalled \
    --title "Choose the stalled sample option" --reason "captain stalled choice pending" --repo sample >/dev/null \
    || fail "could not register the stalled hold"
  run_decisions "$home" complete "$id" routed dropped stalled >/dev/null \
    || fail "completion failed for the close-path origin"

  printf 'Captain routed the work.\n' > "$home/routed-decision.txt"
  run_decisions "$home" resolve "$id" routed \
    --decision-file "$home/routed-decision.txt" --routed-to "$routed" >/dev/null \
    || fail "could not resolve the routed choice"
  printf 'Captain dropped the sample.\n' > "$home/dropped-decision.txt"
  run_decisions "$home" decline "$id" dropped \
    --decision-file "$home/dropped-decision.txt" >/dev/null \
    || fail "could not decline the dropped choice"

  local recorded
  recorded=$(meta_value_in "$home" "$id" answered_keys)
  assert_contains "$recorded" "routed" "resolve did not durably record the captain answer"
  assert_contains "$recorded" "dropped" "decline did not durably record the captain answer"
  case "$recorded" in
    *stalled*) fail "a hold nobody closed was recorded as answered: $recorded" ;;
  esac

  # An exact retry of a close is idempotent and must not grow the record.
  run_decisions "$home" decline "$id" dropped \
    --decision-file "$home/dropped-decision.txt" >/dev/null \
    || fail "an exact decline retry was refused"
  [ "$(meta_value_in "$home" "$id" answered_keys)" = "$recorded" ] \
    || fail "an exact close retry duplicated the durable answer record"

  # Retention trims the two answered Done holds. The still-open one keeps its hold,
  # so verify passes on exactly the durable records the close paths wrote.
  grep -v -e "$id-decision-routed" -e "$id-decision-dropped" "$home/data/backlog.md" \
    > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/close-path.err" \
    || fail "verify rejected two holds each closed through a real close path: $(cat "$home/close-path.err")"

  # Take the never-closed hold out of the backlog too. The origin has ended, which
  # empties the live open set, so its missing durable answer record is the only
  # thing left to refuse on, and it must.
  printf 'done: report complete\n' >> "$home/state/$id.status"
  grep -v "$id-decision-stalled" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed2"
  mv "$home/data/backlog.md.trimmed2" "$home/data/backlog.md"
  if run_decisions "$home" verify "$id" > "$home/stalled.out" 2> "$home/stalled.err"; then
    fail "verify accepted an archived hold that no close path ever answered"
  fi
  assert_contains "$(cat "$home/stalled.err")" "$id-decision-stalled" \
    "the archived never-closed refusal did not name the absent hold: $(cat "$home/stalled.err")"
  pass "every close path records the captain answer durably and an unclosed hold records none"
}

# A durable answered_keys record is proof about the round it closed, not a permanent
# licence. A key is stable and reusable, so a later needs-decision line asks it again,
# and that new round has no hold and no answer. The record must not outrank the live
# question.
test_a_reopened_key_defeats_its_earlier_durable_answer() {
  local home id hold
  home=$(make_home reopened-durable)
  id=sample-reopened-durable
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate a re-asked sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create reopened-durable origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample re-asked review\n\nRound two is still unanswered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the re-asked sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the reopened-durable hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the reopened-durable origin"
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer round one of the re-asked choice"
  assert_contains "$(meta_value_in "$home" "$id" answered_keys)" "choice" \
    "precondition: round one did not leave a durable answer record"

  # Round two asks the same key again. No new hold exists for it.
  printf 'needs-decision [key=choice]: now choose option C or option D\n' \
    >> "$home/state/$id.status"
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  if run_decisions "$home" verify "$id" > "$home/reasked.out" 2> "$home/reasked.err"; then
    fail "verify accepted a re-asked decision on a stale round-one durable answer"
  fi
  pass "a re-asked key is unanswered again despite its earlier durable answer record"
}

test_verify_accepts_an_archived_hold_whose_key_is_named_answered() {
  local home id hold
  home=$(make_home key-named-answered)
  id=sample-answered-key-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the answered-key sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create answered-key origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=answered]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample answered-key review\n\nOne choice was answered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" answered \
    --title "Choose the answered-key sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the answered-key hold"
  run_decisions "$home" complete "$id" answered >/dev/null \
    || fail "completion failed for the answered-key origin"
  printf 'Captain chose option A.\n' > "$home/answered-decision.txt"
  run_decisions "$home" answer "$id" answered --decision-file "$home/answered-decision.txt" >/dev/null \
    || fail "could not answer the answered-key choice"
  # bin/fm-send.sh appends this delivered-answer line when the answer reaches the mate.
  printf 'resolved [key=answered]: answered: captain chose option A\n' >> "$home/state/$id.status"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify failed while the answered-key hold was still in the backlog"

  # Retention trims the answered Done hold out of the backlog.
  grep -v "$hold" "$home/data/backlog.md" > "$home/data/backlog.md.trimmed"
  mv "$home/data/backlog.md.trimmed" "$home/data/backlog.md"
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/answered-key.err" \
    || fail "verify rejected an archived answered hold because its key is named 'answered': $(cat "$home/answered-key.err")"
  pass "verify accepts an archived answered hold whose key is named after the answer marker"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_declined_decision_closes_without_routed_work
test_parked_decision_keeps_identity_and_clears_captain_action
test_reactivated_decision_appends_deferral_cycle
test_park_retry_edges_preserve_state
test_concurrent_park_and_answer_keep_one_decision
test_out_of_band_close_is_repairable_before_teardown
test_unanswered_decision_still_blocks_completion_and_teardown
test_structured_holds_survive_teardown_and_route_resolution
# tasks-axi resolves its backlog from the `path` key of the `[markdown]` table in the
# home's .tasks.toml, so a home that configures a non-default path keeps its whole
# backlog somewhere else. The intactness check that decides archival has to read THAT
# file. A check that assumed data/backlog.md would judge a home by a file tasks-axi
# never touches: it would refuse a real archival because the assumed file is missing,
# and, worse, a stray `path` under some other table could pass a destroyed backlog off
# as an intact one. Both directions are proven here against the real script.
test_verify_reads_the_backlog_path_tasks_axi_resolves() {
  local home id hold
  home=$(make_home configured-backlog-path)
  # The real backlog lives at a configured path, and an unrelated table names a decoy
  # file that tasks-axi ignores and this gate must ignore too.
  mkdir -p "$home/custom" "$home/decoy"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[sqlite]
path = "decoy/backlog.md"

[markdown]
path = "custom/board.md"
done_keep = 10
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/custom/board.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/decoy/backlog.md"
  rm -f "$home/data/backlog.md"

  id=sample-configured-path-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the configured-path sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create configured-path origin"
  assert_grep "$id" "$home/custom/board.md" "tasks-axi did not use the configured backlog path"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample configured-path review\n\nOne choice was answered.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the configured-path option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the configured-path hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the configured-path origin"
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the configured-path choice"
  cp "$home/custom/board.md" "$home/board.intact.md"

  # Real archival out of the configured backlog still clears the gate.
  grep -v "$hold" "$home/board.intact.md" > "$home/custom/board.md"
  run_decisions "$home" verify "$id" >/dev/null 2> "$home/configured.err" \
    || fail "verify rejected archival out of the configured backlog: $(cat "$home/configured.err")"

  # Destroying the configured backlog must refuse, even though the decoy path named by
  # the other table is still a perfectly structured file.
  printf 'not a backlog at all\n' > "$home/custom/board.md"
  assert_grep "## Done" "$home/decoy/backlog.md" "the decoy file stopped being a structured backlog"
  if run_decisions "$home" verify "$id" >/dev/null 2> "$home/decoy.err"; then
    fail "verify read the decoy backlog and accepted a destroyed one as archival"
  fi
  assert_contains "$(cat "$home/decoy.err")" "$hold" \
    "the destroyed configured-backlog refusal did not name the hold"
  pass "verify judges archival from the backlog path tasks-axi resolves, not a decoy"
}

# The durable answer record is an annotation on a LIVE origin's metadata, never a
# reason to bring that metadata back. Teardown deletes state/<origin>.meta on purpose,
# and the whole fleet reads state/*.meta as its register of live workers, so a close
# performed after teardown must leave the directory exactly as it found it. The record
# would be inert anyway: verify reads answered_keys only for a key already in the same
# file's decision_keys, and only `complete` writes those, only into a file that exists.
test_a_post_teardown_close_does_not_resurrect_origin_metadata() {
  local home id hold before after
  home=$(make_home post-teardown-close)
  id=sample-torn-origin
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the torn sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the torn-origin sample"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample torn review\n\nOne choice remained.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" choice \
    --title "Choose the torn sample option" --reason "captain sample choice pending" --repo sample) \
    || fail "could not register the torn-origin hold"
  run_decisions "$home" complete "$id" choice >/dev/null \
    || fail "completion failed for the torn-origin sample"

  # A live origin whose metadata exists records the answer, which is the case the
  # record exists to serve.
  printf 'Captain chose option A.\n' > "$home/choice-decision.txt"
  run_decisions "$home" answer "$id" choice --decision-file "$home/choice-decision.txt" >/dev/null \
    || fail "could not answer the torn-origin choice while it was live"
  assert_contains "$(meta_value_in "$home" "$id" answered_keys)" "choice" \
    "a live origin's close did not record the captain answer"

  # Teardown removes the origin's metadata. Reproduce that end state, then close a
  # second decision the way a post-teardown visual review does.
  hold=$(run_decisions "$home" hold "$id" later \
    --title "Choose the later torn option" --reason "captain later choice pending" --repo sample) \
    || fail "could not register the second torn-origin hold"
  rm -f "$home/state/$id.meta"
  before=$(find "$home/state" | LC_ALL=C sort)
  printf 'Captain chose the later option.\n' > "$home/later-decision.txt"
  run_decisions "$home" answer "$id" later --decision-file "$home/later-decision.txt" >/dev/null \
    || fail "a post-teardown close should still close its hold"
  assert_contains "$(tasks_in "$home" show "$hold" --full)" "state: done" \
    "the post-teardown close did not actually close the hold"
  assert_absent "$home/state/$id.meta" \
    "a post-teardown close recreated the origin metadata teardown deleted"
  after=$(find "$home/state" | LC_ALL=C sort)
  [ "$before" = "$after" ] \
    || fail "a post-teardown close added state files: before [$before] after [$after]"
  pass "a post-teardown close closes its hold without resurrecting origin metadata"
}

test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_bound_channel_answers_close_their_holds_at_answer_time
test_unbound_source_closes_no_hold
test_answer_preserves_every_unrouted_close_guard
test_chat_channel_feeds_the_same_keyed_answer_intake
test_verify_tolerates_answered_hold_archived_out_of_backlog
test_verify_refuses_when_the_backlog_cannot_be_read
test_verify_refuses_a_mate_self_close_as_an_answer
test_completion_refuses_a_key_that_was_never_held
test_verify_accepts_an_archived_hold_whose_key_is_named_answered
test_verify_refuses_when_the_backlog_was_destroyed
test_verify_accepts_archival_under_a_custom_done_heading
test_verify_tolerates_archival_on_the_real_answer_ordering
test_every_close_path_records_the_captain_answer
test_a_reopened_key_defeats_its_earlier_durable_answer
test_verify_reads_the_backlog_path_tasks_axi_resolves
test_a_post_teardown_close_does_not_resurrect_origin_metadata
