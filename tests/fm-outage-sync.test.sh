#!/usr/bin/env bash
# Tests for bin/fm-outage-sync.sh: reconcile local outage landings with GitHub on
# return. It fast-forward-pushes a locally-landed commit to origin, dispatches the
# deferred schedule-only workflows, and clears the ledger entry - but refuses to
# force-push a diverged main, and is idempotent.
#
# Matrix:
#   (a) a clean-ahead local main is fast-forward-pushed to origin, the deferred
#       workflows are dispatched (gh-axi workflow run), and the ledger entry clears
#   (b) idempotent: re-running after a successful sync is a no-op - the commit is
#       already an ancestor of origin/main, nothing is pushed or re-dispatched, and
#       the entry still clears
#   (c) a diverged main ESCALATES (non-zero exit), never force-pushes, dispatches
#       nothing, and preserves the ledger entry for a manual rebase
#   (d) an entry whose commit is already on origin (re-run or stacked) does not
#       auto-dispatch its deferred checks, but SAYS SO once rather than silently
#       dropping them
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SYNC="$ROOT/bin/fm-outage-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-outage-sync-tests)

# Build a project with a local bare origin. Local main starts even with origin,
# then advances by one commit (the outage landing) that origin does not have.
# Echoes "PROJ<TAB>ORIGIN<TAB>AFTER_SHA".
make_landed_project() {  # <name>
  local name=$1 dir proj origin after
  dir="$TMP_ROOT/$name"
  proj="$dir/proj"
  origin="$dir/origin.git"
  mkdir -p "$dir"
  git init -q --bare "$origin"
  git -C "$proj" 2>/dev/null init -q "$proj" || git init -q "$proj"
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
  git -C "$proj" branch -M main
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push -q -u origin main
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m "outage landing"
  after=$(git -C "$proj" rev-parse main)
  printf '%s\t%s\t%s\n' "$proj" "$origin" "$after"
}

# Install a recording gh-axi stub into <dir>/fakebin and echo the fakebin path.
make_gh_recorder() {  # <dir>
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin/gh-axi"
}

write_ledger() {  # <state> <proj> <after> <deferred>
  local state=$1 proj=$2 after=$3 deferred=$4 ledger
  mkdir -p "$state/outage-landings"
  ledger="$state/outage-landings/proj.log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    2026-01-01T00:00:00Z aos-1-work "$proj" main deadbeef "$after" "$deferred" > "$ledger"
  printf '%s\n' "$ledger"
}

run_sync() {  # <dir> <state> [args...]
  local dir=$1 state=$2; shift 2
  FM_TEST_GH_LOG="$dir/gh.log" FM_GH_BIN="$dir/fakebin/gh-axi" \
    FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" "$SYNC" "$@"
}

test_clean_ahead_pushes_dispatches_and_clears() {
  local dir proj origin after state ledger
  dir="$TMP_ROOT/clean-ahead"
  IFS=$(printf '\t') read -r proj origin after < <(make_landed_project clean-ahead)
  make_gh_recorder "$dir" >/dev/null
  state="$dir/state"
  ledger=$(write_ledger "$state" "$proj" "$after" 'a11y.yml,smoke.yml')
  : > "$dir/gh.log"

  run_sync "$dir" "$state" > "$dir/out" 2> "$dir/err" \
    || fail "clean-ahead: sync should succeed (out: $(cat "$dir/out"); err: $(cat "$dir/err"))"

  [ "$(git -C "$origin" rev-parse main)" = "$after" ] \
    || fail "clean-ahead: origin/main was not fast-forwarded to the landing"
  grep -qxF 'workflow run a11y.yml --ref main' "$dir/gh.log" \
    || fail "clean-ahead: a11y.yml was not dispatched"
  grep -qxF 'workflow run smoke.yml --ref main' "$dir/gh.log" \
    || fail "clean-ahead: smoke.yml was not dispatched"
  assert_absent "$ledger" "clean-ahead: ledger entry was not cleared after the sync"
  pass "fm-outage-sync fast-forward-pushes, dispatches deferred workflows, and clears the ledger"
}

test_idempotent_rerun_is_noop() {
  local dir proj origin after state ledger origin_before
  dir="$TMP_ROOT/idempotent"
  IFS=$(printf '\t') read -r proj origin after < <(make_landed_project idempotent)
  make_gh_recorder "$dir" >/dev/null
  state="$dir/state"

  # First sync pushes and clears.
  write_ledger "$state" "$proj" "$after" 'a11y.yml' >/dev/null
  : > "$dir/gh.log"
  run_sync "$dir" "$state" > "$dir/out1" 2> "$dir/err1" \
    || fail "idempotent: first sync failed: $(cat "$dir/err1")"
  origin_before=$(git -C "$origin" rev-parse main)

  # Re-add the same (already-synced) entry and sync again: the commit is now an
  # ancestor of origin/main, so nothing is pushed or dispatched, entry still clears.
  ledger=$(write_ledger "$state" "$proj" "$after" 'a11y.yml')
  : > "$dir/gh.log"
  run_sync "$dir" "$state" > "$dir/out2" 2> "$dir/err2" \
    || fail "idempotent: second sync should be a clean no-op: $(cat "$dir/err2")"

  [ "$(git -C "$origin" rev-parse main)" = "$origin_before" ] \
    || fail "idempotent: origin/main changed on an idempotent re-run"
  [ ! -s "$dir/gh.log" ] \
    || fail "idempotent: a workflow was re-dispatched on an idempotent re-run: $(cat "$dir/gh.log")"
  assert_absent "$ledger" "idempotent: ledger entry was not cleared on the no-op re-run"
  pass "fm-outage-sync is idempotent: a re-run after a successful sync is a no-op"
}

test_diverged_main_escalates_never_forces() {
  local dir proj origin after state ledger other origin_before rc
  dir="$TMP_ROOT/diverged"
  IFS=$(printf '\t') read -r proj origin after < <(make_landed_project diverged)
  make_gh_recorder "$dir" >/dev/null
  state="$dir/state"

  # Advance origin/main independently via a second clone -> divergence.
  other="$dir/other"
  git clone -q "$origin" "$other"
  git -C "$other" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m "someone else"
  git -C "$other" push -q origin main
  origin_before=$(git -C "$origin" rev-parse main)

  ledger=$(write_ledger "$state" "$proj" "$after" 'a11y.yml')
  : > "$dir/gh.log"

  set +e
  run_sync "$dir" "$state" > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "diverged: sync must exit non-zero when a landing diverged"
  assert_grep 'diverged' "$dir/err" "diverged: escalation did not name the divergence"
  [ "$(git -C "$origin" rev-parse main)" = "$origin_before" ] \
    || fail "diverged: origin/main was moved (a force-push) instead of escalating"
  [ ! -s "$dir/gh.log" ] \
    || fail "diverged: a workflow was dispatched despite the divergence"
  assert_present "$ledger" "diverged: the ledger entry must be preserved for a manual rebase"
  assert_grep "$after" "$ledger" "diverged: the preserved ledger lost the landing SHA"
  pass "fm-outage-sync escalates a diverged main and never force-pushes"
}

test_already_on_origin_notes_undispatched_deferred() {
  local dir proj origin after state ledger
  dir="$TMP_ROOT/already-on-origin"
  IFS=$(printf '\t') read -r proj origin after < <(make_landed_project already-on-origin)
  make_gh_recorder "$dir" >/dev/null
  state="$dir/state"

  # Push the landing to origin first, so the ledger entry is already an ancestor
  # (the stacked / re-run case), then sync with the entry still naming deferred
  # checks.
  git -C "$proj" push -q origin main
  ledger=$(write_ledger "$state" "$proj" "$after" 'a11y.yml,smoke.yml')
  : > "$dir/gh.log"

  run_sync "$dir" "$state" > "$dir/out" 2> "$dir/err" \
    || fail "already-on-origin: sync should succeed for an already-pushed landing: $(cat "$dir/err")"

  [ ! -s "$dir/gh.log" ] \
    || fail "already-on-origin: deferred checks were auto-dispatched despite the commit already being on origin: $(cat "$dir/gh.log")"
  assert_contains "$(cat "$dir/out")" 'not auto-dispatched' \
    "already-on-origin: the undispatched deferred checks were not surfaced"
  assert_contains "$(cat "$dir/out")" 'a11y.yml,smoke.yml' \
    "already-on-origin: the note did not name the deferred checks"
  assert_absent "$ledger" "already-on-origin: the entry should still clear"
  pass "fm-outage-sync notes undispatched deferred checks for an already-on-origin landing"
}

test_clean_ahead_pushes_dispatches_and_clears
test_idempotent_rerun_is_noop
test_diverged_main_escalates_never_forces
test_already_on_origin_notes_undispatched_deferred
