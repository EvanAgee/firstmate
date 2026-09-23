#!/usr/bin/env bash
# Tests for bin/fm-spec-point.sh: point a brief still on "Spec: to-spec phase"
# at the one spec its lane wrote, before a guarded local landing
# (docs/specs/fm-spec-gate-brief-and-landing.md, AC5-AC8).
#
# Each case builds a fixture firstmate home and a scratch project whose lane
# worktree commits spec files, and supplies a stub linter through FM_SPEC_LINT:
# it prints a fault and fails for any spec containing BADSPEC, and passes the rest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

POINT="$ROOT/bin/fm-spec-point.sh"
TMP_ROOT=$(fm_test_tmproot fm-spec-point-tests)
LINT="$TMP_ROOT/spec-lint"
cat > "$LINT" <<'SH'
#!/usr/bin/env bash
if grep -q BADSPEC "$1"; then
  echo 'spec-lint: not a spec in the hardened shape (1 fault)'
  echo '- missing section: Seams'
  exit 1
fi
echo 'spec-lint: ok (1 acceptance criteria: AC1)'
SH
chmod +x "$LINT"

# make_task <case> <id> <spec-line> <lane-file>...: a home whose brief carries
# <spec-line> between two fixed lines, and a project whose lane worktree
# fm/<id> commits each <lane-file>. Echoes the home.
make_task() {
  local case_dir="$TMP_ROOT/$1" id=$2 spec_line=$3 home proj wt f
  shift 3
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/state" "$home/data/$id"
  fm_git_init_commit "$proj" >/dev/null
  git -C "$proj" branch -M main
  git -C "$proj" worktree add -q -b "fm/$id" "$wt"
  for f in "$@"; do
    mkdir -p "$wt/$(dirname "$f")"
    case "$f" in
      *bad*) printf '# BADSPEC\n' > "$wt/$f" ;;
      *) printf '# %s\n' "$f" > "$wt/$f" ;;
    esac
  done
  git -C "$wt" add -A
  git -C "$wt" commit -qm lanework
  fm_write_meta "$home/state/$id.meta" "project=$proj" "worktree=$wt" mode=local-only kind=ship
  printf '%s\n' 'You are a crewmate.' "$spec_line" 'The rest of the brief.' > "$home/data/$id/brief.md"
  printf '%s\n' "$home"
}

run_point() {  # <home> <id> <case>
  FM_HOME="$1" FM_SPEC_LINT="$LINT" "$POINT" "$2" > "$TMP_ROOT/$3/out" 2> "$TMP_ROOT/$3/err"
}

# AC5
test_points_a_to_spec_phase_brief_at_its_one_linted_spec() {
  local home brief rc
  home=$(make_task point t5 'Spec: to-spec phase' docs/specs/widget.md src/widget.txt)
  brief="$home/data/t5/brief.md"
  run_point "$home" t5 point; rc=$?
  expect_code 0 "$rc" "point: fm-spec-point failed: $(cat "$TMP_ROOT/point/err")"
  printf '%s\n' 'You are a crewmate.' 'Spec: docs/specs/widget.md' 'The rest of the brief.' \
    | cmp -s - "$brief" || fail "point: brief was not rewritten to exactly the spec line: $(cat "$brief")"
  assert_contains "$(cat "$TMP_ROOT/point/out")" "docs/specs/widget.md" "point: output did not name the spec"
  pass "fm-spec-point points a to-spec-phase brief at the one spec its lane wrote"
}

# AC6
test_refuses_a_branch_that_changed_no_spec() {
  local home brief before rc
  home=$(make_task none t6a 'Spec: to-spec phase' src/a.txt)
  brief="$home/data/t6a/brief.md"
  before=$(cat "$brief")
  run_point "$home" t6a none; rc=$?
  expect_code 1 "$rc" "none: a lane with no spec should be refused"
  assert_contains "$(cat "$TMP_ROOT/none/err")" "changed 0 specs" "none: refusal did not say it found no spec"
  [ "$(cat "$brief")" = "$before" ] || fail "none: a refused point changed the brief"
  pass "fm-spec-point refuses a lane that changed no spec"
}

# AC6
test_refuses_a_branch_that_changed_two_specs() {
  local home brief before rc err
  home=$(make_task two t6b 'Spec: to-spec phase' docs/specs/a.md docs/specs/b.md)
  brief="$home/data/t6b/brief.md"
  before=$(cat "$brief")
  run_point "$home" t6b two; rc=$?
  expect_code 1 "$rc" "two: a lane with two specs should be refused"
  err=$(cat "$TMP_ROOT/two/err")
  assert_contains "$err" "changed 2 specs" "two: refusal did not count the specs"
  assert_contains "$err" "docs/specs/a.md" "two: refusal did not list the first spec"
  assert_contains "$err" "docs/specs/b.md" "two: refusal did not list the second spec"
  [ "$(cat "$brief")" = "$before" ] || fail "two: a refused point changed the brief"
  pass "fm-spec-point refuses a lane that changed two specs"
}

# AC7
test_refuses_a_spec_that_does_not_lint() {
  local home brief before rc
  home=$(make_task lint t7 'Spec: to-spec phase' docs/specs/bad.md)
  brief="$home/data/t7/brief.md"
  before=$(cat "$brief")
  run_point "$home" t7 lint; rc=$?
  expect_code 1 "$rc" "lint: a spec that fails the linter should be refused"
  assert_contains "$(cat "$TMP_ROOT/lint/err")" "- missing section: Seams" "lint: refusal did not print the linter's fault"
  [ "$(cat "$brief")" = "$before" ] || fail "lint: a refused point changed the brief"
  pass "fm-spec-point refuses a spec that does not lint"
}

# AC8
test_leaves_an_already_pointed_brief_alone() {
  local home brief before rc
  home=$(make_task pointed t8 'Spec: EvanAgee/firstmate#140' docs/specs/a.md docs/specs/b.md)
  brief="$home/data/t8/brief.md"
  before=$(cat "$brief")
  run_point "$home" t8 pointed; rc=$?
  expect_code 0 "$rc" "pointed: an already-pointed brief should pass: $(cat "$TMP_ROOT/pointed/err")"
  assert_contains "$(cat "$TMP_ROOT/pointed/out")" "EvanAgee/firstmate#140" "pointed: output did not name the spec it already names"
  [ "$(cat "$brief")" = "$before" ] || fail "pointed: an already-pointed brief was changed"
  pass "fm-spec-point leaves an already-pointed brief alone"
}

test_points_a_to_spec_phase_brief_at_its_one_linted_spec
test_refuses_a_branch_that_changed_no_spec
test_refuses_a_branch_that_changed_two_specs
test_refuses_a_spec_that_does_not_lint
test_leaves_an_already_pointed_brief_alone
