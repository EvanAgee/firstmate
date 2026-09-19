#!/usr/bin/env bash
# Behavior tests for bin/fm-flow.sh, the per-project flow switch.
#
# fm-flow.sh flips one project between the full PR flow ([no-mistakes-prod-only
# +yolo]) and the fast local-only flow ([local-only +yolo]), flipping the two
# GitHub rulesets with it. These tests cover the spec's Tests section
# (docs/specs/flow-switch.md):
#   - registry rewrite round-trip: fast then full restores the exact line
#   - ruleset matching: zero, one, and many candidates
#   - drift verdict when the sides disagree
#   - refusal without the post-merge guard workflow
#   - idempotent second fast run
# GitHub calls go through a fake `gh` binary on PATH (FM_GH_BIN), the same
# stub-per-fakebin pattern the sibling suites use; nothing here touches the
# real GitHub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

FLOW="$ROOT/bin/fm-flow.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-tests)

# --- fixtures ---------------------------------------------------------------

# make_fake_gh <dir> <mode> <ruleset-file> <prs-file>: a fake `gh` answering
# the exact calls fm-flow.sh makes. mode controls which endpoint fails:
#   ok          everything succeeds
#   guard-down  the contents read for the post-merge workflow returns 404
#   put-403     the ruleset PUT answers HTTP 403
# <ruleset-file> holds one JSON ruleset object per line with
# id/name/target/enforcement/conditions/rules.
make_fake_gh() {
  local dir=$1 mode=$2 prs=$4
  local rulesets="$dir/rulesets.json"
  cp "$3" "$rulesets"
  local path="$dir/gh"
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
MODE="$mode"
RULESETS="$rulesets"
PRS="$prs"
api() {
  local endpoint=\$1
  shift
  case "\$endpoint" in
    */rulesets)
      jq -r '. | "\(.id)\t\(.name)"' "\$RULESETS"
      ;;
    */rulesets/*)
      local id=\${endpoint##*/}
      jq -e "select(.id == \$id)" "\$RULESETS"
      ;;
    */contents/.github/workflows/main-postmerge.yml*)
      if [ "\$MODE" = guard-down ]; then
        echo '{"message":"Not Found","status":"404"}' >&2
        exit 1
      fi
      echo '"guard"'
      ;;
    */contents/.github/workflows/main-postmerge-proof.yml*)
      echo '"guard"'
      ;;
    *)
      echo '{}' ;;
  esac
}
case "\$1 \$2" in
  "api repos/"*)
    endpoint=\$2
    shift 2
    if [ "\${1:-}" = "-X" ]; then
      # PUT: enforcement write; persist so a later full sees the new state.
      if [ "\$MODE" = put-403 ]; then
        echo 'gh: Not Found (HTTP 403)' >&2
        exit 1
      fi
      id=\${endpoint##*/}
      enf=\$(cat | jq -r .enforcement)
      jq --argjson id "\$id" --arg enf "\$enf" \
        'if .id == \$id then .enforcement = \$enf else . end' "\$RULESETS" > "\$RULESETS.new" \
        && mv "\$RULESETS.new" "\$RULESETS"
      exit 0
    fi
    api "\$endpoint"
    ;;
  "pr list")
    cat "\$PRS" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$path"
}

# new_case <name>: a fresh FM_HOME with a registry naming one project, a
# captain.md with a Working style header, and a project clone with an origin
# remote. Echoes the home dir.
new_case() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/projects/$name"
  git -C "$home/projects/$name" init -q
  git -C "$home/projects/$name" commit -q --allow-empty -m init
  git -C "$home/projects/$name" remote add origin "https://github.com/test-owner/$name.git"
  printf -- '- %s [no-mistakes-prod-only +yolo] - Test project (added 2026-09-01)\n' "$name" \
    > "$home/data/projects.md"
  printf '# Captain preferences\n\n## Working style\n' > "$home/data/captain.md"
  printf '%s\n' "$home"
}

# make_ruleset <id> <name> <enforcement> <cond> <rules...>: one ruleset JSON
# line for the fake ruleset file.
make_ruleset() {
  local id=$1 name=$2 enforcement=$3 cond=$4
  shift 4
  jq -cn --arg id "$id" --arg name "$name" --arg enf "$enforcement" --arg cond "$cond" \
    --argjson rules "$(printf '%s\n' "$@" | jq -s .)" \
    '{id: ($id | tonumber), name: $name, target: "branch", enforcement: $enf,
      bypass_actors: [],
      conditions: {ref_name: {include: [$cond], exclude: []}},
      rules: $rules}'
}

# run_flow <home> <fakebin> [args...]: run fm-flow.sh with the home's data and
# the fakebin first on PATH.
run_flow() {
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE="$home" FM_GH_BIN=gh PATH="$fakebin:$PATH" \
    "$FLOW" "$@" 2>&1
}

# --- shared ruleset fixtures ------------------------------------------------

RULESETS_MAIN_REVIEW_OK="$TMP_ROOT/rulesets-main-review-ok.json"
make_ruleset 17617595 "Copilot review for default branch" active "~DEFAULT_BRANCH" '{"type":"deletion"}' '{"type":"non_fast_forward"}' > "$RULESETS_MAIN_REVIEW_OK"
make_ruleset 20852194 "Automatic Copilot code review" active "~ALL" '{"type":"copilot_code_review"}' >> "$RULESETS_MAIN_REVIEW_OK"
make_ruleset 23315573 "Commit identity: repo accounts only" active "~ALL" '{"type":"commit_author_email_pattern"}' >> "$RULESETS_MAIN_REVIEW_OK"

# Main ruleset missing: only the review and an unrelated ruleset exist.
RULESETS_NO_MAIN="$TMP_ROOT/rulesets-no-main.json"
make_ruleset 20852194 "Automatic Copilot code review" active "~ALL" '{"type":"copilot_code_review"}' > "$RULESETS_NO_MAIN"
make_ruleset 23315573 "Commit identity: repo accounts only" active "~ALL" '{"type":"commit_author_email_pattern"}' >> "$RULESETS_NO_MAIN"

# Main ruleset disabled: not a candidate, so zero matches.
RULESETS_MAIN_DISABLED="$TMP_ROOT/rulesets-main-disabled.json"
make_ruleset 17617595 "Copilot review for default branch" disabled "~DEFAULT_BRANCH" '{"type":"deletion"}' > "$RULESETS_MAIN_DISABLED"
make_ruleset 20852194 "Automatic Copilot code review" active "~ALL" '{"type":"copilot_code_review"}' >> "$RULESETS_MAIN_DISABLED"

# Many: two active branch rulesets targeting ~DEFAULT_BRANCH.
RULESETS_MAIN_MANY="$TMP_ROOT/rulesets-main-many.json"
make_ruleset 17617595 "Copilot review for default branch" active "~DEFAULT_BRANCH" '{"type":"deletion"}' > "$RULESETS_MAIN_MANY"
make_ruleset 999000 "Protect main too" active "~DEFAULT_BRANCH" '{"type":"non_fast_forward"}' >> "$RULESETS_MAIN_MANY"
make_ruleset 20852194 "Automatic Copilot code review" active "~ALL" '{"type":"copilot_code_review"}' >> "$RULESETS_MAIN_MANY"

# Main ruleset already carries the gates (pull_request + required_status_checks):
# the spec's original shape, still a valid target-condition match.
RULESETS_MAIN_GATED="$TMP_ROOT/rulesets-main-gated.json"
make_ruleset 22292075 "main: required checks" active "~DEFAULT_BRANCH" '{"type":"required_status_checks"}' '{"type":"pull_request"}' > "$RULESETS_MAIN_GATED"
make_ruleset 20852194 "Automatic Copilot code review" active "~ALL" '{"type":"copilot_code_review"}' >> "$RULESETS_MAIN_GATED"

: > "$TMP_ROOT/prs-empty.txt"

# --- tests ------------------------------------------------------------------

test_registry_round_trip() {
  local home fakebin out line_before line_after
  home=$(new_case roundtrip)
  fakebin=$(fm_fakebin "$TMP_ROOT/roundtrip-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  line_before=$(grep -F 'roundtrip' "$home/data/projects.md")

  out=$(run_flow "$home" "$fakebin" roundtrip fast)
  assert_contains "$out" "registry: [no-mistakes-prod-only +yolo] -> [local-only +yolo]" \
    "fast reported the registry flip"
  assert_grep '- roundtrip [local-only +yolo] - Test project (added 2026-09-01)' \
    "$home/data/projects.md" "registry line flipped to fast posture"
  assert_grep '- roundtrip [local-only +yolo] - Test project (added 2026-09-01)' \
    "$home/data/projects.md" "description and date kept intact"
  assert_grep 'no-mistakes-prod-only +yolo' "$home/state/.flow-roundtrip" \
    "previous posture stored for full"
  assert_contains "$out" "ruleset 17617595 enforcement -> disabled" \
    "main ruleset disabled"
  assert_contains "$out" "ruleset 20852194 enforcement -> disabled" \
    "review ruleset disabled"
  assert_grep 'Flow switch push authority' "$home/data/captain.md" \
    "push-authority line appended"
  assert_grep 'may push roundtrip main without asking' "$home/data/captain.md" \
    "push-authority line names the project"

  out=$(run_flow "$home" "$fakebin" roundtrip full)
  assert_contains "$out" "line restored from" \
    "full reported the registry restore"
  assert_contains "$out" "ruleset 17617595 enforcement -> active" \
    "main ruleset reactivated"
  assert_contains "$out" "ruleset 20852194 enforcement -> active" \
    "review ruleset reactivated"
  line_after=$(grep -F 'roundtrip' "$home/data/projects.md")
  [ "$line_before" = "$line_after" ] || fail "full did not restore the exact registry line"
  ! grep -qF 'may push roundtrip main without asking' "$home/data/captain.md" \
    || fail "push-authority line not removed"
  pass "fast then full restores the exact registry line and removes the push line"
}

test_ruleset_zero_main_matches() {
  local home fakebin out
  home=$(new_case zeromain)
  fakebin=$(fm_fakebin "$TMP_ROOT/zeromain-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_NO_MAIN" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" zeromain fast)
  assert_contains "$out" "expected exactly one main-protection ruleset" \
    "zero main rulesets refuse"
  ! grep -qF '[local-only +yolo]' "$home/data/projects.md" \
    || fail "registry was rewritten despite the refusal"
  pass "zero main-protection candidates refuse and leave the registry untouched"
}

test_ruleset_disabled_main_still_discovered() {
  local home fakebin out
  home=$(new_case dismain)
  fakebin=$(fm_fakebin "$TMP_ROOT/dismain-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_DISABLED" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" dismain status)
  assert_contains "$out" "main-protection=17617595" \
    "a disabled main ruleset is still discovered by target"
  assert_contains "$out" "main-protection ruleset 17617595 enforcement: disabled" \
    "status reports the disabled enforcement"
  assert_contains "$out" "verdict: DRIFT" \
    "main disabled while review active is DRIFT"
  pass "a disabled main ruleset is still discovered by its target condition"
}

test_ruleset_many_main_matches() {
  local home fakebin out
  home=$(new_case manymain)
  fakebin=$(fm_fakebin "$TMP_ROOT/manymain-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_MANY" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" manymain fast)
  assert_contains "$out" "found 2" "two main candidates refuse"
  pass "two main-protection candidates refuse"
}

test_ruleset_gated_main_still_matches() {
  local home fakebin out
  home=$(new_case gated)
  fakebin=$(fm_fakebin "$TMP_ROOT/gated-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_GATED" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" gated status)
  assert_contains "$out" "main-protection=22292075" "gated main ruleset matched by target"
  assert_contains "$out" "pull_request + required_status_checks present" \
    "status reports both gates present"
  pass "a main ruleset carrying pull_request + required_status_checks still matches"
}

test_status_drift_verdict() {
  local home fakebin out
  home=$(new_case drift)
  fakebin=$(fm_fakebin "$TMP_ROOT/drift-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  # Both sides full: registry full-form, rulesets active.
  out=$(run_flow "$home" "$fakebin" drift status)
  assert_contains "$out" "verdict: full" "registry full + rulesets active is full"

  # Both sides fast: fast stores the previous posture and disables the rulesets.
  run_flow "$home" "$fakebin" drift fast >/dev/null
  out=$(run_flow "$home" "$fakebin" drift status)
  assert_contains "$out" "verdict: fast" "registry fast + rulesets disabled is fast"

  # One side hand-edited back to full while the rulesets stay disabled: DRIFT.
  sed -i.bak 's/\[local-only +yolo\]/[no-mistakes-prod-only +yolo]/' "$home/data/projects.md"
  rm -f "$home/data/projects.md.bak"
  out=$(run_flow "$home" "$fakebin" drift status)
  assert_contains "$out" "verdict: DRIFT" "registry full + rulesets disabled is DRIFT"

  # full restores both sides from the stored posture.
  run_flow "$home" "$fakebin" drift full >/dev/null
  out=$(run_flow "$home" "$fakebin" drift status)
  assert_contains "$out" "verdict: full" "full restored both sides"
  pass "status verdict tracks agreement and disagreement"
}

test_fast_refuses_without_guard_workflow() {
  local home fakebin out
  home=$(new_case noguard)
  fakebin=$(fm_fakebin "$TMP_ROOT/noguard-fakebin")
  make_fake_gh "$fakebin" guard-down "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" noguard fast)
  assert_contains "$out" "post-merge workflow (.github/workflows/main-postmerge.yml) is absent" \
    "absent guard workflow refuses"
  assert_contains "$out" "--no-guard" "refusal names the override"
  ! grep -qF '[local-only +yolo]' "$home/data/projects.md" \
    || fail "registry was rewritten despite the guard refusal"

  out=$(run_flow "$home" "$fakebin" noguard fast --no-guard "captain approved the risk")
  assert_contains "$out" "proceeding under --no-guard" "override proceeds with the reason"
  assert_grep '[local-only +yolo]' "$home/data/projects.md" "override flipped the registry"
  pass "fast refuses without the guard workflow and --no-guard overrides with a reason"
}

test_fast_idempotent_second_run() {
  local home fakebin out1 out2 registry_after_first registry_after_second captain_after_first captain_after_second
  home=$(new_case idem)
  fakebin=$(fm_fakebin "$TMP_ROOT/idem-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  out1=$(run_flow "$home" "$fakebin" idem fast)
  assert_contains "$out1" "ruleset 17617595 enforcement -> disabled" "first fast flips"
  registry_after_first=$(cat "$home/data/projects.md")
  captain_after_first=$(cat "$home/data/captain.md")

  out2=$(run_flow "$home" "$fakebin" idem fast)
  assert_contains "$out2" "already [local-only +yolo]" "second fast sees the registry done"
  assert_contains "$out2" "ruleset 17617595 already disabled" \
    "second fast skips the disabled ruleset"
  assert_contains "$out2" "no changes needed; already fast" "second fast says it changed nothing"
  registry_after_second=$(cat "$home/data/projects.md")
  captain_after_second=$(cat "$home/data/captain.md")
  [ "$registry_after_first" = "$registry_after_second" ] || fail "second fast changed the registry"
  [ "$captain_after_first" = "$captain_after_second" ] || fail "second fast changed captain.md"
  assert_grep 'Flow switch push authority' "$home/data/captain.md" \
    "second fast did not duplicate the push-authority line"
  [ "$(grep -cF 'Flow switch push authority' "$home/data/captain.md")" = "1" ] \
    || fail "push-authority line duplicated"
  pass "a second fast run changes nothing and says so"
}

test_put_403_refuses_without_retry() {
  local home fakebin out
  home=$(new_case put403)
  fakebin=$(fm_fakebin "$TMP_ROOT/put403-fakebin")
  make_fake_gh "$fakebin" put-403 "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" put403 fast)
  assert_contains "$out" "403" "a 403 is reported"
  assert_contains "$out" "rate-limit or permission problem" \
    "the 403 is framed as rate limit or permission"
  ! grep -qF '[local-only +yolo]' "$home/data/projects.md" \
    || fail "registry flipped even though the ruleset write was refused"
  pass "a 403 on the ruleset write is reported once and never retried"
}

test_fast_lists_open_prs() {
  local home fakebin out prs
  home=$(new_case prlist)
  fakebin=$(fm_fakebin "$TMP_ROOT/prlist-fakebin")
  printf '%s\n' '#42 fix the widget https://github.com/test-owner/prlist/pull/42' > "$TMP_ROOT/prs-open.txt"
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-open.txt"

  out=$(run_flow "$home" "$fakebin" prlist fast)
  assert_contains "$out" "open PRs on test-owner/prlist" "open PR section printed"
  assert_contains "$out" "fix the widget" "the open PR itself is listed"
  pass "fast prints the project's open PRs so none is stranded"
}

test_full_without_stored_posture_refuses() {
  local home fakebin out
  home=$(new_case nostore)
  fakebin=$(fm_fakebin "$TMP_ROOT/nostore-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" nostore full)
  assert_contains "$out" "no stored previous posture" "full without a fast flip refuses"
  pass "full refuses without a stored previous posture"
}

test_registry_without_annotation_flips() {
  local home fakebin out
  home=$(new_case plain)
  printf -- '- plain - Test project with no annotation (added 2026-09-01)\n' > "$home/data/projects.md"
  fakebin=$(fm_fakebin "$TMP_ROOT/plain-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  out=$(run_flow "$home" "$fakebin" plain fast)
  assert_grep '- plain [local-only +yolo] - Test project with no annotation (added 2026-09-01)' \
    "$home/data/projects.md" "a legacy unannotated line flips and keeps its prose"
  out=$(run_flow "$home" "$fakebin" plain full)
  assert_grep '- plain - Test project with no annotation (added 2026-09-01)' \
    "$home/data/projects.md" "full restores the unannotated line"
  pass "a legacy registry line without an annotation round-trips"
}

test_hand_flip_stored_full_line() {
  local home fakebin out
  home=$(new_case handflip)
  fakebin=$(fm_fakebin "$TMP_ROOT/handflip-fakebin")
  make_fake_gh "$fakebin" ok "$RULESETS_MAIN_REVIEW_OK" "$TMP_ROOT/prs-empty.txt"

  # Reproduce firstmate's hand flip: registry already fast-form, the complete
  # previous line stored under previous_registry_line=, push line present.
  printf -- '%s\n' \
    'previous_registry_line=- handflip [no-mistakes-prod-only] - Test project (added 2026-09-01)' \
    'flipped=2026-09-17 by firstmate by hand' \
    > "$home/state/.flow-handflip"
  printf -- '- handflip [local-only +yolo] - Test project (added 2026-09-01)\n' \
    > "$home/data/projects.md"
  printf -- '- **Flow switch push authority** (2026-09-17): firstmate may push handflip main without asking while fast is on.\n' \
    >> "$home/data/captain.md"

  out=$(run_flow "$home" "$fakebin" handflip status)

  assert_contains "$out" "stored previous posture: - handflip [no-mistakes-prod-only]" \
    "status reports the stored full previous line"
  assert_contains "$out" "registry posture: [local-only +yolo]" \
    "status reads the hand-flipped registry"
  assert_contains "$out" "verdict: DRIFT" \
    "rulesets still active while the registry is fast is DRIFT"

  # A second fast is a no-op on the registry side and says so.
  out=$(run_flow "$home" "$fakebin" handflip fast)
  assert_contains "$out" "registry: already [local-only +yolo]" \
    "second fast on a hand flip is a registry no-op"

  # full restores the exact stored line and removes the push line.
  out=$(run_flow "$home" "$fakebin" handflip full)
  assert_grep '- handflip [no-mistakes-prod-only] - Test project (added 2026-09-01)' \
    "$home/data/projects.md" "full restored the exact hand-flip-stored line"
  ! grep -qF 'may push handflip main without asking' "$home/data/captain.md" \
    || fail "push-authority line not removed on full"
  pass "the hand-flip state file drives status, no-op fast, and exact full restore"
}

test_hand_flip_stored_full_line

test_registry_round_trip
test_ruleset_zero_main_matches
test_ruleset_disabled_main_still_discovered
test_ruleset_many_main_matches
test_ruleset_gated_main_still_matches
test_status_drift_verdict
test_fast_refuses_without_guard_workflow
test_fast_idempotent_second_run
test_put_403_refuses_without_retry
test_fast_lists_open_prs
test_full_without_stored_posture_refuses
test_registry_without_annotation_flips
