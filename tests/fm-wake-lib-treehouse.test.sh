#!/usr/bin/env bash
# The backported Treehouse pool-ownership helpers in bin/fm-wake-lib.sh:
# fm_treehouse_slot_owner_marker, fm_treehouse_slot_owner_state,
# fm_treehouse_project_lock_path, and fm_firstmate_root_home.
#
# Each helper runs in a fresh shell that sources the real library, so a missing
# function fails loudly (bash exits 127 on the unknown command) instead of
# passing on a stale definition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-lib-treehouse)
HOME_DIR="$TMP_ROOT/home"
POOL="$TMP_ROOT/pool"
SLOT="$POOL/1"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$SLOT"

WAKELIB="$ROOT/bin/fm-wake-lib.sh"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
POOL=$(cd "$POOL" && pwd -P)
SLOT=$(cd "$SLOT" && pwd -P)
MARKER="$POOL/.fm-slot-owner"

# wake_lib_call <function> [args...]: source fm-wake-lib.sh under the fixture
# home, then call the named function with the remaining arguments.
wake_lib_call() {
  local fn=$1
  shift
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash -c '. "$1"; shift; "$@"' _ "$WAKELIB" "$fn" "$@"
}

# wake_lib_owner_state <slot> <task-id>: read the claim and print its globals.
wake_lib_owner_state() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash -c '
      . "$1"; shift
      fm_treehouse_slot_owner_state "$1" "$2"
      printf "%s|%s|%s" "$FM_TREEHOUSE_SLOT_OWNER" "$FM_TREEHOUSE_SLOT_OWNER_ID" "$FM_TREEHOUSE_SLOT_OWNER_HOME"
    ' _ "$WAKELIB" "$1" "$2"
}

# --- fm_treehouse_slot_owner_marker ------------------------------------------

marker=$(wake_lib_call fm_treehouse_slot_owner_marker "$SLOT") \
  || fail "fm_treehouse_slot_owner_marker failed"
expected_marker="$(dirname "$(cd "$SLOT" && pwd -P)")/.fm-slot-owner"
[ "$marker" = "$expected_marker" ] \
  || fail "fm_treehouse_slot_owner_marker returned '$marker', expected '$expected_marker'"
pass "fm_treehouse_slot_owner_marker names the sibling .fm-slot-owner claim"

# --- fm_treehouse_slot_owner_state -------------------------------------------

rm -f "$MARKER"
state=$(wake_lib_owner_state "$SLOT" task-a)
[ "$state" = "absent||" ] \
  || fail "an unclaimed slot did not read absent: '$state'"
pass "fm_treehouse_slot_owner_state reads an unclaimed slot as absent"

printf 'task=other-task\nhome=/elsewhere\n' > "$MARKER"
state=$(wake_lib_owner_state "$SLOT" task-a)
[ "$state" = "other|other-task|/elsewhere" ] \
  || fail "a claim by another task did not read other: '$state'"
pass "fm_treehouse_slot_owner_state reads a foreign claim as other with its evidence"

printf 'task=task-a\nhome=%s\n' "$HOME_DIR" > "$MARKER"
state=$(wake_lib_owner_state "$SLOT" task-a)
[ "$state" = "mine|task-a|$HOME_DIR" ] \
  || fail "a claim naming this task did not read mine: '$state'"
pass "fm_treehouse_slot_owner_state reads this task's own claim as mine"

printf 'garbage\n' > "$MARKER"
state=$(wake_lib_owner_state "$SLOT" task-a)
[ "$state" = "unsafe||" ] \
  || fail "an unreadable claim did not read unsafe: '$state'"
pass "fm_treehouse_slot_owner_state reads an unreadable claim as unsafe"
rm -f "$MARKER"

# --- fm_treehouse_project_lock_path ------------------------------------------

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Firstmate Tests"
git -C "$REPO" config user.email "tests@firstmate.invalid"
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "initial fixture"
git -C "$REPO" remote add origin "https://example.invalid/org/repo.git"

lock_one=$(wake_lib_call fm_treehouse_project_lock_path "$REPO") \
  || fail "fm_treehouse_project_lock_path failed for an origin-backed repo"
lock_two=$(wake_lib_call fm_treehouse_project_lock_path "$REPO") \
  || fail "fm_treehouse_project_lock_path was not repeatable"
[ "$lock_one" = "$lock_two" ] \
  || fail "fm_treehouse_project_lock_path returned different paths for one repo"
case "$lock_one" in
  "$HOME_DIR/state"/.treehouse-project-*.lock) ;;
  *) fail "fm_treehouse_project_lock_path escaped the root home state dir: '$lock_one'" ;;
esac

git -C "$REPO" remote set-url origin "https://example.invalid/org/other.git"
lock_other=$(wake_lib_call fm_treehouse_project_lock_path "$REPO") \
  || fail "fm_treehouse_project_lock_path failed after the origin changed"
[ "$lock_one" != "$lock_other" ] \
  || fail "fm_treehouse_project_lock_path ignored the repo origin identity"
pass "fm_treehouse_project_lock_path keys the shared lock on the origin identity"

NOORIGIN="$TMP_ROOT/no-origin"
mkdir -p "$NOORIGIN"
git -C "$NOORIGIN" init -q -b main
git -C "$NOORIGIN" config user.name "Firstmate Tests"
git -C "$NOORIGIN" config user.email "tests@firstmate.invalid"
printf 'fixture\n' > "$NOORIGIN/README.md"
git -C "$NOORIGIN" add README.md
git -C "$NOORIGIN" commit -qm "initial fixture"
lock_no_origin=$(wake_lib_call fm_treehouse_project_lock_path "$NOORIGIN") \
  || fail "fm_treehouse_project_lock_path failed for an origin-less repo"
case "$lock_no_origin" in
  "$HOME_DIR/state"/.treehouse-project-*.lock) ;;
  *) fail "the origin-less lock escaped the root home state dir: '$lock_no_origin'" ;;
esac
pass "fm_treehouse_project_lock_path falls back to the toplevel for an origin-less repo"

# --- fm_firstmate_root_home --------------------------------------------------

root=$(wake_lib_call fm_firstmate_root_home "$HOME_DIR") \
  || fail "fm_firstmate_root_home failed for a parentless home"
[ "$root" = "$HOME_DIR" ] \
  || fail "fm_firstmate_root_home returned '$root' for a parentless home"
pass "fm_firstmate_root_home returns the home itself when no parent is recorded"

CHILD="$TMP_ROOT/child"
mkdir -p "$CHILD"
CHILD=$(cd "$CHILD" && pwd -P)
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$CHILD/.fm-secondmate-parent"
root=$(wake_lib_call fm_firstmate_root_home "$CHILD") \
  || fail "fm_firstmate_root_home failed for a locally parented home"
[ "$root" = "$HOME_DIR" ] \
  || fail "fm_firstmate_root_home returned '$root' instead of the local parent home"
pass "fm_firstmate_root_home follows a local parent binding to the root home"

printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=host.example\n' > "$CHILD/.fm-secondmate-parent"
root=$(wake_lib_call fm_firstmate_root_home "$CHILD") \
  || fail "fm_firstmate_root_home failed for a remote-parented home"
[ "$root" = "$CHILD" ] \
  || fail "fm_firstmate_root_home followed a remote route instead of stopping at the home"
pass "fm_firstmate_root_home stops at a remote parent route"

printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CHILD" > "$CHILD/.fm-secondmate-parent"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CHILD" > "$HOME_DIR/.fm-secondmate-parent"
if wake_lib_call fm_firstmate_root_home "$CHILD" >/dev/null 2>&1; then
  fail "fm_firstmate_root_home accepted a parent cycle"
fi
rm -f "$HOME_DIR/.fm-secondmate-parent"
pass "fm_firstmate_root_home refuses a parent cycle"

pass "backported Treehouse pool-ownership helpers behave"
