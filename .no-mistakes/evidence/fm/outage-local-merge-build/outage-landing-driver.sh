#!/usr/bin/env bash
# Evidence driver: exercises the REAL bin/fm-merge-local.sh and
# bin/fm-outage-sync.sh end-to-end against throwaway git repos and prints the
# reviewer-visible artifacts (refusal, ledger, fast-forward push, dispatched
# deferred workflows). Not a test; a demonstration.
set -u
ROOT=$1
MERGE="$ROOT/bin/fm-merge-local.sh"
SYNC="$ROOT/bin/fm-outage-sync.sh"
. "$ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
W=$(mktemp -d)
INERT=$(mktemp -d)   # inert non-git dir so the tangle guard stays silent

sha() { git -C "$1" rev-parse --short "$2"; }

mkproj_ff() {  # <dir> <lane>
  local proj=$1 lane=$2
  git -C "$proj" init -q
  git -C "$proj" commit -q --allow-empty -m init
  git -C "$proj" branch -M main
  git -C "$proj" checkout -q -b "$lane"
  git -C "$proj" commit -q --allow-empty -m "crewmate lane work"
  git -C "$proj" checkout -q main
}

echo "=================================================================="
echo " Part B - local landing + sync during a GitHub outage"
echo "=================================================================="
echo
echo "--- 1) GitHub is UP: a PR-bound task is REFUSED locally ---"
S="$W/up/state"; P="$W/up/proj"; mkdir -p "$S" "$P"
mkproj_ff "$P" ticket-1
fm_write_meta "$S/t1.meta" "project=$P" "mode=no-mistakes" "yolo=on"
set +e
FM_ROOT_OVERRIDE="$INERT" FM_STATE_OVERRIDE="$S" "$MERGE" t1 ticket-1 >"$W/up/out" 2>"$W/up/err"
rc=$?; set -e
echo "exit=$rc  (non-zero = refused)"
echo "message: $(grep -o 'lands locally only while GitHub is unreachable.*' "$W/up/err" | head -1)"
echo "points to normal flow: $(grep -o 'fm-pr-merge.sh' "$W/up/err" | head -1)"
echo "main moved? $(git -C "$P" merge-base --is-ancestor ticket-1 main 2>/dev/null && echo YES || echo 'no (untouched)')"
echo

echo "--- 2) GitHub is DOWN: yolo=on auto-land REFUSED without adversarial review ---"
S="$W/noreview/state"; P="$W/noreview/proj"; mkdir -p "$S" "$P"
mkproj_ff "$P" ticket-9
wt="$W/noreview/wt"; git -C "$P" worktree add -q "$wt" ticket-9
fm_write_meta "$S/t9.meta" "project=$P" "mode=no-mistakes" "yolo=on" "worktree=$wt"
touch "$S/.github-down"
b=$(git -C "$P" rev-parse main)
set +e
FM_ROOT_OVERRIDE="$INERT" FM_STATE_OVERRIDE="$S" "$MERGE" t9 >"$W/noreview/out" 2>"$W/noreview/err"
rc=$?; set -e
echo "exit=$rc  (non-zero = refused)"
echo "message: $(grep -o 'adversarial review.*' "$W/noreview/err" | head -1)"
echo "main unchanged? $( [ "$(git -C "$P" rev-parse main)" = "$b" ] && echo YES || echo NO )  (deterministic backstop: no auto-land on one review)"
echo

echo "--- 3) GitHub is DOWN: yolo=on auto-land ACCEPTED with review proof, ledger written ---"
S="$W/outage/state"; P="$W/outage/proj"; mkdir -p "$S" "$P"
mkproj_ff "$P" ticket-2
wt="$W/outage/wt"; git -C "$P" worktree add -q "$wt" ticket-2
fm_write_meta "$S/t2.meta" "project=$P" "mode=no-mistakes" "yolo=on" "worktree=$wt"
touch "$S/.github-down"
before=$(git -C "$P" rev-parse main)
FM_ROOT_OVERRIDE="$INERT" FM_STATE_OVERRIDE="$S" "$MERGE" t2 \
  --deferred-checks 'a11y.yml,smoke.yml' \
  --adversarial-review-passed 'report:data/adversarial-t2/report.md' \
  >"$W/outage/out" 2>"$W/outage/err" || { echo "FAILED: $(cat "$W/outage/err")"; }
after=$(git -C "$P" rev-parse main)
echo "main: $before  ->  $after   (fast-forwarded onto ticket-2)"
echo "lane on main now? $(git -C "$P" merge-base --is-ancestor ticket-2 main && echo YES)"
echo "ledger file: $S/outage-landings/proj.log"
echo "ledger line:"
sed 's/^/   /' "$S/outage-landings/proj.log"
echo
echo "  fields present: after-SHA=$(grep -c "$after" "$S/outage-landings/proj.log")  deferred-checks=$(grep -c 'a11y.yml,smoke.yml' "$S/outage-landings/proj.log")  review-proof=$(grep -c 'report:data/adversarial-t2/report.md' "$S/outage-landings/proj.log")"
echo

echo "--- 4) diverged branch ESCALATES, never force-pushes ---"
S="$W/div/state"; P="$W/div/proj"; O="$W/div/origin.git"; mkdir -p "$S" "$W/div"
git init -q --bare "$O"; git -C "$O" symbolic-ref HEAD refs/heads/main
git init -q "$P"; git -C "$P" commit -q --allow-empty -m init; git -C "$P" branch -M main
git -C "$P" remote add origin "$O"; git -C "$P" push -q -u origin main >/dev/null 2>&1
git -C "$P" commit -q --allow-empty -m "outage landing"
after=$(git -C "$P" rev-parse main)
# someone else advanced origin/main during the outage -> divergence
other="$W/div/other"; git clone -q "$O" "$other"; git -C "$other" checkout -q -B main
git -C "$other" commit -q --allow-empty -m "someone else pushed during outage"
git -C "$other" push -q origin main
origin_before=$(git -C "$O" rev-parse main)
mkdir -p "$S/outage-landings"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 2026-01-01T00:00:00Z aos-1 "$P" main deadbeef "$after" '' > "$S/outage-landings/proj.log"
fake="$W/div/fakebin"; mkdir -p "$fake"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FM_TEST_GH_LOG"\nexit 0\n' > "$fake/gh-axi"; chmod +x "$fake/gh-axi"
: > "$W/div/gh.log"
set +e
FM_TEST_GH_LOG="$W/div/gh.log" FM_GH_BIN="$fake/gh-axi" FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$W/div" "$SYNC" >"$W/div/out" 2>"$W/div/err"
rc=$?; set -e
echo "exit=$rc  (non-zero = escalated)"
echo "message: $(grep -io 'diverg[a-z ]*' "$W/div/out" "$W/div/err" | head -1)"
echo "origin/main unchanged? $( [ "$(git -C "$O" rev-parse main)" = "$origin_before" ] && echo YES || echo NO )  (never force-pushed)"
echo "ledger entry kept for manual rebase? $( [ -s "$S/outage-landings/proj.log" ] && echo YES || echo no )"
echo

echo "--- 5) GitHub RETURNS: sync fast-forward-pushes, dispatches deferred workflows, clears ledger ---"
S="$W/sync/state"; P="$W/sync/proj"; O="$W/sync/origin.git"; mkdir -p "$S" "$W/sync"
git init -q --bare "$O"; git -C "$O" symbolic-ref HEAD refs/heads/main
git init -q "$P"; git -C "$P" commit -q --allow-empty -m init; git -C "$P" branch -M main
git -C "$P" remote add origin "$O"; git -C "$P" push -q -u origin main >/dev/null 2>&1
git -C "$P" commit -q --allow-empty -m "outage landing"
after=$(git -C "$P" rev-parse main)
origin_before=$(git -C "$O" rev-parse main)
mkdir -p "$S/outage-landings"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 2026-01-01T00:00:00Z aos-1 "$P" main deadbeef "$after" 'a11y.yml,smoke.yml' > "$S/outage-landings/proj.log"
fake="$W/sync/fakebin"; mkdir -p "$fake"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FM_TEST_GH_LOG"\nexit 0\n' > "$fake/gh-axi"; chmod +x "$fake/gh-axi"
: > "$W/sync/gh.log"
FM_TEST_GH_LOG="$W/sync/gh.log" FM_GH_BIN="$fake/gh-axi" FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$W/sync" "$SYNC" >"$W/sync/out" 2>"$W/sync/err" \
  || { echo "FAILED: $(cat "$W/sync/err")"; }
origin_after=$(git -C "$O" rev-parse main)
echo "origin/main: $origin_before  ->  $origin_after"
echo "pushed the outage landing? $( [ "$origin_after" = "$after" ] && echo YES || echo NO )   (plain fast-forward, no --force)"
echo "deferred workflows dispatched via gh-axi:"
sed 's/^/   gh-axi /' "$W/sync/gh.log"
echo "ledger cleared? $( [ ! -s "$S/outage-landings/proj.log" ] && echo YES || echo 'no' )"
echo
echo "--- 6) sync is idempotent: a re-run after success is a no-op ---"
: > "$W/sync/gh.log"
# rebuild the ledger entry (already-on-origin now) to prove the no-op path
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 2026-01-01T00:00:00Z aos-1 "$P" main deadbeef "$after" 'a11y.yml,smoke.yml' > "$S/outage-landings/proj.log"
FM_TEST_GH_LOG="$W/sync/gh.log" FM_GH_BIN="$fake/fakebin/gh-axi" FM_GH_BIN="$fake/gh-axi" FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$W/sync" "$SYNC" >"$W/sync/out2" 2>"$W/sync/err2" || true
echo "commit already on origin -> re-dispatched workflows? $( [ -s "$W/sync/gh.log" ] && echo 'YES (WRONG)' || echo 'no (no double-fire)' )"
echo "surfaced the undispatched deferred checks once? $(grep -io 'defer[a-z ]*' "$W/sync/out2" | head -1 | sed 's/$/ (noted)/')"
echo "ledger cleared? $( [ ! -s "$S/outage-landings/proj.log" ] && echo YES || echo no )"

rm -rf "$W" "$INERT"
