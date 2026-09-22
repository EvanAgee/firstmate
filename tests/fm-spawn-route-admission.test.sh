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
# The root requires every brief to carry nonempty ## Captain's intent and
# ## Firstmate spec subsections (AGENTS.md section 11), which the fork's
# one-line brief predates; fm_test_spawn_brief is the root's own writer for
# that shape, so these cases use it rather than a second local copy.
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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
  *'#{socket_path}'*) printf '%s\n' "${FM_HOME:-/tmp}/tmux.sock"; exit 0 ;;
  *'#{pid}'*) printf '%s\n' "$FM_FAKE_TMUX_SERVER_PID"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -f "$0.windows" ] || cat "$0.windows"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  kill-window) rm -f "$0.windows"; exit 0 ;;
  new-window)
    while [ "$#" -gt 1 ]; do
      [ "$1" != -n ] || { printf '%s\n' "$2" > "$0.windows"; break; }
      shift
    done
    printf '@fake\n'; exit 0 ;;
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
  # Run the command unbounded. Real callers use both `timeout <dur> cmd` and
  # `timeout -k <dur> <dur> cmd`, so skip every leading option and its value
  # plus the duration rather than assuming a fixed argument count.
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k|--kill-after|-s|--signal) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
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
  # omp/bun fakes are the proven bytes from tests/fm-spawn-dispatch-profile.test.sh;
  # fm-omp-capabilities.sh refuses a fake without this exact --help surface and
  # bun-backed shebang.
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bun
case "${1:-}" in
  --help)
    printf '%s\n' '--model=<value>' '--thinking=<value>' '--auto-approve' '--session-dir=<value>' '-e, --extension=<value>' '-r, --resume=<value>'
    [ "${FM_FAKE_OMP_APPEND:-yes}" != yes ] || printf '%s\n' '--append-system-prompt=<path>'
    ;;
  --version) printf 'omp/17.1.8\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/omp"
  cat > "$fakebin/bun" <<'SH'
#!/usr/bin/env bash
script=$1
shift
exec bash "$script" "$@"
SH
  chmod +x "$fakebin/bun"
  # A class spawn resolves through bin/fm-dispatch-resolve.sh, whose
  # model_exhausted filter reads quota-axi for claude and codex members.
  # Without this stub these cases reach the REAL quota-axi, so a model the
  # captain's account has genuinely spent would drop its rung and change the
  # pool under test. These cases are about admission, not live quota, so the
  # reading is pinned healthy.
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider=claude
case "$*" in *"--provider codex"*) provider=codex ;; *"--provider grok"*) provider=grok ;; esac
scope=all_models
[ "$provider" != grok ] || scope=all_products
cat <<JSON
{"schemaVersion":3,"providers":[{"provider":"$provider","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"$scope","status":"known","effectivePercentRemaining":50}]},"state":{"status":"fresh","stale":false,"refreshedAt":"2026-09-15T00:00:00.000Z"}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
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
    fm_test_spawn_brief "$home" "$id"
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

# omp-only pool, matching the harness whose pre-launch guards and
# post-launch acknowledgement gate make both refusal classes observable.
# (omp,gpt-5) maps to route id "omp" (fm_route_group_for's fallback rule).
enable_omp_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","when":"builder work","use":[{"harness":"omp","model":"gpt-5","effort":"high"}],"pin":{"harness":"omp","model":"gpt-5","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
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
  # shellcheck disable=SC2034 # CASE_DIR is part of the record shape; not every test needs it.
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

# A failure after the route claim but before the harness process starts is
# not route evidence: the claim must be RELEASED (the assignment record is
# deleted outright), so the route keeps its recorded state and the freed id
# retries as a fresh acquire instead of hitting "already closed".
test_post_acquire_prelaunch_failure_releases_route_claim_and_retries() {
  local rec id out status route_home rec_json retry_out retry_status
  id=$(profile_id profile-route-prelaunch-z6)
  rec=$(make_spawn_case profile-route-prelaunch codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-prelaunch)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  mv "$PROJ_DIR.origin.git" "$PROJ_DIR.origin.git.bak"
  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  mv "$PROJ_DIR.origin.git.bak" "$PROJ_DIR.origin.git"
  expect_code 1 "$status" "a broken origin fetch should fail the spawn after acquire ran"
  assert_contains "$out" "could not fetch origin for pooled worktree" \
    "spawn did not hit the expected post-acquire failure point"

  rec_json=$(cat "$route_home/state/route.json")
  assert_not_contains "$rec_json" "\"$id\"" \
    "a pre-launch failure must release its claim, not close it"
  assert_not_contains "$rec_json" '"launch-failed"' \
    "a pre-launch failure must never record launch-failed"
  assert_contains "$rec_json" '"codex":{"state":"eligible"' \
    "a pre-launch failure must leave the route's recorded state untouched"

  # The failed spawn leaked its endpoint before the harness process ever
  # started (the window is created before the failing fetch); in the fleet
  # the supervisor removes that dead endpoint before respawning, exactly as
  # it always had to. What this change must guarantee is that the ROUTE
  # layer adds no second blocker: no launch-failed exclusion and no closed
  # record turning the same id into "already closed".
  rm -f "$FAKEBIN_DIR/tmux.windows"
  retry_out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  retry_status=$?
  expect_code 0 "$retry_status" "the same task id must retry immediately after a released claim"$'\n'"$retry_out"
  assert_contains "$retry_out" "spawned $id harness=codex" "retry did not launch"
  rec_json=$(jq -c --arg a "$id" '.assignments[$a]' "$route_home/state/route.json")
  assert_contains "$rec_json" '"status":"closed"' "retried spawn's assignment never closed"
  assert_contains "$rec_json" '"outcome":"success"' "retried spawn did not record a success outcome"
  pass "a post-acquire pre-launch failure releases its claim and the same task id retries immediately"
}

# A spawn that fails on its own arguments - a project directory that does
# not resolve, or a --mode the brief disagrees with - must fail BEFORE any
# route is claimed: the route store stays byte-identical, and the corrected
# retry with the same task id launches normally.
test_bare_project_name_refuses_before_route_claim_and_retries() {
  local rec id out status route_home seed_copy rec_json retry_out retry_status
  id=$(profile_id profile-route-barename-z10)
  rec=$(make_spawn_case profile-route-barename codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-barename)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'
  seed_copy="$CASE_DIR/route.seed.json"
  cp "$route_home/state/route.json" "$seed_copy"

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "not-a-project-$RUN_TOKEN" --class builder)
  status=$?
  expect_code 1 "$status" "a bare project name must fail the spawn"
  assert_contains "$out" "No such file or directory" \
    "bare-name spawn did not fail at project directory resolution"
  cmp -s "$CASE_DIR/route.seed.json" "$route_home/state/route.json" \
    || fail "route store changed for a spawn that failed before route admission:\n$(diff "$CASE_DIR/route.seed.json" "$route_home/state/route.json")"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn should not have written meta"

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 0 "$status" "the corrected retry must launch under the same task id"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=codex" "corrected retry did not launch"
  rec_json=$(jq -c --arg a "$id" '.assignments[$a]' "$route_home/state/route.json")
  assert_contains "$rec_json" '"status":"closed"' "retried spawn's assignment never closed"
  assert_contains "$rec_json" '"outcome":"success"' "retried spawn did not record a success outcome"
  pass "a bare project name fails before any route claim, leaving route.json byte-identical, and the retry launches"
}

test_mode_mismatch_refuses_before_route_claim() {
  local rec id out status route_home seed_copy rec_json
  id=$(profile_id profile-route-modemis-z11)
  rec=$(make_spawn_case profile-route-modemis codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf 'Delivery contract: mode=direct-PR\n' >> "$HOME_DIR/data/$id/brief.md"
  route_home=$(make_route_home route-modemis)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'
  seed_copy="$CASE_DIR/route.seed.json"
  cp "$route_home/state/route.json" "$seed_copy"

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "a --mode that disagrees with the brief must fail the spawn"
  assert_contains "$out" "delivery mismatch" "spawn did not name the brief/mode disagreement"
  cmp -s "$CASE_DIR/route.seed.json" "$route_home/state/route.json" \
    || fail "route store changed for a spawn that failed before route admission:\n$(diff "$CASE_DIR/route.seed.json" "$route_home/state/route.json")"

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the retry with the brief's own mode must launch"$'\n'"$out"
  rec_json=$(jq -c --arg a "$id" '.assignments[$a]' "$route_home/state/route.json")
  assert_contains "$rec_json" '"outcome":"success"' "the corrected retry did not record a success outcome"
  pass "a brief/mode disagreement fails before any route claim, route.json byte-identical"
}

# A harness guard that refuses before launch (here: OMP's existing-task
# artifact guard, issue #134's trigger) is evidence about the request, not
# the route: the claim must be released, the route left untouched, and the
# freed id acquirable again immediately.
test_prelaunch_harness_guard_refusal_releases_route_claim() {
  local rec id out status route_home rec_json retry_acquire guard_path
  id=$(profile_id profile-route-ompguard-z12)
  rec=$(make_spawn_case profile-route-ompguard codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  # The fork proved this contract through its OMP preexisting-artifact guard,
  # which belongs to native OMP (upstream-rebase ticket C6) and does not exist
  # on the root. The contract under test here is the release, not that one
  # guard, so this case drives the root's own pre-launch refusal: a task temp
  # root that is not a private directory owned by this user. It refuses at the
  # same point in the spawn, after the route is acquired and before any harness
  # process starts.
  guard_path="/tmp/fm-$id"
  rm -rf "$guard_path"
  ln -s /etc "$guard_path"
  route_home=$(make_route_home route-ompguard)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  rm -f "$guard_path"
  expect_code 1 "$status" "the pre-launch task temp root guard must refuse the spawn"
  assert_contains "$out" "task temp root $guard_path already exists and is not a private directory" \
    "spawn did not fail at the expected harness guard"

  rec_json=$(cat "$route_home/state/route.json")
  assert_contains "$rec_json" '"codex":{"state":"eligible"' \
    "a pre-launch guard refusal must leave the route's recorded state untouched"
  assert_not_contains "$rec_json" '"launch-failed"' \
    "a pre-launch guard refusal must never record launch-failed"
  [ "$(jq --arg a "$id" '.assignments | has($a)' "$route_home/state/route.json")" = false ] \
    || fail "a released claim must delete its assignment record: $(cat "$route_home/state/route.json")"
  retry_acquire=$(jq -cn --arg a "$id" --arg owner "$id" \
    '{assignment_id:$a, owner:{identity:$owner, generation:"g-retry"}, routes:["codex"]}' \
    | FM_ROUTE_HOME_OVERRIDE="$route_home" "$ROOT/bin/fm-route.sh" acquire)
  assert_contains "$retry_acquire" '"result":"selected"' \
    "the released task id must be acquirable again immediately, not refused as already-closed"
  pass "a pre-launch harness guard refusal releases its claim and frees the task id"
}

# A genuine launch failure - the harness process was actually started and
# failed (here: OMP never acknowledged its first turn) - is route evidence
# and still records launch-failed exactly as before, excluding the route.
test_genuine_launch_failure_records_launch_failed() {
  local rec id out status route_home rec_json real_tasks_axi
  id=$(profile_id profile-route-ackfail-z13)
  rec=$(make_spawn_case profile-route-ackfail codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  # The fork proved this through its OMP first-turn acknowledgement gate, which
  # belongs to native OMP (upstream-rebase ticket C6); the root's own OMP has
  # no such gate. The contract under test is that a failure AFTER the launch
  # command reached the endpoint is evidence against the route, so it records
  # launch-failed rather than releasing the claim. On the root the reachable
  # failure at that point is the backlog In-flight transition, which runs at
  # the commit point after launch delivery, so this case drives that instead.
  real_tasks_axi=$(command -v tasks-axi) \
    || fail "tasks-axi is required to drive the post-launch commit point"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$HOME_DIR/data/backlog.md"
  cat > "$HOME_DIR/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  "$real_tasks_axi" add "$id" "item for $id" --kind ship \
    --file "$HOME_DIR/data/backlog.md" >/dev/null
  # Fail only the transition verb, so every read before the commit point still
  # succeeds and the spawn reaches launch delivery before it fails.
  cat > "$FAKEBIN_DIR/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "start" ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"
  route_home=$(make_route_home route-ackfail)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "a failed backlog transition after launch delivery must fail the spawn"
  assert_contains "$out" "could not be moved to In flight" \
    "spawn did not fail at the expected post-launch commit point"

  rec_json=$(jq -c --arg a "$id" '.assignments[$a]' "$route_home/state/route.json")
  assert_contains "$rec_json" '"status":"closed"' "a genuine launch failure must close its assignment"
  assert_contains "$rec_json" '"outcome":"launch-failed"' \
    "a genuine launch failure must still record launch-failed"
  [ "$(jq -r '.routes.codex.state' "$route_home/state/route.json")" = "launch-failed" ] \
    || fail "a genuine launch failure must still exclude its route: $(cat "$route_home/state/route.json")"
  pass "a genuine launch failure after the harness process started still records launch-failed and excludes the route"
}

# These are the real pool shapes from this repo's own
# docs/examples/crew-dispatch.json, the ones that reproduced live failures:
# builder carries an enabled codex pin inside a three-route pool, and tester
# carries a switched-off pi-grok member. In both cases a candidate route the
# class cannot actually resolve to would win admission and then turn every
# usable pool member into an --exclude-routes entry, failing a healthy spawn.
enable_example_shaped_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"class":"builder","when":"builder work","use":[{"harness":"pi","model":"xai/grok-4.6","effort":"high"},{"harness":"codex","model":"gpt-5","effort":"high"},{"harness":"claude","model":"opus","effort":"high"}],"pin":{"harness":"codex","model":"gpt-5","effort":"high"}},{"class":"tester","when":"test work","use":[{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-5","effort":"xhigh"},{"harness":"pi","model":"xai/grok-4.6","effort":"high","enabled":false}]}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

ALL_ROUTES_ELIGIBLE='{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"claude":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false},"pi-grok":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

# A pinned class always resolves to its pin, so a healthy pinned spawn must
# succeed on EVERY attempt. Repeated across enough spawns to advance the tie
# cursor past all three catalog routes, which is exactly what made the
# unscoped version fail 2 out of every 3 times.
test_pinned_class_spawn_succeeds_on_every_rotation() {
  local rec id out status route_home rec_json n
  route_home=$(make_route_home route-pinned)
  for n in 1 2 3 4; do
    id=$(profile_id "profile-route-pinned-z7$n")
    rec=$(make_spawn_case "profile-route-pinned-$n" codex "$id")
    read_case_record "$rec"
    enable_example_shaped_dispatch_profile "$HOME_DIR"
    cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
    [ -f "$route_home/state/route.json" ] || seed_route_state "$route_home" "$ALL_ROUTES_ELIGIBLE"

    out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --class builder)
    status=$?
    expect_code 0 "$status" "pinned builder spawn #$n must launch, not break its own pin"$'\n'"$out"
    assert_contains "$out" "spawned $id harness=codex" "pinned builder spawn #$n did not land on its pin"
    assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high

    rec_json=$(jq -c --arg a "$id" '.assignments[$a]' "$route_home/state/route.json")
    [ "$(jq -r '.route' <<<"$rec_json")" = codex ] \
      || fail "pinned builder spawn #$n acquired a route other than its pin: $rec_json"
  done
  pass "a pinned class spawn resolves to its pin on every tie-cursor rotation"
}

# tester's only pi-grok member is switched off, so pi-grok must never be
# offered; winning it would exclude claude and codex and empty the pool.
test_disabled_pool_member_never_wins_admission() {
  local rec id out status route_home picked n
  route_home=$(make_route_home route-disabled)
  for n in 1 2 3 4; do
    id=$(profile_id "profile-route-disabled-z9$n")
    rec=$(make_spawn_case "profile-route-disabled-$n" codex "$id")
    read_case_record "$rec"
    enable_example_shaped_dispatch_profile "$HOME_DIR"
    cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
    [ -f "$route_home/state/route.json" ] || seed_route_state "$route_home" "$ALL_ROUTES_ELIGIBLE"

    out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --class tester)
    status=$?
    expect_code 0 "$status" "tester spawn #$n must launch; its enabled members are healthy"$'\n'"$out"
    picked=$(jq -r --arg a "$id" '.assignments[$a].route' "$route_home/state/route.json")
    case "$picked" in
      claude|codex) : ;;
      *) fail "tester spawn #$n acquired '$picked', whose only pool member is switched off" ;;
    esac
  done
  pass "a switched-off pool member's route never wins admission for its class"
}

# A closed assignment record is spent history. If a spawn ever reuses one,
# acquire answers already-closed with no route_id and the spawn must refuse
# rather than launch from a record that authorized nothing.
test_already_closed_assignment_refuses_launch() {
  local rec id out status route_home
  id=$(profile_id profile-route-closed-z8)
  rec=$(make_spawn_case profile-route-closed codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-closed)
  cp "$HOME_DIR/config/crew-dispatch.json" "$route_home/config/crew-dispatch.json"
  # Seed a already-closed record under exactly the assignment id this spawn
  # will use (the task id), owned by the same identity.
  printf '%s' "{\"generation\":1,\"routes\":{\"codex\":{\"state\":\"eligible\",\"reason\":\"ok\",\"observedAt\":\"t\",\"manualDisabled\":false},\"pi-grok\":{\"state\":\"eligible\",\"reason\":\"ok\",\"observedAt\":\"t\",\"manualDisabled\":false}},\"assignments\":{\"$id\":{\"owner\":\"$id\",\"ownerGeneration\":\"g0\",\"status\":\"closed\",\"route\":\"codex\",\"reason\":\"fewest-pending\",\"outcome\":\"success\"}}}" \
    > "$route_home/state/route.json"

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "a spent closed assignment must never authorize a launch"
  assert_contains "$out" "already closed" "spawn did not explain the closed-record refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn should not have written meta"
  pass "an already-closed assignment record never authorizes a fresh launch"
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

# A resolver that cannot answer "which routes can this class use" must refuse
# the spawn, not look identical to "no routing policy configured" and skip the
# admission gate entirely. The duplicate class below makes
# fm-dispatch-resolve.sh's own validation reject the config.
test_class_spawn_refuses_when_candidate_lookup_fails() {
  local rec id out status route_home
  id=$(profile_id profile-route-badcfg-z9)
  rec=$(make_spawn_case profile-route-badcfg codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  route_home=$(make_route_home route-badcfg)
  jq '.rules += [.rules[0]]' "$HOME_DIR/config/crew-dispatch.json" \
    > "$route_home/config/crew-dispatch.json"
  seed_route_state "$route_home" \
    '{"generation":1,"routes":{"codex":{"state":"eligible","reason":"ok","observedAt":"t","manualDisabled":false}},"assignments":{}}'

  out=$(FM_ROUTE_HOME_OVERRIDE="$route_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class builder)
  status=$?
  expect_code 1 "$status" "spawn should refuse when candidate routes cannot be determined"
  assert_contains "$out" "could not determine candidate routes for class 'builder'" \
    "spawn did not report the candidate lookup failure"
  assert_contains "$out" "dispatch class must be unique" \
    "the resolver's own reason never reached the operator's refusal message"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn should not have written meta"
  pass "a failed candidate lookup refuses the spawn instead of silently skipping admission"
}

test_class_spawn_acquires_and_finishes_route
test_class_spawn_excludes_ineligible_route
test_class_spawn_refuses_when_every_route_excluded
test_captain_override_bypasses_route_admission
test_post_acquire_prelaunch_failure_releases_route_claim_and_retries
test_bare_project_name_refuses_before_route_claim_and_retries
test_mode_mismatch_refuses_before_route_claim
test_prelaunch_harness_guard_refusal_releases_route_claim
test_genuine_launch_failure_records_launch_failed
test_pinned_class_spawn_succeeds_on_every_rotation
test_disabled_pool_member_never_wins_admission
test_already_closed_assignment_refuses_launch
test_no_class_spawn_never_touches_route_store
test_class_spawn_refuses_when_candidate_lookup_fails

echo "# all fm-spawn-route-admission tests passed"
