#!/usr/bin/env bash
# End-to-end simulation of .github/workflows/unslop.yml:
# extracts the real `run` scripts from the workflow YAML and executes them
# against a scratch git repo, with the pinned analyzers on PATH.
set -euo pipefail

TMP="$1"       # scratch root (analyzers already installed under $TMP/tools)
WT="$2"        # project worktree (source of the workflow YAML)
export PATH="$TMP/tools/node_modules/.bin:$PATH"

# --- extract the two run scripts from the workflow (head + base versions) ---
git -C "$WT" show dc48fe5:.github/workflows/unslop.yml > "$TMP/unslop-head.yml"
git -C "$WT" show 63ca758:.github/workflows/unslop.yml > "$TMP/unslop-base.yml"
python3 - "$TMP" <<'PY'
import yaml, sys
tmp = sys.argv[1]
for tag, path in (("new", tmp+"/unslop-head.yml"), ("old", tmp+"/unslop-base.yml")):
    wf = yaml.safe_load(open(path))
    steps = wf["jobs"]["unslop"]["steps"]
    changed = next(s for s in steps if s.get("id") == "changed")
    gate = next(s for s in steps if s.get("name", "").startswith("Report findings"))
    open(f"{tmp}/step-changed-{tag}.sh", "w").write(changed["run"])
    open(f"{tmp}/step-gate-{tag}.sh", "w").write(gate["run"])
print("extracted run scripts")
PY

# --- scratch repo with pre-existing slop at the base commit ---
REPO="$TMP/repo"
rm -rf "$REPO"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "gate-test"

mkdir -p lib
cat > lib/orders.js <<'EOF'
export function formatOrderSummary(order, options) {
  const lines = [];
  const currency = options && options.currency ? options.currency : "$";
  lines.push(`Order ${order.id} for ${order.customer.name}`);
  for (const item of order.items) {
    const price = (item.cents / 100).toFixed(2);
    if (item.qty > 1) {
      lines.push(`${item.qty} x ${item.name} @ ${currency}${price}`);
    } else {
      lines.push(`${item.name} ${currency}${price}`);
    }
  }
  const totalCents = order.items.reduce((sum, item) => sum + item.cents * item.qty, 0);
  const total = (totalCents / 100).toFixed(2);
  lines.push(`Total: ${currency}${total}`);
  if (order.coupon) {
    lines.push(`Coupon applied: ${order.coupon.code} (-${order.coupon.percent}%)`);
  }
  if (order.notes && order.notes.length > 0) {
    lines.push(`Notes: ${order.notes.join("; ")}`);
  }
  return lines.join("\n");
}
EOF
# pre-existing slop: invoices.js is an exact clone of orders.js
cp lib/orders.js lib/invoices.js
cat > lib/clean.js <<'EOF'
export function double(n) {
  return n * 2;
}
EOF
echo "# scratch" > README.md
git add -A
git commit -qm "base with pre-existing exact-clone slop"
BASE=$(git rev-parse HEAD)

# --- scenario branches ---
# 1. rename: move orders.js and touch its clone partner; no new slop
git checkout -qB sc-rename "$BASE"
mkdir -p src
git mv lib/orders.js src/orders.js
printf '\n// touched by this PR\n' >> lib/invoices.js
git add -A
git commit -qm "rename orders.js, touch invoices.js"
HEAD_RENAME=$(git rev-parse HEAD)

# 2. preexisting: touch both clone halves in place; no rename, no new slop
git checkout -qB sc-preexisting "$BASE"
printf '\n// touched a\n' >> lib/orders.js
printf '\n// touched b\n' >> lib/invoices.js
git add -A
git commit -qm "touch files that already carry slop"
HEAD_PREEXISTING=$(git rev-parse HEAD)

# 3. newslop: add a brand-new clone pair
git checkout -qB sc-newslop "$BASE"
cp lib/orders.js lib/copy_one.js
cp lib/orders.js lib/copy_two.js
git add -A
git commit -qm "introduce new duplicated code"
HEAD_NEWSLOP=$(git rev-parse HEAD)

# 4. nocode: only a markdown change
git checkout -qB sc-nocode "$BASE"
echo "docs only" >> README.md
git add -A
git commit -qm "docs only"
HEAD_NOCODE=$(git rev-parse HEAD)

run_pipeline() {
  local tag="$1" head="$2" want_gate_rc="$3" extra_path="${4:-}"
  local rt gh_out rc
  rt=$(mktemp -d "$TMP/runner-$tag.XXXX")
  gh_out="$rt/gh-output"; : > "$gh_out"
  git -C "$REPO" checkout -q "$head"
  echo "=================================================================="
  echo "SCENARIO $tag (BASE=${BASE:0:9} HEAD=${head:0:9})"
  echo "=================================================================="
  (
    cd "$REPO"
    export RUNNER_TEMP="$rt" GITHUB_OUTPUT="$gh_out" GITHUB_WORKSPACE="$REPO"
    export BASE_SHA="$BASE" HEAD_SHA="$head"
    [ -n "$extra_path" ] && export PATH="$extra_path:$PATH"
    bash "$TMP/step-changed-${5:-new}.sh"
  )
  if grep -q '^has_code=true$' "$gh_out"; then
    rc=0
    (
      cd "$REPO"
      export RUNNER_TEMP="$rt" GITHUB_OUTPUT="$gh_out" GITHUB_WORKSPACE="$REPO"
      export BASE_SHA="$BASE" HEAD_SHA="$head"
      [ -n "$extra_path" ] && export PATH="$extra_path:$PATH"
      bash "$TMP/step-gate-${5:-new}.sh"
    ) || rc=$?
    echo "-- gate step exit code: $rc (expected $want_gate_rc)"
  else
    rc="skipped"
    echo "-- gate step skipped: has_code=false (expected $want_gate_rc)"
  fi
  if [ "$rc" = "$want_gate_rc" ]; then
    echo "SCENARIO $tag: OK"
  else
    echo "SCENARIO $tag: MISMATCH (got $rc, want $want_gate_rc)"
    exit 1
  fi
}

# fake analyzer that always crashes, for the non-blocking failure scenario
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "unslop: simulated crash" >&2\nexit 3\n' > "$FAKEBIN/unslop"
chmod +x "$FAKEBIN/unslop"

run_pipeline rename        "$HEAD_RENAME"      0
run_pipeline preexisting   "$HEAD_PREEXISTING" 0
run_pipeline newslop       "$HEAD_NEWSLOP"     1
run_pipeline nocode        "$HEAD_NOCODE"      skipped
run_pipeline analyzer-fail "$HEAD_RENAME"      0 "$FAKEBIN"

# regression proof: the OLD gate script (base commit) wrongly fails the rename
echo "=================================================================="
echo "REGRESSION CHECK: old gate script on the rename scenario"
echo "=================================================================="
run_pipeline rename-oldscript "$HEAD_RENAME" 1 "" old

echo "ALL SCENARIOS PASSED"
