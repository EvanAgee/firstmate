#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Guards the move of AGENTS.md detail into internal skills (#5175).
# 1. Every sentence of the pre-move AGENTS.md, frozen in
#    tests/fixtures/agents-md-before-5175.snapshot, still appears word for word
#    in AGENTS.md or in some .agents/skills/*/SKILL.md, so nothing the move
#    touched was silently dropped. A later change that deliberately rewords or
#    removes one of those sentences deletes it from the snapshot in the same
#    commit.
# 2. Every agent-only internal skill (metadata internal: true and
#    user-invocable: false) is named by a load trigger in AGENTS.md, so no moved
#    reference is unreachable. Captain-invocable skills are loaded by the
#    captain's own command and are exempt.

python3 - "$ROOT" <<'PY' || fail "AGENTS.md coverage check failed (details above)"
import glob, os, re, sys

root = sys.argv[1]

def norm(text):
    return re.sub(r"\s+", " ", text).strip()

def sentences(path):
    out = []
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("```"):
            continue
        line = re.sub(r"^(?:[-*]|\d+\.)\s+", "", line)
        if line:
            out.append(norm(line))
    return out

skills = sorted(glob.glob(os.path.join(root, ".agents/skills/*/SKILL.md")))
agents = open(os.path.join(root, "AGENTS.md"), encoding="utf-8").read()
corpus = norm(agents + "\n" + "\n".join(open(p, encoding="utf-8").read() for p in skills))

before = os.path.join(root, "tests/fixtures/agents-md-before-5175.snapshot")
missing = [s for s in sentences(before) if s not in corpus]
for s in missing:
    print("missing BEFORE sentence: " + s, file=sys.stderr)

untriggered = []
for p in skills:
    head = open(p, encoding="utf-8").read().split("\n---", 1)[0]
    if not re.search(r"^\s*internal:\s*true\s*$", head, re.M):
        continue
    if not re.search(r"^user-invocable:\s*false\s*$", head, re.M):
        continue
    name = os.path.basename(os.path.dirname(p))
    tick = "`" + name + "`"
    if not any(tick in line and re.search(r"\bload", line, re.I) for line in agents.splitlines()):
        untriggered.append(name)
for name in untriggered:
    print("internal skill with no AGENTS.md load trigger: " + name, file=sys.stderr)

sys.exit(1 if missing or untriggered else 0)
PY
pass "every pre-move AGENTS.md sentence survives and every agent-only skill has a load trigger"
