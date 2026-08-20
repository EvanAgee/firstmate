#!/usr/bin/env bash
# Dedupe-key stability: the clone's start line shifts between base and head,
# so the finding message's <name@path:line> reference differs. The new gsub
# must keep the key stable; the old script (no gsub) must false-positive.
set -euo pipefail
TMP="$1"
export PATH="$TMP/tools/node_modules/.bin:$PATH"
REPO="$TMP/repo"
cd "$REPO"
BASE=$(git rev-parse sc-rename~1)

git checkout -qB sc-lineshift "$BASE"
# push the clone in orders.js down two lines; touch invoices.js so both
# clone halves are in the changed set
printf '// prologue line one\n// prologue line two\n' | cat - lib/orders.js > lib/orders.tmp
mv lib/orders.tmp lib/orders.js
printf '\n// touched\n' >> lib/invoices.js
git add -A
git commit -qm "shift clone start line"
HEAD=$(git rev-parse HEAD)

run_one() {
  local tag="$1" want="$2"
  local rt gh_out rc
  rt=$(mktemp -d "$TMP/runner-lineshift-$tag.XXXX")
  gh_out="$rt/gh-output"; : > "$gh_out"
  echo "=================================================================="
  echo "LINESHIFT with $tag gate script (BASE=${BASE:0:9} HEAD=${HEAD:0:9})"
  echo "=================================================================="
  (
    cd "$REPO"
    export RUNNER_TEMP="$rt" GITHUB_OUTPUT="$gh_out" GITHUB_WORKSPACE="$REPO"
    export BASE_SHA="$BASE" HEAD_SHA="$HEAD"
    bash "$TMP/step-changed-$tag.sh"
  )
  rc=0
  (
    cd "$REPO"
    export RUNNER_TEMP="$rt" GITHUB_OUTPUT="$gh_out" GITHUB_WORKSPACE="$REPO"
    export BASE_SHA="$BASE" HEAD_SHA="$HEAD"
    bash "$TMP/step-gate-$tag.sh"
  ) || rc=$?
  echo "-- $tag gate exit code: $rc (expected $want)"
  [ "$rc" = "$want" ] || { echo "LINESHIFT $tag: MISMATCH"; exit 1; }
  echo "LINESHIFT $tag: OK"
}

run_one new 0
run_one old 1
echo "LINESHIFT SCENARIOS PASSED"
