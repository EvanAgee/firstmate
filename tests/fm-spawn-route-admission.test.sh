#!/usr/bin/env bash
# Behavior tests for provider-availability admission inside fm-spawn.sh: a
# class-based spawn acquires a route through bin/fm-route.sh before the
# dispatch resolver picks a concrete profile, and finishes that assignment
# exactly once on exit (data/fm-dynamic-subscription-routing/report.md
# addendum). The fake tmux/launch harness below is trimmed from
# tests/fm-spawn-dispatch-profile.test.sh's proven fixture (tests/lib.sh's own
# doc comment: harness-specific fakes belong with the tests that own them,
# not a shared library).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-route-admission)
RUN_TOKEN="t$$-${RANDOM:-0}"
profile_id() { printf '%s-%s' "$1" "$RUN_TOKEN"; }
cleanup() {
  local data_dir id home tasktmp
  while IFS= read -r data_dir; do
    id=$(basename "$data_dir")
    home=$(dirname "$(dirname "$data_dir")")
    tasktmp=$(sed -n 's/^tasktmp=//p' "$home/state/$id.meta" 2>/dev/null)
    [ -n "$tasktmp" ] || tasktmp="/tmp/fm-$id"
    case "$id:$tasktmp" in
      profile-*:/tmp/fm-"$id") rm -rf "$tasktmp" ;;
    esac
  done < <(find "$TMP_ROOT" -type d -path '*/home/data/profile-*' 2>/dev/null)
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session) exit 0 ;;
  kill-window) exit 0 ;;
  new-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' "Pi 0.84.0" 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/worker-home/.agents/skills/caveman" "$case_dir/worker-home/.agents/skills/ponytail"
  printf 'CAVEMAN_FIXTURE_BODY\n' > "$case_dir/worker-home/.agents/skills/caveman/SKILL.md"
  printf 'PONYTAIL_FIXTURE_BODY\n' > "$case_dir/worker-home/.agents/skills/ponytail/SKILL.md"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  # pi/xai model naming matches config/crew-dispatch.json's real approved
  # builder pool shape, which fm_route_group_for maps to route id pi-grok;
  # the standalone "grok" harness is a different, deprecated billing surface
  # (report: "Grok uses native Pi, not the separately billed Grok Build
  # adapter") and would resolve to an unrecognized route instead.
  printf '%s\n' '{"rules":[{"class":"builder","when":"builder work","use":[{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

# Unpinned pool: a disabled pinned member always refuses without a captain
# override (fm-dispatch-resolve.sh's existing, unrelated pin-safety
# behavior), so route-health fallback across the pool is only observable
# without a pin in the way.
enable_unpinned_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","when":"builder work","use":[{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"pi","model":"xai/grok-4.6","effort":"high"}]}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 worker_home
  shift 4
  worker_home="${launchlog%/*}/../worker-home"
  : > "$launchlog"
  HOME="$worker_home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    BASH_ENV='' GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

make_route_home() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config"
  printf '%s\n' "$case_dir"
}

seed_route_state() {  # <home> <json>
  printf '%s' "$2" > "$1/state/route.json"
}

test_class_spawn_acquires_and_finishes_route() {
  local rec id out status route_home rec_json
  id=$(profile_id profile-route-admit-z1)
  rec=$(make_spawn_case profile-route-admit codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-admit)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "class spawn with an eligible route should launch"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report resolved codex harness"

  rec_json=$(cat "$route_home/state/route.json")
  assert_contains "$rec_json" '"status":"closed"' "acquired assignment was not closed on successful launch"
  assert_contains "$rec_json" '"outcome":"success"' "closed assignment did not record a success outcome"
  assert_contains "$rec_json" '"profile":{"adapter":"codex","model":"gpt-5","effort":"high"}' "closed assignment did not record the resolved profile identity"
  pass "a class-based spawn acquires a route and finishes it successfully"
}

test_class_spawn_excludes_ineligible_route() {
  local rec id out status route_home rec_json
  id=$(profile_id profile-route-exclude-z2)
  rec=$(make_spawn_case profile-route-exclude codex "$id")
  read_case_record "$rec"
  enable_unpinned_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-exclude)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  # codex exhausted; grok remains eligible, so acquire must steer the
  # resolver away from the excluded codex member and onto grok instead.
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "class spawn should fall through to the eligible route"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not fall back to the eligible pi/grok route"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi xai/grok-4.6 high

  rec_json=$(cat "$route_home/state/route.json")
  assert_contains "$rec_json" '"route":"pi-grok"' "acquired assignment did not record the eligible route"
  pass "a class-based spawn excludes an exhausted route from an unpinned pool and lands on the eligible one"
}

test_class_spawn_refuses_when_every_route_excluded() {
  local rec id out status route_home
  id=$(profile_id profile-route-deferred-z3)
  rec=$(make_spawn_case profile-route-deferred codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-deferred)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"outage","reason":"down","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "class spawn should refuse when every approved route is excluded"
  assert_contains "$out" "no approved route is currently eligible for class 'builder'" \
    "spawn did not explain the provider-availability refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn should not have written meta"
  pass "a class-based spawn refuses to launch when every approved route is excluded"
}

test_captain_override_bypasses_route_admission() {
  local rec id out status route_home rec_json
  id=$(profile_id profile-route-override-z4)
  rec=$(make_spawn_case profile-route-override codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-override)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"exhausted","reason":"0%","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --harness codex --model gpt-5 --effort high \
    --captain-override "captain wants codex regardless")
  status=$?
  expect_code 0 "$status" "an explicit captain override should bypass route admission entirely"
  assert_contains "$out" "spawned $id harness=codex" "captain override did not launch codex"

  rec_json=$(cat "$route_home/state/route.json")
  assert_contains "$rec_json" '"assignments":{}' \
    "a captain override must not touch the provider-availability assignment ledger"
  pass "a captain override bypasses provider-availability admission the same way it bypasses the enabled filter"
}

test_launch_failure_releases_route_assignment() {
  local rec id out status route_home rec_json
  id=$(profile_id profile-route-launchfail-z6)
  rec=$(make_spawn_case profile-route-launchfail codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-launchfail)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'
  # A real post-acquire launch failure fm-spawn.sh cannot see in advance:
  # freshen_spawn_worktree_base's unconditional `git fetch origin` (called
  # after dispatch/acquire, before any launch command is sent) fails once
  # origin is broken, exercising the actual failure path rather than a
  # simulated one.
  rm -rf "$PROJ_DIR.origin.git"

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "a broken origin fetch should fail the spawn after acquire ran"
  assert_contains "$out" "could not fetch origin for pooled worktree" \
    "spawn did not hit the expected post-acquire failure point"

  rec_json=$(cat "$route_home/state/route.json")
  assert_contains "$rec_json" '"status":"closed"' "a failed launch must still close its acquired assignment"
  assert_contains "$rec_json" '"outcome":"launch-failed"' \
    "a failed launch must record launch-failed, releasing the slot for a retry"
  assert_not_contains "$rec_json" '"outcome":"success"' \
    "a failed launch must never record a success outcome"
  pass "a real post-acquire launch failure releases its acquired route assignment exactly once"
}

test_no_class_spawn_never_touches_route_store() {
  local rec id out status route_home
  id=$(profile_id profile-route-noclass-z5)
  rec=$(make_spawn_case profile-route-noclass codex "$id")
  read_case_record "$rec"
  route_home=$(make_route_home route-noclass)

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a non-class spawn should still launch"
  [ ! -f "$route_home/state/route.json" ] \
    || fail "a spawn with no --class must never create a provider-availability record"
  pass "a spawn with no dispatch class never touches the route store"
}

test_class_spawn_acquires_and_finishes_route
test_class_spawn_excludes_ineligible_route
test_class_spawn_refuses_when_every_route_excluded
test_captain_override_bypasses_route_admission
test_launch_failure_releases_route_assignment
test_no_class_spawn_never_touches_route_store

echo "# all fm-spawn-route-admission tests passed"
