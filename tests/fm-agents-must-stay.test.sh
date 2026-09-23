#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Some AGENTS.md sentences apply on every turn or every captain message, so a
# copy in a skill that loads only in a named situation is not enough (#5175).
# This test fails when any of them leaves AGENTS.md itself. It reads the
# sentences from the frozen pre-move snapshot so the list cannot drift from
# the wording it protects:
# - the preamble, including the captain-address rule;
# - section 1, the identity and hard rules;
# - the captain instruction precedence section;
# - the section 9 core named in SECTION9_CORE below, including the PR-link rule.
# To protect another sentence, add its opening words to SECTION9_CORE or add
# its section to KEEP_SECTIONS.

python3 - "$ROOT" <<'PY' || fail "a must-stay sentence left AGENTS.md (details above)"
import os, re, sys

root = sys.argv[1]

def norm(text):
    return re.sub(r"\s+", " ", text).strip()

def strip_marker(line):
    return norm(re.sub(r"^(?:[-*]|\d+\.)\s+", "", line.strip()))

KEEP_SECTIONS = ["# Firstmate", "## 1. Identity and prime directives", "## Captain instruction precedence"]
SECTION9 = "## 9. Escalation and captain etiquette"
SECTION9_CORE = [
    "**Talk in outcomes, not mechanics.**",
    "Every captain-facing message must translate",
    "Do not expose internal terms",
    "Scout and second mate are accepted",
    "Never relay worker reports",
    "Read them as evidence",
    "Every escalation must stand alone",
    "Lead directly with concrete evidence",
    "Use the same evidence-first form",
    "Reach the captain immediately for:",
    "Work ready for their review",
    "Finished investigation findings",
    "Gate findings that require their decision",
    "A real blocker or failure",
    "Anything destructive, irreversible, or security-sensitive.",
    "A needed credential or login.",
    "Do not surface automatic fixes",
    "When a routine operational update",
    "Whenever a PR is mentioned",
]

sections = {}
current = None
for raw in open(os.path.join(root, "tests/fixtures/agents-md-before-5175.snapshot"), encoding="utf-8"):
    line = raw.rstrip("\n")
    if re.match(r"^#{1,2} ", line):
        current = line
        sections.setdefault(current, [])
        continue
    if current is not None and line.strip() and not line.startswith("```"):
        sections[current].append(strip_marker(line))

required = []
for name in KEEP_SECTIONS + [SECTION9]:
    if name not in sections:
        sys.exit(f"snapshot has no section {name!r}")
for name in KEEP_SECTIONS:
    required.extend(sections[name])
for prefix in SECTION9_CORE:
    hits = [s for s in sections[SECTION9] if s.startswith(prefix)]
    if len(hits) != 1:
        sys.exit(f"section 9 prefix {prefix!r} matches {len(hits)} snapshot sentences, expected 1")
    required.append(hits[0])

agents = norm(open(os.path.join(root, "AGENTS.md"), encoding="utf-8").read())
missing = [s for s in required if s not in agents]
for s in missing:
    print("must-stay sentence missing from AGENTS.md: " + s, file=sys.stderr)
print(f"checked {len(required)} must-stay sentences")
sys.exit(1 if missing else 0)
PY
pass "every must-stay sentence is inline in AGENTS.md"
