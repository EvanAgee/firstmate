#!/usr/bin/env bash
# fm-evidence.sh - record an independent run of a ship task's approved
# acceptance commands and resolve the task's completion claim to that run.
#
# A worker's done line is a notification, not evidence. Firstmate approves each
# acceptance command for a task and names its independent verifier, which is
# another recorded task with its own worktree. The verifier runs each command
# with `capture`, which executes it on one exact commit and records the command,
# the commit, the environment policy, the exit and the output in this home. The
# verifier records its verdict with `judge`. The author renders that evidence
# into its lane with `attach` and names the manifest in its proof, and `verify`
# resolves the committed claim against the records here and prints the
# completion report.
#
# The actor behind every call is the recorded task whose worktree
# (state/<id>.meta worktree=) holds the current directory, never an argument or
# a committed field. `assign` runs only outside every task worktree, so a worker
# cannot choose the command that grades it. Same-user files are not a security
# boundary against a hostile process; this records who ran what, it does not
# attest it.
#
# capture runs the approved argv, with no shell, in a scratch checkout of the
# exact commit's tree read from the task's repository, under a clean
# environment (PATH, a scratch HOME and TMPDIR only), with the approved timeout.
# Neither the caller's environment nor any untracked file (such as .env) in any
# worktree reaches the run. A run that times out, is interrupted, exceeds the
# output bound or changes a tracked file is recorded as such and never verifies.
#
# verify requires, for the task's committed candidate P (the HEAD of the task's
# recorded worktree), each of these, and names the field of any mismatch:
#   - docs/proof/<task>.md at P names the manifest in its front matter
#     (evidence: docs/proof/...), and the manifest is for this task;
#   - the reviewed revision C is P or an ancestor of P, and every change from C
#     to P adds or edits a regular file under docs/proof/ (exact identity, not
#     ancestry: code after C invalidates the evidence);
#   - the review base is an ancestor of C and is the base the judge reviewed;
#   - every approved command has a supported claim;
#   - each claim's run is a record of this task in this home, executed by the
#     assigned verifier (not the author) on exactly C, for the command still
#     approved in the same form, the same spec blob and criterion, and it exited
#     0 within its bounds without changing tracked files;
#   - the captured output bytes here, the manifest's digests and the committed
#     output files at P all agree, zero-length files included;
#   - each claim's judge is a record of this task by the verifier, on C, against
#     the claim's base, over the same output digests, with verdict supported.
# The manifest's copies of run and judge fields are compared with the records;
# a decision never rests on a committed field.
#
# This is the firstmate half of fleet evidence E1. Activation is off: nothing
# calls verify on a real landing yet. The committed binding format is specified
# in docs/proof/fleet-evidence-e1.md ("Binding contract"), the contract the
# public spec-lock checker will validate.
#
# Records live under data/<task>/evidence/: assignment.json,
# runs/<task>-r<n>/{record.json,stdout,stderr} and judges/<task>-j<n>.json. Only
# this script writes them.
#
# Usage:
#   fm-evidence.sh assign <task> --verifier <task> --command-id <id> --spec <path> --ac <AC<n>>
#                  [--timeout <seconds>] [--max-output <bytes>] -- <argv>...
#   fm-evidence.sh capture <task> --command-id <id> --revision <commit>
#   fm-evidence.sh judge <task> --run <run-id> --base <commit> --verdict supported|unsupported
#   fm-evidence.sh attach <task> <run-id>:<judge-id>...
#   fm-evidence.sh verify <task>
#
# Exit status: 0 done (verify: verified); 1 refused (verify: refused or
# unchecked); 2 usage error or a record that cannot be read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'refused: %s\n' "$1" >&2; exit 1; }

valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;; esac; }
is_oid() { printf '%s' "$1" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'; }
physical() { (cd "$1" 2>/dev/null && pwd -P); }
meta_get() { sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null | head -n 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-evidence.XXXXXX") || die "cannot make a scratch directory"
trap 'rm -rf "$SCRATCH"' EXIT

sha256_file() { fm_custom_check_sha256 "$1"; }
sha256_text() { printf '%s' "$1" > "$SCRATCH/text"; sha256_file "$SCRATCH/text"; }

# The recorded task whose worktree holds the current directory, or nothing.
# Fails when two tasks claim that worktree; callers exit on that failure.
caller() {
  local top meta wt found=
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(physical "$top")
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -n 1)
    [ -n "$wt" ] && [ "$(physical "$wt")" = "$top" ] || continue
    [ -z "$found" ] || die "more than one recorded task claims the worktree $top"
    found=$(basename "$meta" .meta)
  done
  printf '%s' "$found"
}

# load_task <task>: sets TASK EV WT PROJECT GD for a recorded task.
load_task() {
  TASK=$1
  valid_id "$TASK" || die "invalid task id '$TASK'"
  [ -f "$STATE/$TASK.meta" ] || die "no recorded task $TASK in $STATE"
  EV="$DATA/$TASK/evidence"
  WT=$(meta_get "$TASK" worktree)
  PROJECT=$(meta_get "$TASK" project)
  GD=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || die "cannot read $TASK's repository at $WT"
}

g() { git --git-dir="$GD" "$@"; }
commit_of() { g rev-parse --verify --quiet "$1^{commit}"; }

# next_id <dir> <prefix> [suffix]: claim the next free <prefix><n> under <dir>
# atomically, as a directory, or as an empty <prefix><n><suffix> file when a
# suffix is given, and print <prefix><n>.
next_id() {
  local n=1 path
  mkdir -p "$1" || die "cannot make $1"
  while :; do
    path="$1/$2$n${3:-}"
    if [ -n "${3:-}" ]; then (set -C; : > "$path") 2>/dev/null && break; else mkdir "$path" 2>/dev/null && break; fi
    [ -e "$path" ] || die "cannot create $path"
    n=$((n + 1))
  done
  printf '%s%s' "$2" "$n"
}

write_json() {  # <file> <json>
  printf '%s\n' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

cmd_assign() {
  local verifier='' cid='' spec='' ac='' timeout=300 max=1048576 who decl file current
  load_task "${1:-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verifier) verifier=${2:-}; shift 2 ;;
      --command-id) cid=${2:-}; shift 2 ;;
      --spec) spec=${2:-}; shift 2 ;;
      --ac) ac=${2:-}; shift 2 ;;
      --timeout) timeout=${2:-}; shift 2 ;;
      --max-output) max=${2:-}; shift 2 ;;
      --) shift; break ;;
      *) die "unknown assign argument '$1'" ;;
    esac
  done
  [ "$#" -gt 0 ] || die "assign needs the command's argv after --"
  valid_id "$verifier" || die "assign needs --verifier <task>"
  valid_id "$cid" || die "assign needs --command-id <id>"
  printf '%s' "$ac" | grep -Eq '^AC[0-9]+$' || die "assign needs --ac AC<n>"
  case "/$spec/" in *//*|*/../*|*/./*) die "--spec must be a path inside the repository" ;; esac
  case "$timeout$max" in *[!0-9]*) die "--timeout and --max-output take whole numbers" ;; esac
  [ "$timeout" -gt 0 ] && [ "$max" -gt 0 ] || die "--timeout and --max-output must be positive"
  [ "$verifier" != "$TASK" ] || die "the verifier cannot be the author $TASK"
  [ -f "$STATE/$verifier.meta" ] || die "verifier $verifier is not a recorded task"
  [ "$(physical "$(meta_get "$verifier" worktree)")" != "$(physical "$WT")" ] \
    || die "verifier $verifier shares $TASK's worktree"
  who=$(caller) || exit 2
  [ -z "$who" ] || die "only firstmate approves acceptance commands; $who is a recorded task"
  file="$EV/assignment.json"
  current=$(jq -r '.verifier // ""' "$file" 2>/dev/null || true)
  [ -z "$current" ] || [ "$current" = "$verifier" ] || die "$TASK's verifier is already $current"
  decl=$(jq -cn --arg spec "$spec" --arg ac "$ac" --argjson timeout "$timeout" --argjson max "$max" \
    '{spec: $spec, ac: $ac, argv: $ARGS.positional, timeout: $timeout, max_output: $max, env: "clean"}' --args -- "$@")
  decl=$(jq -c --arg sha "$(sha256_text "$decl")" '. + {sha256: $sha}' <<< "$decl")
  mkdir -p "$EV"
  [ -f "$file" ] || printf '{}\n' > "$file"
  write_json "$file" "$(jq -S --arg task "$TASK" --arg v "$verifier" --arg cid "$cid" --argjson decl "$decl" \
    '.version = 1 | .task = $task | .verifier = $v | .commands[$cid] = $decl' "$file")" || die "cannot write $file"
  printf 'approved %s for %s: %s of %s, verified by %s\n' "$cid" "$TASK" "$ac" "$spec" "$verifier"
}

cmd_capture() {
  local cid='' rev='' decl who id dir copy idx spec spec_blob timeout max rc outcome exit_json changed base started a
  local -a argv=()
  load_task "${1:-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command-id) cid=${2:-}; shift 2 ;;
      --revision) rev=${2:-}; shift 2 ;;
      *) die "unknown capture argument '$1'" ;;
    esac
  done
  [ -n "$cid" ] && [ -n "$rev" ] || die "capture needs --command-id <id> and --revision <commit>"
  [ -f "$EV/assignment.json" ] || refuse "no acceptance commands are approved for $TASK"
  decl=$(jq -c --arg c "$cid" '.commands[$c] // empty' "$EV/assignment.json") || die "cannot read $EV/assignment.json"
  [ -n "$decl" ] || refuse "$cid is not an approved command for $TASK"
  who=$(caller) || exit 2
  [ -n "$who" ] || die "cannot tell which recorded task is running this: $PWD is in no task's worktree"
  rev=$(commit_of "$rev") || die "cannot resolve $rev in $TASK's repository"
  spec=$(jq -r .spec <<< "$decl")
  spec_blob=$(g rev-parse --verify --quiet "$rev:$spec") || die "the spec $spec is not in $rev"
  timeout=$(jq -r .timeout <<< "$decl")
  max=$(jq -r .max_output <<< "$decl")
  while IFS= read -r -d '' a; do argv+=("$a"); done < <(jq -j '.argv[] | ., "\u0000"' <<< "$decl")

  id=$(next_id "$EV/runs" "$TASK-r") || exit 2
  dir="$EV/runs/$id"
  copy="$SCRATCH/tree"
  idx="$SCRATCH/index"
  mkdir -p "$copy" "$SCRATCH/home" "$SCRATCH/tmp"
  if ! { GIT_INDEX_FILE="$idx" g --work-tree="$copy" read-tree "$rev" \
    && GIT_INDEX_FILE="$idx" g --work-tree="$copy" checkout-index -a -u; }; then
    die "cannot check out $rev for the run"
  fi
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  base=$(jq -cn --arg id "$id" --arg task "$TASK" --arg who "$who" --arg repo "$PROJECT" --arg cid "$cid" \
    --argjson decl "$decl" --arg rev "$rev" --arg blob "$spec_blob" --argjson seq "${id##*-r}" --arg started "$started" \
    '{version: 1, id: $id, task: $task, executor: $who, author: $task, repository: $repo, command_id: $cid,
      command_sha256: $decl.sha256, argv: $decl.argv, spec: $decl.spec, ac: $decl.ac, spec_blob: $blob,
      revision: $rev, env: {policy: "clean", keys: ["HOME", "PATH", "TMPDIR"]}, timeout: $decl.timeout,
      max_output: $decl.max_output, sequence: $seq, started_at: $started,
      finished_at: null, exit: null, outcome: "started", changed_tracked: [], stdout: null, stderr: null}')
  write_json "$dir/record.json" "$base" || die "cannot write $dir/record.json"

  # The command's own status comes from this wrapper: fm_run_timed's perl path
  # reports a command killed by a signal as exit 0.
  # shellcheck disable=SC2016  # Expanded by the wrapper shell, not here.
  (cd "$copy" && fm_run_timed "$timeout" env -i PATH="$PATH" HOME="$SCRATCH/home" TMPDIR="$SCRATCH/tmp" \
    bash -c '"$@"; printf %s "$?" > "$0"' "$SCRATCH/status" "${argv[@]}") > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  [ "$rc" -eq 124 ] || [ ! -s "$SCRATCH/status" ] || rc=$(cat "$SCRATCH/status")
  GIT_INDEX_FILE="$idx" g --work-tree="$copy" update-index -q --refresh > /dev/null 2>&1
  changed=$(GIT_INDEX_FILE="$idx" g --work-tree="$copy" diff-files --name-only | jq -Rsc 'split("\n") | map(select(length > 0))')
  exit_json=$rc
  if [ "$rc" -eq 124 ]; then
    outcome=timeout
    exit_json=null
  elif [ "$changed" != '[]' ]; then
    outcome=tracked-files-changed
  elif [ "$(wc -c < "$dir/stdout")" -gt "$max" ] || [ "$(wc -c < "$dir/stderr")" -gt "$max" ]; then
    outcome=output-over-bound
  else
    outcome=exited
  fi
  write_json "$dir/record.json" "$(jq -c --arg fin "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson exit "$exit_json" \
    --arg outcome "$outcome" --argjson changed "$changed" \
    --argjson ob "$(wc -c < "$dir/stdout")" --arg os "$(sha256_file "$dir/stdout")" \
    --argjson eb "$(wc -c < "$dir/stderr")" --arg es "$(sha256_file "$dir/stderr")" \
    '. + {finished_at: $fin, exit: $exit, outcome: $outcome, changed_tracked: $changed,
          stdout: {bytes: $ob, sha256: $os}, stderr: {bytes: $eb, sha256: $es}}' <<< "$base")" \
    || die "cannot write $dir/record.json"
  printf 'run %s %s exit=%s revision=%s by %s\n' "$id" "$outcome" "$exit_json" "$rev" "$who"
}

cmd_judge() {
  local run='' base='' verdict='' who rec id
  load_task "${1:-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run) run=${2:-}; shift 2 ;;
      --base) base=${2:-}; shift 2 ;;
      --verdict) verdict=${2:-}; shift 2 ;;
      *) die "unknown judge argument '$1'" ;;
    esac
  done
  case "$verdict" in supported|unsupported) ;; *) die "judge needs --verdict supported|unsupported" ;; esac
  valid_id "$run" || die "judge needs --run <run-id>"
  rec="$EV/runs/$run/record.json"
  [ -f "$rec" ] || refuse "unknown run $run for $TASK"
  base=$(commit_of "$base") || die "judge needs --base <commit> in $TASK's repository"
  who=$(caller) || exit 2
  [ -n "$who" ] || die "cannot tell which recorded task is running this: $PWD is in no task's worktree"
  id=$(next_id "$EV/judges" "$TASK-j" .json) || exit 2
  write_json "$EV/judges/$id.json" "$(jq -c --arg id "$id" --arg who "$who" --arg base "$base" --arg verdict "$verdict" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{version: 1, id: $id, task: .task, judge: $who, run: .id, spec: .spec, spec_blob: .spec_blob, ac: .ac,
      revision: .revision, base: $base, evidence: {stdout_sha256: .stdout.sha256, stderr_sha256: .stderr.sha256},
      verdict: $verdict, judged_at: $at}' "$rec")" || die "cannot write $EV/judges/$id.json"
  printf 'judge %s %s run=%s by %s\n' "$id" "$verdict" "$run" "$who"
}

cmd_attach() {
  local pair run judge art rel out s runs=() judges=()
  load_task "${1:-}"
  shift
  [ "$#" -gt 0 ] || die "attach needs <run-id>:<judge-id>..."
  art="$WT/docs/proof/$TASK.evidence"
  for pair in "$@"; do
    run=${pair%%:*}
    judge=${pair#*:}
    valid_id "$run" && valid_id "$judge" && [ "$pair" = "$run:$judge" ] || die "attach takes <run-id>:<judge-id>, not '$pair'"
    [ -f "$EV/runs/$run/record.json" ] || refuse "unknown run $run for $TASK"
    [ -f "$EV/judges/$judge.json" ] || refuse "unknown judge $judge for $TASK"
    [ "$(jq -r .run "$EV/judges/$judge.json")" = "$run" ] || refuse "$judge judged another run than $run"
    runs+=("$EV/runs/$run/record.json")
    judges+=("$EV/judges/$judge.json")
    mkdir -p "$art"
    for s in stdout stderr; do
      [ ! -f "$EV/runs/$run/$s" ] || cp "$EV/runs/$run/$s" "$art/$run.$s"
    done
  done
  rel="docs/proof/$TASK.evidence"
  out=$(jq -S -n --arg task "$TASK" --arg rel "$rel" --slurpfile runs <(cat "${runs[@]}") --slurpfile judges <(cat "${judges[@]}") '
    def artifact($r; $s): if $r[$s] == null then null else {path: "\($rel)/\($r.id).\($s)", bytes: $r[$s].bytes, sha256: $r[$s].sha256} end;
    if ([$runs[].revision] | unique | length) != 1 then error("the runs are on different revisions")
    elif ([$judges[].base] | unique | length) != 1 then error("the judges reviewed against different bases")
    else {
      version: 1, task: $task, reviewed: $runs[0].revision, base: $judges[0].base,
      claims: [range(0; $runs | length) as $i | {spec: $runs[$i].spec, spec_blob: $runs[$i].spec_blob, ac: $runs[$i].ac,
        state: $judges[$i].verdict, run: $runs[$i].id, judge: $judges[$i].id}],
      runs: [$runs[] | {id, executor, command_id, argv, revision, exit, outcome,
        stdout: artifact(.; "stdout"), stderr: artifact(.; "stderr")}],
      judges: [$judges[] | {id, judge, run, ac, revision, base, evidence, verdict}]
    } end') || refuse "cannot attach these records together"
  mkdir -p "$WT/docs/proof"
  write_json "$WT/docs/proof/$TASK.evidence.json" "$out" || die "cannot write the manifest in $WT"
  printf 'wrote docs/proof/%s.evidence.json and its output files in %s\n' "$TASK" "$WT"
  printf 'name it in the front matter of docs/proof/%s.md: evidence: docs/proof/%s.evidence.json\n' "$TASK" "$TASK"
}

# --- verify ------------------------------------------------------------------

FAULTS=()
fault() { FAULTS+=("$1: $2"); }

proof_path() { case "/$1/" in /docs/proof/*) ;; *) return 1 ;; esac; case "/$1/" in *//*|*/../*|*/./*) return 1 ;; esac; }

# blob_at <rev> <path> <out>: a regular file's bytes at <rev>, or failure.
blob_at() {
  local entry mode
  entry=$(g ls-tree --full-tree "$1" -- "$2" 2>/dev/null)
  mode=${entry%% *}
  case "$mode" in 100644|100755) ;; *) return 1 ;; esac
  [ "${entry#*$'\t'}" = "$2" ] || return 1
  g cat-file blob "$1:$2" > "$3"
}

front_field() {  # <file> <key>
  awk -v k="$2" 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit }
    index($0, k ":") == 1 { v = substr($0, length(k) + 2); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }' "$1"
}

check_candidate() {  # <C> <P>
  local line status mode path
  [ "$1" = "$2" ] && return 0
  g merge-base --is-ancestor "$1" "$2" 2>/dev/null \
    || { fault candidate "the reviewed revision $1 is not an ancestor of the candidate $2"; return 0; }
  while IFS= read -r line; do
    path=${line#*$'\t'}
    read -r _ mode _ _ status <<< "${line%%$'\t'*}"
    case "$status:$mode" in
      A:100644|M:100644) proof_path "$path" && continue ;;
    esac
    fault candidate "$path changed after the reviewed revision $1"
  done < <(g diff-tree -r --no-renames --raw "$1" "$2")
}

# check_claim <i>: resolve manifest claim <i>; appends report lines to REPORT.
check_claim() {
  local i=$1 c run jid spec ac r ex cid decl blob s f a mr mj j path msha nsha jr
  local -a ran
  c=$(jq -c ".claims[$i]" "$MANIFEST")
  spec=$(jq -r '.spec // ""' <<< "$c")
  ac=$(jq -r '.ac // ""' <<< "$c")
  run=$(jq -r '.run // ""' <<< "$c")
  jid=$(jq -r '.judge // ""' <<< "$c")
  valid_id "$run" || { fault run "the claim for $ac names no run"; return; }
  r="$EV/runs/$run/record.json"
  [ -f "$r" ] || { fault run "unknown run $run for $TASK"; return; }
  [ "$(jq -r .task "$r")" = "$TASK" ] || fault task "run $run is not $TASK's"
  [ "$(jq -r .repository "$r")" = "$PROJECT" ] || fault repository "run $run ran in $(jq -r .repository "$r"), not $PROJECT"
  ex=$(jq -r .executor "$r")
  [ "$ex" = "$VERIFIER" ] && [ "$ex" != "$TASK" ] \
    || fault executor "run $run was executed by $ex, not the independent verifier $VERIFIER"
  cid=$(jq -r .command_id "$r")
  decl=$(jq -c --arg c "$cid" '.commands[$c] // empty' "$ASSIGNMENT")
  if [ -z "$decl" ]; then
    fault command "run $run's command $cid is not approved"
  elif [ "$(jq -r .sha256 <<< "$decl")" != "$(jq -r .command_sha256 "$r")" ]; then
    fault command "$cid changed after run $run"
  fi
  [ "$spec" = "$(jq -r .spec "$r")" ] && [ "$ac" = "$(jq -r .ac "$r")" ] \
    || fault spec "the claim names $spec $ac, the run proved $(jq -r '"\(.spec) \(.ac)"' "$r")"
  blob=$(g rev-parse --verify --quiet "$C:$spec" 2>/dev/null)
  [ -n "$blob" ] && [ "$blob" = "$(jq -r .spec_blob "$r")" ] && [ "$blob" = "$(jq -r '.spec_blob // ""' <<< "$c")" ] \
    || fault spec "the spec $spec at $C is not the one run $run checked"
  [ "$(jq -r .revision "$r")" = "$C" ] || fault revision "run $run ran on $(jq -r .revision "$r"), not the reviewed revision $C"
  case "$(jq -r .outcome "$r")" in
    exited) [ "$(jq -r .exit "$r")" = 0 ] || fault run "run $run exited $(jq -r .exit "$r")" ;;
    timeout) fault run "run $run timed out after $(jq -r .timeout "$r")s" ;;
    tracked-files-changed) fault run "run $run changed tracked files: $(jq -r '.changed_tracked | join(", ")' "$r")" ;;
    output-over-bound) fault run "run $run wrote more than $(jq -r .max_output "$r") bytes of output" ;;
    *) fault run "run $run did not finish" ;;
  esac

  mr=$(jq -c --arg id "$run" 'first(.runs[]? | select(.id == $id)) // empty' "$MANIFEST")
  [ -n "$mr" ] || fault run "the manifest has no entry for $run"
  for f in executor command_id argv revision exit outcome; do
    [ -z "$mr" ] || [ "$(jq -c ".$f" <<< "$mr")" = "$(jq -c ".$f" "$r")" ] \
      || fault run "the manifest's $f for $run differs from the run record"
  done
  for s in stdout stderr; do
    nsha=$(jq -r ".$s.sha256 // \"\"" "$r")
    [ -n "$nsha" ] || { fault output "run $run has no captured $s"; continue; }
    [ -f "$EV/runs/$run/$s" ] || { fault output "the captured $s of $run is missing"; continue; }
    [ "$(sha256_file "$EV/runs/$run/$s")" = "$nsha" ] || fault output "the captured $s of $run was altered"
    [ -n "$mr" ] || continue
    msha=$(jq -r ".$s.sha256 // \"\"" <<< "$mr")
    path=$(jq -r ".$s.path // \"\"" <<< "$mr")
    [ "$msha" = "$nsha" ] || fault output "the manifest's $s digest for $run differs from the run record"
    if ! proof_path "$path"; then
      fault output "the manifest's $s path for $run is not under docs/proof/"
    elif ! blob_at "$P" "$path" "$SCRATCH/blob"; then
      fault output "committed $s $path is not in the candidate"
    elif [ "$(sha256_file "$SCRATCH/blob")" != "$nsha" ]; then
      fault output "committed $s $path does not match the captured output"
    fi
  done

  if ! valid_id "$jid"; then
    fault judge "the claim for $ac names no judge"
    return
  fi
  j="$EV/judges/$jid.json"
  [ -f "$j" ] || { fault judge "unknown judge $jid for $TASK"; return; }
  jr=$(jq -r .judge "$j")
  [ "$(jq -r .task "$j")" = "$TASK" ] && [ "$(jq -r .run "$j")" = "$run" ] || fault judge "$jid did not judge $TASK's run $run"
  [ "$jr" = "$VERIFIER" ] && [ "$jr" != "$TASK" ] || fault judge "$jid was judged by $jr, not the independent verifier $VERIFIER"
  [ "$(jq -r .revision "$j")" = "$C" ] || fault judge "$jid judged $(jq -r .revision "$j"), not the reviewed revision $C"
  [ "$(jq -r .base "$j")" = "$BASE" ] || fault base "$jid reviewed against $(jq -r .base "$j"), the claim says $BASE"
  [ "$(jq -c .evidence "$j")" = "$(jq -c '{stdout_sha256: .stdout.sha256, stderr_sha256: .stderr.sha256}' "$r")" ] \
    || fault judge "$jid judged other output than run $run captured"
  [ "$(jq -r .verdict "$j")" = supported ] || fault judge "$jid found $ac unsupported"
  [ "$(jq -r '.state // ""' <<< "$c")" = supported ] || fault claim "the claim for $ac is not supported"
  mj=$(jq -c --arg id "$jid" 'first(.judges[]? | select(.id == $id)) // empty' "$MANIFEST")
  [ -n "$mj" ] && [ "$(jq -cS . <<< "$mj")" = "$(jq -cS '{id, judge, run, ac, revision, base, evidence, verdict}' "$j")" ] \
    || fault judge "the manifest's entry for $jid differs from the judge record"

  REPORT+="$ac $spec: run $run by $ex, judged $jid by $jr ($(jq -r .verdict "$j"))"$'\n'
  ran=()
  while IFS= read -r -d '' a; do ran+=("$a"); done < <(jq -j '.argv[] | ., "\u0000"' "$r")
  REPORT+="  Ran:$(printf ' %q' "${ran[@]}")"$'\n'
  REPORT+="  Revision: $(jq -r .revision "$r")"$'\n'
  REPORT+="  Exit: $(jq -r .exit "$r")"$'\n'
  for s in stdout stderr; do
    [ -z "$mr" ] || REPORT+="  Observed: $s $(jq -r ".$s.path" <<< "$mr") ($(jq -r ".$s.bytes" "$r") bytes, sha256 $(jq -r ".$s.sha256" "$r"))"$'\n'
  done
}

cmd_verify() {
  local proof ev n i k claimed run
  load_task "${1:-}"
  [ "$#" -eq 1 ] || die "verify takes only <task>"
  ASSIGNMENT="$EV/assignment.json"
  unchecked() { printf 'unchecked: %s\n' "$1"; exit 1; }
  [ -f "$ASSIGNMENT" ] || unchecked "no acceptance commands are approved for $TASK"
  VERIFIER=$(jq -r .verifier "$ASSIGNMENT")
  P=$(commit_of HEAD) || die "cannot resolve the HEAD of $TASK's worktree $WT"
  proof="docs/proof/$TASK.md"
  blob_at "$P" "$proof" "$SCRATCH/proof" || unchecked "$proof is not in the candidate $P"
  ev=$(front_field "$SCRATCH/proof" evidence)
  [ -n "$ev" ] || unchecked "$proof names no evidence manifest"
  MANIFEST="$SCRATCH/manifest.json"
  REPORT=
  if ! proof_path "$ev"; then
    fault evidence "$proof names $ev, which is not under docs/proof/"
  elif ! blob_at "$P" "$ev" "$MANIFEST"; then
    fault evidence "the manifest $ev is not in the candidate"
  elif ! jq -e 'type == "object"' "$MANIFEST" > /dev/null 2>&1; then
    fault evidence "the manifest $ev is not a JSON object"
  else
    [ "$(jq -r .version "$MANIFEST")" = 1 ] || fault evidence "the manifest is not version 1"
    [ "$(jq -r .task "$MANIFEST")" = "$TASK" ] || fault task "the manifest is for $(jq -r .task "$MANIFEST"), not $TASK"
    C=$(jq -r '.reviewed // ""' "$MANIFEST")
    BASE=$(jq -r '.base // ""' "$MANIFEST")
    if ! is_oid "$C" || ! commit_of "$C" > /dev/null; then
      fault revision "the reviewed revision '$C' is not a full commit id in $TASK's repository"
    else
      check_candidate "$C" "$P"
      if ! { is_oid "$BASE" && commit_of "$BASE" > /dev/null && g merge-base --is-ancestor "$BASE" "$C" 2>/dev/null; }; then
        fault base "the review base $BASE is not an ancestor of the reviewed revision $C"
      fi
      n=$(jq '.claims | length' "$MANIFEST" 2>/dev/null || echo 0)
      [ "$n" -gt 0 ] || fault claim "the manifest has no claims"
      for ((i = 0; i < n; i++)); do check_claim "$i"; done
      for k in $(jq -r '.commands | keys[]' "$ASSIGNMENT"); do
        claimed=no
        for ((i = 0; i < n; i++)); do
          run=$(jq -r ".claims[$i].run // \"\"" "$MANIFEST")
          valid_id "$run" && [ -f "$EV/runs/$run/record.json" ] || continue
          [ "$(jq -r .command_id "$EV/runs/$run/record.json")" = "$k" ] \
            && [ "$(jq -r ".claims[$i].state" "$MANIFEST")" = supported ] && claimed=yes
        done
        [ "$claimed" = yes ] || fault claim "no supported claim for approved command $k ($(jq -r --arg k "$k" '.commands[$k] | "\(.ac) of \(.spec)"' "$ASSIGNMENT"))"
      done
    fi
  fi
  if [ "${#FAULTS[@]}" -gt 0 ]; then
    printf 'refused: %s at %s\n' "$TASK" "$P"
    printf -- '- %s\n' "${FAULTS[@]}"
    exit 1
  fi
  printf 'verified: %s at %s (reviewed %s, base %s)\n%s' "$TASK" "$P" "$C" "$BASE" "$REPORT"
}

case "${1:-}" in
  assign|capture|judge|attach|verify) sub=$1; shift; "cmd_$sub" "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
