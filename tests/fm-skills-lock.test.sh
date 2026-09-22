#!/usr/bin/env bash
# Contract tests for bin/fm-skills-lock.sh: every vendored skill folder's
# lock hash must match the files on disk, and a byte change must fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-skills-lock.sh"
assert_present "$CHECK" "bin/fm-skills-lock.sh is missing"
[ -x "$CHECK" ] || fail "bin/fm-skills-lock.sh must be executable"

TMP_ROOT=$(fm_test_tmproot fm-skills-lock)

write_single_lock() {  # <root> <name>
  python3 - "$ROOT/skills-lock.json" "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
source, root, name = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
entry = data["skills"][name.name]
(root / "skills-lock.json").write_text(
    json.dumps({"version": 1, "skills": {name.name: entry}}) + "\n",
    encoding="utf-8",
)
PY
}

test_repository_lock_matches_vendored_files() {
  local out
  out=$("$CHECK") || fail "repository vendored skill hashes drifted"
  assert_contains "$out" "fm-skills-lock: ok skills=" \
    "lock check did not report exact skill coverage"
  pass "every skills-lock.json hash matches its vendored folder"
}

test_hash_drift_and_missing_folder_fail() {
  local root="$TMP_ROOT/drift" skill=ask-matt out rc
  mkdir -p "$root/.agents/skills"
  cp -R "$ROOT/.agents/skills/$skill" "$root/.agents/skills/$skill"
  write_single_lock "$root" "$skill"
  out=$("$CHECK" --root "$root") || fail "copied matching skill should pass: $out"
  assert_contains "$out" "ok skills=1" "copied matching skill did not report one skill"

  printf '\n' >>"$root/.agents/skills/$skill/SKILL.md"
  set +e
  out=$("$CHECK" --root "$root" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an edited vendored file must fail the lock check"
  assert_contains "$out" "hash drift in .agents/skills/$skill" \
    "drift failure did not name the edited skill"

  rm -rf "$root/.agents/skills/$skill"
  set +e
  out=$("$CHECK" --root "$root" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a missing vendored folder must fail the lock check"
  assert_contains "$out" "missing vendored folder .agents/skills/$skill" \
    "missing-folder failure did not name the skill"
  pass "lock check fails on hash drift and a missing vendored folder"
}

test_repository_lock_matches_vendored_files
test_hash_drift_and_missing_folder_fail

echo "all fm-skills-lock tests passed"
