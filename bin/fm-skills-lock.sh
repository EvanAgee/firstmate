#!/usr/bin/env bash
# fm-skills-lock.sh - verify vendored skill folders against skills-lock.json.
#
# Usage:
#   bin/fm-skills-lock.sh
#   bin/fm-skills-lock.sh --root <repo>
#
# Each lock entry's computedHash is SHA-256 over every regular file in
# .agents/skills/<name>/, feeding the POSIX-relative path then the file
# bytes, files ordered by case-insensitive path then the original path
# (JavaScript localeCompare order). Directories named .git or node_modules
# are skipped. A drift, missing folder, or malformed lock fails the run.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "fm-skills-lock: --root requires a path" >&2; exit 2; }
      ROOT=$(cd "$2" && pwd) || exit 2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "fm-skills-lock: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

cd "$ROOT"
export FM_SKILLS_LOCK_ROOT="$ROOT"
exec python3 - <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(os.environ["FM_SKILLS_LOCK_ROOT"])
LOCK_PATH = ROOT / "skills-lock.json"
SKILLS_ROOT = ROOT / ".agents" / "skills"
SKIP_DIRS = {".git", "node_modules"}


def fail(message: str) -> None:
    print(f"fm-skills-lock: {message}", file=sys.stderr)
    raise SystemExit(1)


def folder_hash(folder: Path) -> str:
    files: list[tuple[str, bytes]] = []
    for dirpath, dirnames, filenames in os.walk(folder, followlinks=False):
        dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
        for name in filenames:
            path = Path(dirpath) / name
            if not path.is_file() or path.is_symlink():
                continue
            rel = path.relative_to(folder).as_posix()
            files.append((rel, path.read_bytes()))
    files.sort(key=lambda item: (item[0].lower(), item[0]))
    digest = hashlib.sha256()
    for rel, content in files:
        digest.update(rel.encode("utf-8"))
        digest.update(content)
    return digest.hexdigest()


try:
    data = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
except FileNotFoundError:
    fail(f"lock file is missing: {LOCK_PATH}")
except (OSError, json.JSONDecodeError) as exc:
    fail(f"lock file is unreadable: {exc}")

if not isinstance(data, dict):
    fail("lock root must be an object")
skills = data.get("skills")
if not isinstance(skills, dict) or not skills:
    fail("lock skills must be a non-empty object")

errors = 0
for name, meta in sorted(skills.items()):
    if not isinstance(name, str) or not name:
        print("fm-skills-lock: lock skill name must be a non-empty string", file=sys.stderr)
        errors += 1
        continue
    if not isinstance(meta, dict):
        print(f"fm-skills-lock: lock entry {name} must be an object", file=sys.stderr)
        errors += 1
        continue
    want = meta.get("computedHash")
    if not isinstance(want, str) or not want:
        print(f"fm-skills-lock: lock entry {name} is missing computedHash", file=sys.stderr)
        errors += 1
        continue
    folder = SKILLS_ROOT / name
    if not folder.is_dir():
        print(f"fm-skills-lock: missing vendored folder .agents/skills/{name}", file=sys.stderr)
        errors += 1
        continue
    got = folder_hash(folder)
    if got != want:
        print(
            f"fm-skills-lock: hash drift in .agents/skills/{name} (lock={want} got={got})",
            file=sys.stderr,
        )
        errors += 1

if errors:
    raise SystemExit(1)
print(f"fm-skills-lock: ok skills={len(skills)}")
PY
