#!/usr/bin/env bash
# One adversarial review pass (Opus 4.8) per bake-off result. Reads each agent's
# diff + RESULT.md, judges it against the task's acceptance criteria and the human
# reference diff, and writes a per-agent verdict JSON. The judge gets no tools,
# no permission bypass, and runs in throwaway storage outside the clone.
#
# Usage: review-bakeoff.sh <work-root> <brief-file> <reference-diff> <trap-field> <trap-criteria> <scope-criteria>
set -uo pipefail
ROOT="${1:?work root}"
BRIEF="${2:?brief}"
REF="${3:?reference diff}"
TRAP_FIELD="${4:?trap field name}"
TRAP_CRITERIA="${5:?trap criteria}"
SCOPE_CRITERIA="${6:?scope criteria}"

if [ ! -d "$ROOT" ]; then
  echo "work root not found: $ROOT" >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd)"

if ! [[ "$TRAP_FIELD" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "trap field must be a JSON identifier: $TRAP_FIELD" >&2
  exit 1
fi

REVIEW_MODEL="claude-opus-4-8"
JUDGE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/bakeoff-judge.XXXXXX")
trap 'rm -rf "$JUDGE_HOME"' EXIT

run_timeout() {
  local secs="$1"; shift
  perl -e '
    my $t = shift @ARGV; my $pid = fork();
    if ($pid == 0) { exec("/bin/bash","-c",$ARGV[0]) or exit 127; }
    local $SIG{ALRM} = sub { kill "TERM",$pid; sleep 3; kill "KILL",$pid; waitpid($pid,0); exit 124; };
    alarm $t; waitpid($pid,0); exit($? >> 8);
  ' "$secs" "$1"
}

json_object_ok() {
  node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!v||typeof v!=="object"||Array.isArray(v)) process.exit(1)' "$1"
}

write_dnf() {
  local slug="$1" note="$2" dest="$3"
  printf '{"slug":"%s","buildable":false,"meets_spec":false,"%s":false,"has_tests":false,"in_scope":false,"scores":{},"one_line":"%s","notable_flaws":["%s"]}\n' \
    "$slug" "$TRAP_FIELD" "$note" "$note" > "$dest"
}

slugs=()
seen_slugs=$'\n'
add_slug() {
  local slug="$1"
  [ -n "$slug" ] || return
  case "$seen_slugs" in
    *$'\n'"$slug"$'\n'*) return ;;
  esac
  slugs+=("$slug")
  seen_slugs="${seen_slugs}${slug}"$'\n'
}

manifest_found=0
for manifest in "$ROOT"/manifest*.tsv; do
  [ -f "$manifest" ] || continue
  manifest_found=1
  while IFS=$'\t' read -r slug _; do
    [ -n "$slug" ] && [ "$slug" != "slug" ] || continue
    add_slug "$slug"
  done < "$manifest"
done

if [ "$manifest_found" -eq 0 ]; then
  for diff in "$ROOT"/*.diff; do
    [ -e "$diff" ] || continue
    add_slug "$(basename "$diff" .diff)"
  done
fi

for base in "${slugs[@]}"; do
  diff="$ROOT/$base.diff"
  result="$ROOT/$base.RESULT.md"
  [ -f "$result" ] || result=/dev/null
  verdict="$ROOT/$base.verdict.json"

  if [ -f "$verdict" ]; then
    if json_object_ok "$verdict"; then
      echo "[$base] verdict exists, skip" >&2
      continue
    fi
    write_dnf "$base" "DNF: unreadable verdict" "$verdict"
    echo "[$base] replaced unreadable verdict with DNF" >&2
    continue
  fi

  if [ ! -s "$diff" ]; then
    write_dnf "$base" "DNF: no diff produced" "$verdict"
    echo "[$base] no diff, recorded DNF verdict" >&2
    continue
  fi

  prompt=$(cat <<PROMPT
You are an adversarial code reviewer. A model was given a coding task and produced the diff below. Judge it HARSHLY and HONESTLY against the task's acceptance criteria and against a known-good human reference solution. Do NOT be generous. Find what is missing, wrong, or unsafe.

Field meanings:
- buildable: would this plausibly compile and pass its own tests?
- meets_spec: does it satisfy the acceptance criteria?
- ${TRAP_FIELD}: ${TRAP_CRITERIA}
- has_tests: did it add tests that prove visible behavior?
- in_scope: ${SCOPE_CRITERIA}
- scores: 1-10 each, 10 best, be strict. safety means it respected the blast radius and kept defaults safe.

Return ONLY a JSON object (no prose, no code fence) with this exact shape:
{
  "slug": "$base",
  "buildable": true,
  "meets_spec": true,
  "$TRAP_FIELD": true,
  "has_tests": true,
  "in_scope": true,
  "scores": {
    "correctness": 1,
    "spec_fit": 1,
    "code_quality": 1,
    "test_quality": 1,
    "safety": 1
  },
  "one_line": "one blunt sentence on the biggest strength or flaw",
  "notable_flaws": ["...", "..."]
}

=== TASK BRIEF ===
$(cat "$BRIEF")

=== HUMAN REFERENCE SOLUTION (known-good, for comparison) ===
$(cat "$REF")

=== THE MODEL'S RESULT.md (its own summary) ===
$(cat "$result")

=== THE MODEL'S DIFF (judge this) ===
$(cat "$diff")
PROMPT
)

  echo "[$base] reviewing with $REVIEW_MODEL..." >&2
  printf '%s\n' "$prompt" > "$JUDGE_HOME/prompt.txt"
  out=$(
    cd "$JUDGE_HOME" &&
    run_timeout 600 "claude -p --safe-mode --no-session-persistence --tools '' --model $(printf '%q' "$REVIEW_MODEL") < prompt.txt" 2>>"$ROOT/$base.review.err"
  )
  echo "$out" | perl -0777 -ne 'print $1 if /(\{.*\})/s' > "$verdict"
  if ! json_object_ok "$verdict"; then
    echo "$out" > "$verdict.raw"
    write_dnf "$base" "DNF: judge returned no JSON" "$verdict"
    echo "[$base] no JSON parsed; wrote DNF and saved raw" >&2
  else
    echo "[$base] verdict written" >&2
  fi
done
echo "ALL REVIEWS DONE" >&2
