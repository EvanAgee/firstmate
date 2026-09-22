#!/usr/bin/env bash
# Exercise the Unslop workflow's event refs and changed-code ratchet locally.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/unslop.yml"

assert_present "$WORKFLOW" ".github/workflows/unslop.yml is missing"
command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse unslop.yml"
command -v jq >/dev/null 2>&1 || fail "jq is required to run the Unslop gate"

workflow_step() {
  local name=$1
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
step = doc.fetch("jobs").fetch("unslop").fetch("steps").find { |item| item["name"] == ARGV[1] }
raise "missing workflow step: #{ARGV[1]}" unless step
puts step.fetch("run")
' "$WORKFLOW" "$name"
}

test_push_and_pull_request_refs_are_bounded() {
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
events = doc.fetch(true)
raise "push trigger missing" unless events.fetch("push").fetch("branches") == ["main"]
raise "pull_request trigger missing" unless events.fetch("pull_request").fetch("branches") == ["main"]
step = doc.fetch("jobs").fetch("unslop").fetch("steps").find { |item| item["name"] == "Find changed supported code" }
env = step.fetch("env")
raise "base ref does not support PR and push events" unless env.fetch("BASE_SHA").include?("pull_request.base.sha") && env.fetch("BASE_SHA").include?("github.event.before")
raise "head ref does not support PR and push events" unless env.fetch("HEAD_SHA").include?("pull_request.head.sha") && env.fetch("HEAD_SHA").include?("github.sha")
' "$WORKFLOW" || fail "Unslop event refs are not bounded to each push or pull request"
  pass "Unslop compares one push or pull request instead of repository history"
}

test_changed_code_ratchet() {
  local tmp repo runner_tmp fake_bin base head rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-unslop-workflow.XXXXXX")
  repo="$tmp/repo"
  runner_tmp="$tmp/runner"
  fake_bin="$tmp/bin"
  mkdir -p "$repo/src" "$runner_tmp" "$fake_bin"
  git -C "$repo" init -q
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  printf 'const marker = "SLOP-old";\n' >"$repo/src/demo.ts"
  printf '# baseline\n' >"$repo/README.md"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  base=$(git -C "$repo" rev-parse HEAD)

  printf 'const keep = true;\n' >>"$repo/src/demo.ts"
  printf '# changed\n' >>"$repo/README.md"
  git -C "$repo" add .
  git -C "$repo" commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)

  workflow_step "Find changed supported code" >"$tmp/find-changed.sh" \
    || { rm -rf "$tmp"; fail "could not read changed-code workflow step"; }
  (
    cd "$repo" || exit 1
    BASE_SHA="$base" HEAD_SHA="$head" RUNNER_TEMP="$runner_tmp" GITHUB_OUTPUT="$tmp/github-output" \
      bash "$tmp/find-changed.sh"
  ) >"$tmp/find.out" 2>"$tmp/find.err" \
    || { rm -rf "$tmp"; fail "changed-code selection failed"; }
  [ "$(tr '\0' '\n' <"$runner_tmp/unslop-files")" = "./src/demo.ts" ] \
    || { rm -rf "$tmp"; fail "Unslop did not limit its scan to changed supported code"; }

  cat >"$fake_bin/unslop" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys

findings = []
for path in sys.argv[3:]:
    with open(path, encoding="utf-8") as source:
        for marker in re.findall(r"SLOP-[A-Za-z0-9_-]+", source.read()):
            findings.append({
                "ruleId": "fixture-rule",
                "message": f"Fixture finding {marker}",
                "severity": "error",
                "gateable": True,
                "locations": [{"file": os.path.abspath(path)}],
            })
json.dump(findings, sys.stdout)
PY
  chmod +x "$fake_bin/unslop"
  workflow_step "Report findings and gate newly introduced slop" >"$tmp/gate.sh" \
    || { rm -rf "$tmp"; fail "could not read Unslop gate workflow step"; }

  set +e
  (
    cd "$repo" || exit 1
    PATH="$fake_bin:$PATH" BASE_SHA="$base" HEAD_SHA="$head" \
      RUNNER_TEMP="$runner_tmp" GITHUB_WORKSPACE="$repo" bash "$tmp/gate.sh"
  ) >"$tmp/preexisting.out" 2>"$tmp/preexisting.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || { rm -rf "$tmp"; fail "a pre-existing finding failed the ratchet"; }

  printf 'const added = "SLOP-new";\n' >>"$repo/src/demo.ts"
  git -C "$repo" add src/demo.ts
  git -C "$repo" commit -qm new-finding
  head=$(git -C "$repo" rev-parse HEAD)
  set +e
  (
    cd "$repo" || exit 1
    PATH="$fake_bin:$PATH" BASE_SHA="$base" HEAD_SHA="$head" \
      RUNNER_TEMP="$runner_tmp" GITHUB_WORKSPACE="$repo" bash "$tmp/gate.sh"
  ) >"$tmp/new.out" 2>"$tmp/new.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] \
    || { rm -rf "$tmp"; fail "a newly introduced finding did not fail the ratchet"; }

  rm -rf "$tmp"
  pass "Unslop ignores existing findings and fails on a new changed-code finding"
}

test_push_and_pull_request_refs_are_bounded
test_changed_code_ratchet
