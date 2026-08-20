#!/usr/bin/env bash
# Behavior tests for bin/fm-omp.sh, the canonical primary omp launch wrapper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-omp.sh"
TURNEND="$ROOT/.pi/extensions/fm-primary-omp-turnend-guard.ts"
WATCH="$ROOT/.pi/extensions/fm-primary-omp-watch.ts"
TMP_ROOT=$(fm_test_tmproot fm-omp)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")

install_fake_omp() {
  cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${FM_TEST_OMP_ARGV}"
printf 'ran\n' > "${FM_TEST_OMP_RAN}"
exit "${FM_TEST_OMP_EXIT:-0}"
SH
  chmod +x "$FAKEBIN/omp"
}

nul_eq() {
  cmp -s "$1" "$2"
}

install_fake_omp
assert_present "$TURNEND" "fixture turn-end extension is missing from this checkout"
assert_present "$WATCH" "fixture watcher extension is missing from this checkout"

# Happy path: the wrapper must exec omp with both -e flags, then passthrough args.
: > "$TMP_ROOT/argv.bin"
: > "$TMP_ROOT/ran"
printf '%s\0' -e "$TURNEND" -e "$WATCH" --foo 'bar baz' > "$TMP_ROOT/expected.bin"
set +e
out=$(
  FM_OMP_BIN="$FAKEBIN/omp" \
    FM_TEST_OMP_ARGV="$TMP_ROOT/argv.bin" \
    FM_TEST_OMP_RAN="$TMP_ROOT/ran" \
    FM_TEST_OMP_EXIT=7 \
    "$WRAPPER" --foo 'bar baz' 2>"$TMP_ROOT/stderr"
)
rc=$?
set -e
[ "$rc" -eq 7 ] || fail "wrapper did not preserve omp exit status (got $rc)"
[ -s "$TMP_ROOT/ran" ] || fail "wrapper did not exec the omp override"
nul_eq "$TMP_ROOT/expected.bin" "$TMP_ROOT/argv.bin" \
  || fail "wrapper did not exec omp with both -e flags then passthrough args"
[ -z "$out" ] || fail "wrapper leaked stdout before exec"
pass "wrapper execs omp with both -e flags, passthrough args, and omp's exit status"

# PATH lookup when FM_OMP_BIN is unset.
: > "$TMP_ROOT/argv.bin"
rm -f "$TMP_ROOT/ran"
printf '%s\0' -e "$TURNEND" -e "$WATCH" > "$TMP_ROOT/expected-empty.bin"
set +e
PATH="$FAKEBIN:/usr/bin:/bin" \
  FM_TEST_OMP_ARGV="$TMP_ROOT/argv.bin" \
  FM_TEST_OMP_RAN="$TMP_ROOT/ran" \
  env -u FM_OMP_BIN \
  "$WRAPPER" >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "PATH omp lookup failed (got $rc): $(cat "$TMP_ROOT/stderr")"
[ -s "$TMP_ROOT/ran" ] || fail "wrapper did not exec PATH omp when FM_OMP_BIN was unset"
nul_eq "$TMP_ROOT/expected-empty.bin" "$TMP_ROOT/argv.bin" \
  || fail "PATH omp did not receive both -e flags"
pass "wrapper uses command -v omp when FM_OMP_BIN is unset"

# Missing extension files fail loud and never exec omp.
missing_root="$TMP_ROOT/missing-root"
mkdir -p "$missing_root/.pi/extensions"
cp "$WATCH" "$missing_root/.pi/extensions/fm-primary-omp-watch.ts"
rm -f "$TMP_ROOT/ran"
set +e
err=$(
  FM_ROOT_OVERRIDE="$missing_root" FM_OMP_BIN="$FAKEBIN/omp" \
    FM_TEST_OMP_RAN="$TMP_ROOT/ran" \
    "$WRAPPER" 2>&1
)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing turn-end extension was accepted"
assert_contains "$err" "error:" "missing turn-end extension did not fail loud"
assert_contains "$err" "fm-primary-omp-turnend-guard.ts" "missing turn-end extension did not name the file"
assert_absent "$TMP_ROOT/ran" "missing turn-end extension still exec'd omp"
pass "wrapper fails loud when the turn-end extension is missing"

mkdir -p "$missing_root/.pi/extensions"
rm -f "$missing_root/.pi/extensions/"*
cp "$TURNEND" "$missing_root/.pi/extensions/fm-primary-omp-turnend-guard.ts"
rm -f "$TMP_ROOT/ran"
set +e
err=$(
  FM_ROOT_OVERRIDE="$missing_root" FM_OMP_BIN="$FAKEBIN/omp" \
    FM_TEST_OMP_RAN="$TMP_ROOT/ran" \
    "$WRAPPER" 2>&1
)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing watcher extension was accepted"
assert_contains "$err" "error:" "missing watcher extension did not fail loud"
assert_contains "$err" "fm-primary-omp-watch.ts" "missing watcher extension did not name the file"
assert_absent "$TMP_ROOT/ran" "missing watcher extension still exec'd omp"
pass "wrapper fails loud when the watcher extension is missing"

# Missing omp binary fails before any launch.
rm -f "$TMP_ROOT/ran"
set +e
err=$(
  PATH="/usr/bin:/bin" env -u FM_OMP_BIN "$WRAPPER" 2>&1
)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing omp on PATH was accepted"
assert_contains "$err" "error:" "missing omp did not fail loud"
assert_contains "$err" "omp" "missing omp did not name the executable"
pass "wrapper fails loud when omp is not on PATH"

echo "ALL TESTS PASSED"
