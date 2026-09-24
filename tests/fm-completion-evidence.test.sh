#!/usr/bin/env bash
# Tests for bin/fm-evidence.sh: an independent verifier runs a task's approved
# acceptance command on the exact reviewed revision, the run is recorded in the
# home, and the task's committed completion claim resolves to that run and the
# verifier's judgement (fleet evidence E1: AC3, AC6, AC7).
#
# Each case builds a fixture firstmate home and a scratch project. The project's
# acceptance test, test/value.mjs, feeds fixture input 7 to src/value.mjs and
# requires 14. The default branch holds a constant-zero program; the author's
# lane (task t1, worktree wt-t1) commits the repair as the reviewed revision C.
# The independent verifier is task v1, a separate recorded task with its own
# worktree (wt-v1). Every fm-evidence.sh call runs from the directory of the
# actor making it: firstmate from the case directory, which is no task's
# worktree, and each task from its own worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

EV="$ROOT/bin/fm-evidence.sh"
TMP_ROOT=$(fm_test_tmproot fm-completion-evidence-tests)
command -v node >/dev/null 2>&1 || fail "node is required: the fixture's acceptance command is a node script"

# fixture <case>: a home, a project on main at base B, the author's lane with the
# reviewed repair C, and the verifier's worktree. Sets D H PJ AW VW B C.
fixture() {
  D="$TMP_ROOT/$1"
  H="$D/home"
  PJ="$D/proj"
  AW="$D/wt-t1"
  VW="$D/wt-v1"
  mkdir -p "$H/state" "$H/data" "$PJ/src" "$PJ/test" "$PJ/docs/specs"
  git -C "$PJ" init -q
  printf 'export const value = () => 0\n' > "$PJ/src/value.mjs"
  cat > "$PJ/test/value.mjs" <<'JS'
import { existsSync, readFileSync } from 'node:fs'
import { value } from '../src/value.mjs'
const skip = process.env.SKIP_TESTS === '1' || (existsSync('.env') && /SKIP_TESTS=1/.test(readFileSync('.env', 'utf8')))
if (skip) { console.log('skipped'); process.exit(0) }
const v = value(7)
console.log(`value=${v}`)
if (v !== 14) { console.error(`expected 14, got ${v}`); process.exit(1) }
JS
  cat > "$PJ/test/rewrite.mjs" <<'JS'
import { writeFileSync } from 'node:fs'
writeFileSync('README.md', 'rewritten by the runner\n')
console.log('value=14')
JS
  printf '# proj\n' > "$PJ/README.md"
  printf '# S1\n\nAC1 requires value 14 for input 7.\n' > "$PJ/docs/specs/s1.md"
  printf '# S2\n\nAC1 is a different criterion.\n' > "$PJ/docs/specs/s2.md"
  git -C "$PJ" add -A
  git -C "$PJ" commit -qm base
  git -C "$PJ" branch -M main
  B=$(git -C "$PJ" rev-parse HEAD)
  git -C "$PJ" worktree add -q -b fm/t1 "$AW"
  printf 'export const value = (x) => x * 2\n' > "$AW/src/value.mjs"
  git -C "$AW" commit -qam 'fix: double the input'
  C=$(git -C "$AW" rev-parse HEAD)
  git -C "$PJ" worktree add -q --detach "$VW" main
  fm_write_meta "$H/state/t1.meta" "project=$PJ" "worktree=$AW" kind=ship mode=local-only
  fm_write_meta "$H/state/v1.meta" "project=$PJ" "worktree=$VW" kind=scout
}

# ev <dir> <args>...: run fm-evidence.sh as the actor whose directory is <dir>.
ev() {
  local dir=$1
  shift
  (cd "$dir" && FM_HOME="$H" "$EV" "$@")
}

# approve [argv]...: firstmate approves command k1 for AC1 of docs/specs/s1.md,
# verified by v1. The argv defaults to the fixture's acceptance test.
approve() {
  [ "$#" -gt 0 ] || set -- node test/value.mjs
  ev "$D" assign t1 --verifier v1 --command-id k1 --spec docs/specs/s1.md --ac AC1 --timeout "${TIMEOUT:-30}" \
    --max-output "${MAXOUT:-1048576}" -- "$@" > /dev/null \
    || fail "$D: firstmate could not approve the acceptance command"
}

# capture <dir> <revision>: capture k1 as the actor in <dir>; echoes the run id.
capture() {
  local out
  out=$(ev "$1" capture t1 --command-id k1 --revision "$2") || fail "$D: capture from $1 failed: $out"
  printf '%s\n' "$out" | awk '$1 == "run" { print $2 }'
}

# judge <run> [base] [verdict]: v1 records its verdict on <run>; echoes the judge id.
judge() {
  local out
  out=$(ev "$VW" judge t1 --run "$1" --base "${2:-$B}" --verdict "${3:-supported}") || fail "$D: judge failed: $out"
  printf '%s\n' "$out" | awk '$1 == "judge" { print $2 }'
}

# attach <run>:<judge>...: the author renders the evidence into its lane.
attach() {
  ev "$AW" attach t1 "$@" > "$D/attach.out" 2>&1 || fail "$D: attach failed: $(cat "$D/attach.out")"
}

# edit_manifest <jq filter>: the author hand-edits its committed manifest.
edit_manifest() {
  local m="$AW/docs/proof/t1.evidence.json"
  jq "$1" "$m" > "$m.new" && mv "$m.new" "$m"
}

# commit_proof: the author writes the proof that names the manifest and commits
# the proof, the manifest and the output files on top of the lane.
commit_proof() {
  printf -- '---\nissue: t1\nspec: docs/specs/s1.md\nevidence: docs/proof/t1.evidence.json\n---\n\nAC1 is proved by the attached run.\n' > "$AW/docs/proof/t1.md"
  git -C "$AW" add docs/proof
  git -C "$AW" commit -qm 'docs(proof): attach the evidence'
}

# verify: firstmate resolves t1's claim; sets RC and OUT.
verify() {
  OUT=$(ev "$D" verify t1 2>&1)
  RC=$?
}

# full_pass: approve, capture from the verifier on C, judge, attach, commit.
full_pass() {
  approve
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

expect_refused() {  # <label> <text the refusal must name>
  expect_code 1 "$RC" "$1: completion should be refused"
  assert_contains "$OUT" "refused:" "$1: verify did not say refused"
  assert_contains "$OUT" "$2" "$1: refusal did not name the reason"
  assert_not_contains "$OUT" "verified:" "$1: a refused claim read as verified"
}

# --- AC3: an independent execution on the exact reviewed revision -----------

# AC3
test_ac3_independent_run_on_the_reviewed_revision_is_verified() {
  fixture ac3-ok
  full_pass
  assert_contains "$(cat "$AW/docs/proof/t1.evidence/$R.stdout")" "value=14" "ac3-ok: the captured output is not the program's"
  verify
  expect_code 0 "$RC" "ac3-ok: an independent passing run should verify: $OUT"
  assert_contains "$OUT" "verified: t1" "ac3-ok: verify did not say verified"
  assert_contains "$OUT" "run $R by v1" "ac3-ok: the report did not name the independent executor"
  assert_contains "$OUT" "judged $J by v1" "ac3-ok: the report did not name the judge record"
  pass "AC3: an independent run of the approved command on the reviewed revision verifies"
}

# AC3
test_ac3_author_only_run_is_refused_even_with_a_forged_executor() {
  fixture ac3-author
  approve
  R=$(capture "$AW" "$C")
  J=$(judge "$R")
  attach "$R:$J"
  edit_manifest '.runs[0].executor = "v1"'
  commit_proof
  verify
  expect_refused ac3-author "executor: run $R was executed by t1"
  pass "AC3: the author's own run is refused, even when its manifest names the verifier"
}

# AC3
test_ac3_unapproved_command_and_author_approval_are_refused() {
  local out rc
  fixture ac3-unapproved
  approve
  out=$(ev "$VW" capture t1 --command-id k2 --revision "$C" 2>&1); rc=$?
  expect_code 1 "$rc" "ac3-unapproved: capturing an unapproved command should be refused"
  assert_contains "$out" "k2 is not an approved command" "ac3-unapproved: refusal did not name the command"
  [ ! -d "$H/data/t1/evidence/runs" ] || [ -z "$(ls "$H/data/t1/evidence/runs")" ] \
    || fail "ac3-unapproved: a refused capture left a run record"
  out=$(ev "$AW" assign t1 --verifier v1 --command-id k1 --spec docs/specs/s1.md --ac AC1 -- node -e 'console.log("value=14")' 2>&1); rc=$?
  expect_code 2 "$rc" "ac3-unapproved: the author approving its own grading command should be refused"
  assert_contains "$out" "only firstmate approves" "ac3-unapproved: refusal did not say who approves"
  out=$(ev "$D" assign t1 --verifier t1 --command-id k1 --spec docs/specs/s1.md --ac AC1 -- node test/value.mjs 2>&1); rc=$?
  expect_code 2 "$rc" "ac3-unapproved: the author as its own verifier should be refused"
  fm_write_meta "$H/state/t9.meta" "project=$PJ" "worktree=$AW" kind=ship mode=local-only
  out=$(ev "$AW" assign t1 --verifier v1 --command-id k1 --spec docs/specs/s1.md --ac AC1 -- node test/value.mjs 2>&1); rc=$?
  expect_code 2 "$rc" "ac3-unapproved: an actor that two tasks claim must not read as firstmate"
  assert_contains "$out" "more than one recorded task claims" "ac3-unapproved: refusal did not name the ambiguity"
  pass "AC3: an unapproved command, an author-chosen command, a self-verifier and an ambiguous actor are refused"
}

# AC3
test_ac3_run_on_another_revision_is_refused() {
  local c2
  fixture ac3-rev
  approve
  printf 'export const extra = 1\n' > "$AW/src/extra.mjs"
  git -C "$AW" add src/extra.mjs
  git -C "$AW" commit -qm 'feat: extra'
  c2=$(git -C "$AW" rev-parse HEAD)
  git -C "$AW" reset -q --hard "$C"
  R=$(capture "$VW" "$c2")
  J=$(judge "$R")
  attach "$R:$J"
  edit_manifest ".reviewed = \"$C\""
  commit_proof
  verify
  expect_refused ac3-rev "revision: run $R ran on $c2, not the reviewed revision $C"
  pass "AC3: a run on another revision, even a descendant, is refused"
}

# AC3
test_ac3_author_environment_never_reaches_the_run() {
  fixture ac3-env
  approve
  printf 'SKIP_TESTS=1\n' > "$AW/.env"
  printf 'SKIP_TESTS=1\n' > "$VW/.env"
  R=$(SKIP_TESTS=1 capture "$VW" "$C")
  [ "$(cat "$H/data/t1/evidence/runs/$R/stdout")" = "value=14" ] \
    || fail "ac3-env: SKIP_TESTS or a .env reached the run: $(cat "$H/data/t1/evidence/runs/$R/stdout")"
  assert_not_contains "$(jq -c .env "$H/data/t1/evidence/runs/$R/record.json")" SKIP_TESTS "ac3-env: the run record kept an inherited variable"
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_code 0 "$RC" "ac3-env: the clean run should verify: $OUT"
  pass "AC3: SKIP_TESTS=1 and a .env that skips tests cannot turn the independent run into a skip"
}

# AC3
test_ac3_failed_run_is_refused() {
  local c3
  fixture ac3-exit1
  approve
  printf 'export const value = (x) => x * 3\n' > "$AW/src/value.mjs"
  git -C "$AW" commit -qam 'fix: triple the input'
  c3=$(git -C "$AW" rev-parse HEAD)
  R=$(capture "$VW" "$c3")
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac3-exit1 "run: run $R exited 1"
  pass "AC3: a run that exits 1 is refused even when its judge says supported"
}

# AC3
test_ac3_unsupported_verdict_is_refused() {
  fixture ac3-verdict
  approve
  R=$(capture "$VW" "$C")
  J=$(judge "$R" "$B" unsupported)
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac3-verdict "judge: $J found AC1 unsupported"
  pass "AC3: a passing run the judge found unsupported is refused"
}

# AC3
test_ac3_interrupted_run_is_refused() {
  local pid rec i=0
  fixture ac3-null
  approve node -e 'setTimeout(() => {}, 3000)'
  (cd "$VW" && FM_HOME="$H" exec "$EV" capture t1 --command-id k1 --revision "$C" > "$D/capture.out" 2>&1) &
  pid=$!
  rec="$H/data/t1/evidence/runs/t1-r1/record.json"
  while [ ! -s "$rec" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$rec" ] || fail "ac3-null: capture never wrote its started record"
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ "$(jq -r .exit "$rec")" = null ] || fail "ac3-null: an interrupted run recorded an exit: $(cat "$rec")"
  J=$(judge t1-r1)
  attach "t1-r1:$J"
  commit_proof
  verify
  expect_refused ac3-null "run: run t1-r1 did not finish"
  pass "AC3: an interrupted run with no exit is refused"
}

# AC3
test_ac3_timed_out_run_is_refused() {
  fixture ac3-timeout
  TIMEOUT=1 approve node -e 'setTimeout(() => {}, 20000)'
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac3-timeout "run: run $R timed out after 1s"
  pass "AC3: a run that hits its declared timeout is refused"
}

# AC3
test_ac3_run_killed_by_a_signal_is_refused() {
  fixture ac3-signal
  approve node -e 'process.kill(process.pid, "SIGKILL")'
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac3-signal "run: run $R exited 137"
  pass "AC3: a run killed by a signal is refused, not read as exit 0"
}

# AC3
test_ac3_output_over_its_bound_is_refused() {
  fixture ac3-bound
  MAXOUT=4 approve
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac3-bound "run: run $R wrote more than 4 bytes of output"
  pass "AC3: a run whose output exceeds its declared bound is refused"
}

# AC3
test_ac3_run_that_rewrites_a_tracked_file_is_refused() {
  fixture ac3-rewrite
  approve node test/rewrite.mjs
  R=$(capture "$VW" "$C")
  [ "$(cat "$AW/README.md")" = "# proj" ] || fail "ac3-rewrite: the run touched the author's worktree"
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac3-rewrite "run: run $R changed tracked files: README.md"
  pass "AC3: a runner that rewrites a tracked file is refused"
}

# AC3
test_ac3_every_approved_command_needs_a_claim() {
  fixture ac3-missing
  full_pass
  ev "$D" assign t1 --verifier v1 --command-id k2 --spec docs/specs/s1.md --ac AC2 -- node test/value.mjs > /dev/null \
    || fail "ac3-missing: firstmate could not approve a second command"
  verify
  expect_refused ac3-missing "claim: no supported claim for approved command k2 (AC2"
  pass "AC3: an approved command with no independent run is refused"
}

# --- AC6: the report renders the run record, and evidence bytes must match --

# AC6
test_ac6_report_renders_the_run_record() {
  local sha
  fixture ac6-report
  full_pass
  verify
  expect_code 0 "$RC" "ac6-report: should verify: $OUT"
  sha=$(sha256_of "$H/data/t1/evidence/runs/$R/stdout")
  assert_contains "$OUT" "Ran: node test/value.mjs" "ac6-report: no Ran line"
  assert_contains "$OUT" "Revision: $C" "ac6-report: no Revision line"
  assert_contains "$OUT" "Exit: 0" "ac6-report: no Exit line"
  assert_contains "$OUT" "Observed: stdout docs/proof/t1.evidence/$R.stdout (9 bytes, sha256 $sha)" "ac6-report: no Observed line for stdout"
  pass "AC6: the completion report renders Ran, Revision, Exit and Observed from the run record"
}

# AC6
test_ac6_absent_or_altered_evidence_bytes_are_refused() {
  local good native
  fixture ac6-bytes
  full_pass
  good=$(git -C "$AW" rev-parse HEAD)
  native="$H/data/t1/evidence/runs/$R/stdout"

  mv "$native" "$native.kept"
  verify
  expect_refused ac6-bytes-native "output: the captured stdout of $R is missing"
  mv "$native.kept" "$native"

  printf 'PASS\n' > "$AW/docs/proof/t1.evidence/$R.stdout"
  git -C "$AW" commit -qam 'docs(proof): a hand-written pass line'
  verify
  expect_refused ac6-bytes-handwritten "output: committed stdout docs/proof/t1.evidence/$R.stdout does not match the captured output"
  git -C "$AW" reset -q --hard "$good"

  git -C "$AW" rm -q "docs/proof/t1.evidence/$R.stdout"
  git -C "$AW" commit -qm 'docs(proof): drop the output'
  verify
  expect_refused ac6-bytes-removed "output: committed stdout docs/proof/t1.evidence/$R.stdout is not in the candidate"
  git -C "$AW" reset -q --hard "$good"

  edit_manifest ".runs[0].stdout.sha256 = \"$(printf '0%.0s' $(seq 64))\""
  git -C "$AW" commit -qam 'docs(proof): alter the digest'
  verify
  expect_refused ac6-bytes-digest "output: the manifest's stdout digest for $R differs from the run record"
  git -C "$AW" reset -q --hard "$good"

  verify
  expect_code 0 "$RC" "ac6-bytes: the restored candidate should verify again: $OUT"
  pass "AC6: missing, hand-written, removed or re-digested output is refused"
}

# AC6
test_ac6_unrelated_receipt_is_refused() {
  local other r2
  fixture ac6-receipt
  full_pass
  other="$D/wt-t2"
  git -C "$PJ" worktree add -q -b fm/t2 "$other" "$C"
  fm_write_meta "$H/state/t2.meta" "project=$PJ" "worktree=$other" kind=ship mode=local-only
  ev "$D" assign t2 --verifier v1 --command-id k1 --spec docs/specs/s1.md --ac AC1 -- node test/value.mjs > /dev/null \
    || fail "ac6-receipt: could not approve t2's command"
  r2=$(ev "$VW" capture t2 --command-id k1 --revision "$C" | awk '$1 == "run" { print $2 }')
  [ -n "$r2" ] || fail "ac6-receipt: t2's run was not recorded"
  edit_manifest ".claims[0].run = \"$r2\" | .runs[0].id = \"$r2\""
  git -C "$AW" commit -qam 'docs(proof): cite another task run'
  verify
  expect_refused ac6-receipt "run: unknown run $r2 for t1"
  pass "AC6: a receipt from another task is refused"
}

# AC6
test_ac6_empty_output_needs_zero_length_artifacts() {
  fixture ac6-empty
  approve node -e ''
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  attach "$R:$J"
  [ -f "$AW/docs/proof/t1.evidence/$R.stdout" ] && [ ! -s "$AW/docs/proof/t1.evidence/$R.stdout" ] \
    || fail "ac6-empty: attach did not write a zero-length stdout artifact"
  commit_proof
  verify
  expect_code 0 "$RC" "ac6-empty: genuinely empty output with zero-length artifacts should verify: $OUT"
  git -C "$AW" rm -q "docs/proof/t1.evidence/$R.stderr"
  git -C "$AW" commit -qm 'docs(proof): drop the empty stderr'
  verify
  expect_refused ac6-empty "output: committed stderr docs/proof/t1.evidence/$R.stderr is not in the candidate"
  pass "AC6: empty output verifies only with its captured zero-length artifacts"
}

# --- AC7: a claim resolves to the same task, spec, criterion, revision, judge -

# AC7
test_ac7_proof_only_commits_after_the_review_pass() {
  fixture ac7-proof
  full_pass
  printf '\nA repaired sentence.\n' >> "$AW/docs/proof/t1.md"
  git -C "$AW" commit -qam 'docs(proof): repair the prose'
  verify
  expect_code 0 "$RC" "ac7-proof: proof-only commits after C should verify: $OUT"
  assert_contains "$OUT" "reviewed $C" "ac7-proof: the result did not name C"
  assert_contains "$OUT" "run $R" "ac7-proof: the result did not name the run"
  assert_contains "$OUT" "judged $J" "ac7-proof: the result did not name the judge"
  pass "AC7: the claim resolves through proof-only commits after the reviewed revision"
}

# AC7
test_ac7_code_after_the_reviewed_revision_is_refused() {
  fixture ac7-code
  approve
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  printf 'export const value = () => 0\n' > "$AW/src/value.mjs"
  git -C "$AW" commit -qam 'refactor: a later code change'
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac7-code "candidate: src/value.mjs changed after the reviewed revision $C"
  pass "AC7: code changed after the reviewed revision invalidates its evidence"
}

# AC7
test_ac7_old_run_after_a_rebase_is_refused() {
  local rebased
  fixture ac7-rebase
  approve
  R=$(capture "$VW" "$C")
  J=$(judge "$R")
  git -C "$AW" commit -q --amend -m 'fix: double the input (rebased)'
  rebased=$(git -C "$AW" rev-parse HEAD)
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac7-rebase-old "candidate: the reviewed revision $C is not an ancestor of the candidate"
  edit_manifest ".reviewed = \"$rebased\""
  git -C "$AW" commit -qam 'docs(proof): claim the rebased commit'
  verify
  expect_refused ac7-rebase-new "revision: run $R ran on $C, not the reviewed revision $rebased"
  git -C "$AW" reset -q --hard "$rebased"
  git -C "$AW" clean -qfd docs/proof
  R=$(capture "$VW" "$rebased")
  [ "$R" = t1-r2 ] || fail "ac7-rebase: the fresh run did not get the next id (got $R)"
  J=$(judge "$R")
  attach "$R:$J"
  commit_proof
  verify
  expect_code 0 "$RC" "ac7-rebase: fresh evidence on the rebased commit should verify: $OUT"
  pass "AC7: a run from before a rebase cannot vouch for the rebased commit, and a fresh run can"
}

# AC7
test_ac7_mismatched_bindings_are_refused() {
  local good
  fixture ac7-bind
  full_pass
  good=$(git -C "$AW" rev-parse HEAD)
  try_binding() {  # <label> <jq filter> <reason>
    edit_manifest "$2"
    git -C "$AW" commit -qam "docs(proof): $1"
    verify
    expect_refused "ac7-bind-$1" "$3"
    git -C "$AW" reset -q --hard "$good"
  }
  try_binding missing-judge '.claims[0].judge = ""' "judge: the claim for AC1 names no judge"
  try_binding forged-run '.claims[0].run = "t1-r99"' "run: unknown run t1-r99 for t1"
  try_binding task '.task = "t2"' "task: the manifest is for t2, not t1"
  try_binding spec '.claims[0].spec = "docs/specs/s2.md"' "spec: the claim names docs/specs/s2.md AC1, the run proved docs/specs/s1.md AC1"
  try_binding judge-digest '.judges[0].evidence.stdout_sha256 = "feed"' "judge: the manifest's entry for $J differs from the judge record"
  verify
  expect_code 0 "$RC" "ac7-bind: the untouched candidate should verify: $OUT"
  pass "AC7: a missing judge, a forged run id, another task, another spec and a substituted digest are refused"
}

# AC7
test_ac7_review_on_another_base_is_refused() {
  local b2
  fixture ac7-base
  printf 'more\n' >> "$PJ/README.md"
  git -C "$PJ" commit -qam 'docs: main moves on'
  b2=$(git -C "$PJ" rev-parse HEAD)
  approve
  R=$(capture "$VW" "$C")
  J=$(judge "$R" "$b2")
  attach "$R:$J"
  commit_proof
  verify
  expect_refused ac7-base-foreign "base: the review base $b2 is not an ancestor of the reviewed revision $C"
  edit_manifest ".base = \"$B\""
  git -C "$AW" commit -qam 'docs(proof): claim the lane base'
  verify
  expect_refused ac7-base-judge "base: $J reviewed against $b2, the claim says $B"
  pass "AC7: a review against another base is refused"
}

# AC7
test_ac7_changed_command_is_refused() {
  fixture ac7-command
  full_pass
  ev "$D" assign t1 --verifier v1 --command-id k1 --spec docs/specs/s1.md --ac AC1 -- node test/value.mjs --strict > /dev/null \
    || fail "ac7-command: could not re-approve k1"
  verify
  expect_refused ac7-command "command: k1 changed after run $R"
  pass "AC7: a run of a command whose approved form changed is refused"
}

test_ac3_independent_run_on_the_reviewed_revision_is_verified
test_ac3_author_only_run_is_refused_even_with_a_forged_executor
test_ac3_unapproved_command_and_author_approval_are_refused
test_ac3_run_on_another_revision_is_refused
test_ac3_author_environment_never_reaches_the_run
test_ac3_failed_run_is_refused
test_ac3_unsupported_verdict_is_refused
test_ac3_interrupted_run_is_refused
test_ac3_timed_out_run_is_refused
test_ac3_run_killed_by_a_signal_is_refused
test_ac3_output_over_its_bound_is_refused
test_ac3_run_that_rewrites_a_tracked_file_is_refused
test_ac3_every_approved_command_needs_a_claim
test_ac6_report_renders_the_run_record
test_ac6_absent_or_altered_evidence_bytes_are_refused
test_ac6_unrelated_receipt_is_refused
test_ac6_empty_output_needs_zero_length_artifacts
test_ac7_proof_only_commits_after_the_review_pass
test_ac7_code_after_the_reviewed_revision_is_refused
test_ac7_old_run_after_a_rebase_is_refused
test_ac7_mismatched_bindings_are_refused
test_ac7_review_on_another_base_is_refused
test_ac7_changed_command_is_refused
