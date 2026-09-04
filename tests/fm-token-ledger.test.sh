#!/usr/bin/env bash
# Behavior tests for bin/fm-token-ledger.sh.
#
# Every case builds its own Claude and Pi session logs under the test's temp
# root and points the ledger at them with FM_CLAUDE_SESSIONS_ROOT and
# FM_PI_SESSIONS_ROOT, so no case ever reads the captain's real session logs.
#
# Covered: Claude token columns, Pi token and cost columns, pipeline
# attribution by manager branch and by the no-mistakes worktrees root, the
# no-guess rule that keeps a session outside every spawn window unattributed
# when a worktree slot is reused, the same no-guess rule holding under a --since
# cutoff placed after the slot was respawned, the same rule holding for a session
# that records no cwd and for a log whose records are not in time order,
# firstmate's own session, --since filtering, compare totals and shared-task
# rows, compare's one-line error on a non-numeric cell, and the task subcommand.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-token-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-ledger)

# Fixed epochs so a window boundary is exact rather than clock-dependent.
# 1788500000 = 2026-09-04T06:53:20Z, well inside the fixture day.
EARLY_SPAWN=1788500000
LATE_SPAWN=1788510000

iso_at() {  # <epoch-seconds> -> the UTC ISO-8601 stamp the logs use
  python3 -c 'import sys,datetime;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"
}

# claude_session <sessions-root> <session-id> <cwd> <branch> <model> <epoch> <in> <cw> <cr> <out> <think>
# One Claude session file with a single assistant turn carrying message.usage.
claude_session() {
  local root=$1 id=$2 cwd=$3 branch=$4 model=$5 epoch=$6
  local input=$7 cache_write=$8 cache_read=$9 output=${10} thinking=${11}
  local slug dir
  slug=$(printf '%s' "$cwd" | tr '/.' '--')
  dir=$root/$slug
  mkdir -p "$dir"
  python3 - "$dir/$id.jsonl" "$cwd" "$branch" "$model" "$(iso_at "$epoch")" \
    "$input" "$cache_write" "$cache_read" "$output" "$thinking" <<'PY'
import json, sys
path, cwd, branch, model, stamp = sys.argv[1:6]
numbers = [int(value) for value in sys.argv[6:11]]
record = {
    "type": "assistant",
    "timestamp": stamp,
    "cwd": cwd,
    "gitBranch": branch,
    "message": {
        "model": model,
        "usage": {
            "input_tokens": numbers[0],
            "cache_creation_input_tokens": numbers[1],
            "cache_read_input_tokens": numbers[2],
            "output_tokens": numbers[3],
            "output_tokens_details": {"thinking_tokens": numbers[4]},
        },
    },
}
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

# pi_session <sessions-root> <session-id> <cwd> <provider> <model> <epoch> <in> <cw> <cr> <out> <reason> <cost>
pi_session() {
  local root=$1 id=$2 cwd=$3 provider=$4 model=$5 epoch=$6
  local input=$7 cache_write=$8 cache_read=$9 output=${10} reasoning=${11} cost=${12}
  local slug dir
  slug=$(printf '%s' "$cwd" | tr '/.' '--')
  dir=$root/$slug
  mkdir -p "$dir"
  python3 - "$dir/$id.jsonl" "$cwd" "$provider" "$model" "$(iso_at "$epoch")" \
    "$input" "$cache_write" "$cache_read" "$output" "$reasoning" "$cost" <<'PY'
import json, sys
path, cwd, provider, model, stamp = sys.argv[1:6]
numbers = [int(value) for value in sys.argv[6:11]]
cost = float(sys.argv[11])
lines = [
    {"type": "session", "timestamp": stamp, "cwd": cwd},
    {"type": "model_change", "timestamp": stamp, "provider": provider, "modelId": model},
    {
        "type": "message",
        "timestamp": stamp,
        "message": {
            "role": "assistant",
            "usage": {
                "input": numbers[0],
                "cacheWrite": numbers[1],
                "cacheRead": numbers[2],
                "output": numbers[3],
                "reasoning": numbers[4],
                "totalTokens": sum(numbers),
                "cost": {"total": cost},
            },
        },
    },
]
with open(path, "w", encoding="utf-8") as handle:
    for line in lines:
        handle.write(json.dumps(line) + "\n")
PY
}

# make_home <name>: a firstmate home with empty state/ and data/, echoed.
make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

# run_ledger <home> <claude-root> <pi-root> <nm-worktrees> <args...>
run_ledger() {
  local home=$1 claude_root=$2 pi_root=$3 nm_root=$4
  shift 4
  FM_ROOT_OVERRIDE="$home" \
    FM_CLAUDE_SESSIONS_ROOT="$claude_root" \
    FM_PI_SESSIONS_ROOT="$pi_root" \
    FM_NO_MISTAKES_WORKTREES="$nm_root" \
    "$LEDGER" "$@"
}

# field <output> <session-id> <column-number>: one TSV cell from a row.
field() {
  printf '%s\n' "$1" | awk -F'\t' -v id="$2" -v col="$3" '$16 == id {print $col}'
}

test_claude_columns_and_worker_attribution() {
  local home claude pi nm out
  home=$(make_home claude-columns)
  claude=$TMP_ROOT/claude-columns-logs
  pi=$TMP_ROOT/claude-columns-pi
  nm=$TMP_ROOT/claude-columns-nm
  mkdir -p "$claude" "$pi" "$nm"

  fm_write_meta "$home/state/alpha-ship.meta" \
    "worktree=$TMP_ROOT/slot/1/alpha" \
    "kind=ship" \
    "spawn_gen=s$EARLY_SPAWN.100.200"
  claude_session "$claude" sess-alpha "$TMP_ROOT/slot/1/alpha" fm/alpha claude-opus-5 \
    $((EARLY_SPAWN + 60)) 11 22 33 44 55

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the Claude fixture"

  [ "$(field "$out" sess-alpha 1)" = alpha-ship ] \
    || fail "a Claude session inside the spawn window was not attributed to its task"
  [ "$(field "$out" sess-alpha 2)" = worker ] \
    || fail "a kind=ship meta did not produce a worker row"
  [ "$(field "$out" sess-alpha 3)" = claude ] || fail "the harness column is not claude"
  [ "$(field "$out" sess-alpha 5)" = fm/alpha ] || fail "the branch column is wrong"
  [ "$(field "$out" sess-alpha 6)" = claude-opus-5 ] || fail "the model column is wrong"
  [ "$(field "$out" sess-alpha 9)" = 1 ] || fail "the turn count is wrong"
  [ "$(field "$out" sess-alpha 10)" = 11 ] || fail "input_tokens did not land in input"
  [ "$(field "$out" sess-alpha 11)" = 22 ] \
    || fail "cache_creation_input_tokens did not land in cache_write"
  [ "$(field "$out" sess-alpha 12)" = 33 ] \
    || fail "cache_read_input_tokens did not land in cache_read"
  [ "$(field "$out" sess-alpha 13)" = 44 ] || fail "output_tokens did not land in output"
  [ "$(field "$out" sess-alpha 14)" = 55 ] || fail "thinking_tokens did not land in thinking"
  pass "a Claude session reports its token columns and its owning worker task"
}

test_pi_columns_cost_and_scout_kind() {
  local home claude pi nm out
  home=$(make_home pi-columns)
  claude=$TMP_ROOT/pi-columns-claude
  pi=$TMP_ROOT/pi-columns-logs
  nm=$TMP_ROOT/pi-columns-nm
  mkdir -p "$claude" "$pi" "$nm"

  fm_write_meta "$home/state/beta-scout.meta" \
    "worktree=$TMP_ROOT/slot/2/beta" \
    "kind=scout" \
    "spawn_gen=s$EARLY_SPAWN.101.201"
  pi_session "$pi" sess-beta "$TMP_ROOT/slot/2/beta" xai grok-4.6 \
    $((EARLY_SPAWN + 90)) 7 8 9 10 11 1.25

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the Pi fixture"

  [ "$(field "$out" sess-beta 1)" = beta-scout ] \
    || fail "a Pi session inside the spawn window was not attributed to its task"
  [ "$(field "$out" sess-beta 2)" = scout ] || fail "a kind=scout meta did not produce a scout row"
  [ "$(field "$out" sess-beta 3)" = pi ] || fail "the harness column is not pi"
  [ "$(field "$out" sess-beta 6)" = xai/grok-4.6 ] \
    || fail "model_change provider and modelId did not compose the model column"
  [ "$(field "$out" sess-beta 10)" = 7 ] || fail "Pi input did not land in input"
  [ "$(field "$out" sess-beta 11)" = 8 ] || fail "Pi cacheWrite did not land in cache_write"
  [ "$(field "$out" sess-beta 12)" = 9 ] || fail "Pi cacheRead did not land in cache_read"
  [ "$(field "$out" sess-beta 13)" = 10 ] || fail "Pi output did not land in output"
  [ "$(field "$out" sess-beta 14)" = 11 ] || fail "Pi reasoning did not land in thinking"
  [ "$(field "$out" sess-beta 15)" = 1.2500 ] || fail "Pi cost.total did not land in cost_usd"
  pass "a Pi session reports its token columns, its recorded cost, and its scout kind"
}

test_pipeline_attribution() {
  local home claude pi nm out
  home=$(make_home pipeline)
  claude=$TMP_ROOT/pipeline-claude
  pi=$TMP_ROOT/pipeline-pi
  nm=$TMP_ROOT/pipeline-nm
  mkdir -p "$claude" "$pi" "$nm/repohash"

  claude_session "$claude" sess-manager "$TMP_ROOT/anywhere" manager/RUN-BRANCH claude-opus-5 \
    $((EARLY_SPAWN + 10)) 1 2 3 4 0
  claude_session "$claude" sess-nmtree "$nm/repohash/RUN-CWD" HEAD claude-opus-5 \
    $((EARLY_SPAWN + 20)) 1 2 3 4 0

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the manager-branch fixture"

  [ "$(field "$out" sess-manager 1)" = RUN-BRANCH ] \
    || fail "a manager/<run-id> branch did not attribute to that run id"
  [ "$(field "$out" sess-manager 2)" = pipeline ] \
    || fail "a manager-branch session was not classified as pipeline"
  [ "$(field "$out" sess-nmtree 1)" = RUN-CWD ] \
    || fail "a session under the no-mistakes worktrees root did not attribute to its run id"
  [ "$(field "$out" sess-nmtree 2)" = pipeline ] \
    || fail "a no-mistakes worktree session was not classified as pipeline"
  pass "pipeline sessions attribute by manager branch and by the no-mistakes worktrees root"
}

test_reused_slot_never_guesses() {
  local home claude pi nm out slot
  home=$(make_home slot-reuse)
  claude=$TMP_ROOT/slot-reuse-claude
  pi=$TMP_ROOT/slot-reuse-pi
  nm=$TMP_ROOT/slot-reuse-nm
  mkdir -p "$claude" "$pi" "$nm"
  slot=$TMP_ROOT/reused/3/repo

  # Two tasks occupied the same slot in turn. Only the later one still has a
  # meta; the earlier one was torn down, exactly as it is on a live machine.
  fm_write_meta "$home/state/second-occupant.meta" \
    "worktree=$slot" \
    "kind=ship" \
    "spawn_gen=s$LATE_SPAWN.102.202"

  claude_session "$claude" sess-before "$slot" fm/first claude-opus-5 \
    $((LATE_SPAWN - 500)) 1 2 3 4 0
  claude_session "$claude" sess-after "$slot" fm/second claude-opus-5 \
    $((LATE_SPAWN + 500)) 1 2 3 4 0

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the slot-reuse fixture"

  [ "$(field "$out" sess-after 1)" = second-occupant ] \
    || fail "a session inside the current occupant's window was not attributed to it"
  [ "$(field "$out" sess-before 1)" = "-" ] \
    || fail "a session that predates the current occupant's spawn was guessed onto it"
  [ "$(field "$out" sess-before 2)" = "-" ] \
    || fail "an unattributed slot-reuse session was given a kind"
  [ "$(field "$out" sess-before 4)" = "$slot" ] \
    || fail "an unattributed session lost its worktree"
  pass "a session outside every spawn window stays unattributed on a reused slot"
}

test_since_never_moves_a_session_onto_another_task() {
  local home claude pi nm out slot now first_turn respawn
  home=$(make_home since-attribution)
  claude=$TMP_ROOT/since-attribution-claude
  pi=$TMP_ROOT/since-attribution-pi
  nm=$TMP_ROOT/since-attribution-nm
  mkdir -p "$claude" "$pi" "$nm"
  slot=$TMP_ROOT/reused/11/repo
  now=$(date +%s)
  first_turn=$((now - 30 * 3600))
  respawn=$((now - 3600))

  # An overnight session that still runs, in a slot respawned an hour ago for a
  # different task. Only the new occupant has a meta, so nothing proves the old
  # session's owner and it must stay unattributed under every cutoff.
  fm_write_meta "$home/state/today-task.meta" \
    "worktree=$slot" "kind=ship" "spawn_gen=s$respawn.110.210"
  claude_session "$claude" sess-overnight "$slot" fm/overnight claude-opus-5 \
    "$first_turn" 1 2 3 4 0
  claude_session "$claude" sess-overnight "$slot" fm/overnight claude-opus-5 \
    $((now - 600)) 1 2 3 4 0

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2020-01-01 --stdout) \
    || fail "snapshot with full history failed"
  [ "$(field "$out" sess-overnight 1)" = "-" ] \
    || fail "with full history the overnight session was charged to the new occupant"

  # The cutoff sits after the respawn, so only the recent turns are counted.
  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot \
    --since "$(iso_at $((respawn + 60)))" --stdout) \
    || fail "snapshot with a cutoff after the respawn failed"
  [ "$(field "$out" sess-overnight 1)" = "-" ] \
    || fail "--since moved the overnight session onto the task that now holds the slot"
  [ "$(field "$out" sess-overnight 2)" = "-" ] \
    || fail "--since gave the overnight session a kind it has no evidence for"
  [ "$(field "$out" sess-overnight 4)" = "$slot" ] \
    || fail "the unattributed overnight session lost its worktree"
  [ "$(field "$out" sess-overnight 9)" = 1 ] \
    || fail "--since should still count only the turns at or after the cutoff"
  pass "--since scopes which turns are counted and never which task is billed"
}

test_a_session_with_no_cwd_stays_unattributed() {
  local home claude pi nm caller out
  home=$(make_home no-cwd)
  claude=$TMP_ROOT/no-cwd-claude
  pi=$TMP_ROOT/no-cwd-pi
  nm=$TMP_ROOT/no-cwd-nm
  caller=$TMP_ROOT/no-cwd-caller
  mkdir -p "$claude/empty-slug" "$pi" "$nm" "$caller"

  # A task whose worktree is the very directory the ledger is invoked from. A
  # session that records no cwd must not be billed to it just for lining up.
  fm_write_meta "$home/state/caller-task.meta" \
    "worktree=$caller" "kind=ship" "spawn_gen=s$EARLY_SPAWN.111.211"
  python3 - "$claude/empty-slug/sess-nocwd.jsonl" "$(iso_at $((EARLY_SPAWN + 60)))" <<'PY'
import json, sys
path, stamp = sys.argv[1:3]
record = {
    "type": "assistant",
    "timestamp": stamp,
    "cwd": "",
    "message": {"model": "claude-opus-5", "usage": {"input_tokens": 5, "output_tokens": 6}},
}
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY

  out=$(cd "$caller" && run_ledger "$home" "$claude" "$pi" "$nm" \
    snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the empty-cwd fixture"

  [ "$(field "$out" sess-nocwd 1)" = "-" ] \
    || fail "a session with no cwd was billed to the task holding the ledger's own directory"
  [ "$(field "$out" sess-nocwd 2)" = "-" ] \
    || fail "a session with no cwd was given a kind it has no evidence for"
  [ "$(field "$out" sess-nocwd 4)" = "-" ] \
    || fail "a session with no cwd should report no worktree"
  pass "a session that records no cwd stays unattributed"
}

test_out_of_order_log_attributes_on_its_earliest_turn() {
  local home claude pi nm out slot now first_turn respawn
  home=$(make_home out-of-order)
  claude=$TMP_ROOT/out-of-order-claude
  pi=$TMP_ROOT/out-of-order-pi
  nm=$TMP_ROOT/out-of-order-nm
  mkdir -p "$claude" "$pi" "$nm"
  slot=$TMP_ROOT/reused/12/repo
  now=$(date +%s)
  first_turn=$((now - 30 * 3600))
  respawn=$((now - 3600))

  fm_write_meta "$home/state/today-task.meta" \
    "worktree=$slot" "kind=ship" "spawn_gen=s$respawn.112.212"
  # The recent turn is written first, so file order and time order disagree.
  claude_session "$claude" sess-jumbled "$slot" fm/jumbled claude-opus-5 \
    $((now - 600)) 1 2 3 4 0
  claude_session "$claude" sess-jumbled "$slot" fm/jumbled claude-opus-5 \
    "$first_turn" 1 2 3 4 0

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2020-01-01 --stdout) \
    || fail "snapshot failed on the out-of-order fixture"

  [ "$(field "$out" sess-jumbled 1)" = "-" ] \
    || fail "an out-of-order log was attributed on a later turn instead of its earliest"
  [ "$(field "$out" sess-jumbled 2)" = "-" ] \
    || fail "an out-of-order log was given a kind it has no evidence for"
  [ "$(field "$out" sess-jumbled 4)" = "$slot" ] \
    || fail "the unattributed out-of-order session lost its worktree"
  pass "attribution reads a log's earliest turn, not the first one written"
}

test_earlier_occupant_window_closes_at_the_next_spawn() {
  local home claude pi nm out slot
  home=$(make_home window-close)
  claude=$TMP_ROOT/window-close-claude
  pi=$TMP_ROOT/window-close-pi
  nm=$TMP_ROOT/window-close-nm
  mkdir -p "$claude" "$pi" "$nm"
  slot=$TMP_ROOT/reused/4/repo

  # Both occupants still have metas, so the earlier window is bounded by the
  # later spawn rather than running to now.
  fm_write_meta "$home/state/first-occupant.meta" \
    "worktree=$slot" "kind=ship" "spawn_gen=s$EARLY_SPAWN.103.203"
  fm_write_meta "$home/state/later-occupant.meta" \
    "worktree=$slot" "kind=ship" "spawn_gen=s$LATE_SPAWN.104.204"

  claude_session "$claude" sess-in-first "$slot" fm/first claude-opus-5 \
    $((EARLY_SPAWN + 100)) 1 2 3 4 0
  claude_session "$claude" sess-in-later "$slot" fm/later claude-opus-5 \
    $((LATE_SPAWN + 100)) 1 2 3 4 0

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the two-occupant fixture"

  [ "$(field "$out" sess-in-first 1)" = first-occupant ] \
    || fail "a session in the earlier occupant's window was not attributed to it"
  [ "$(field "$out" sess-in-later 1)" = later-occupant ] \
    || fail "a session after the later spawn was not attributed to the later occupant"
  pass "an earlier occupant's window closes at the next spawn on the same slot"
}

test_firstmate_and_since_filter() {
  local home claude pi nm out
  home=$(make_home firstmate-own)
  claude=$TMP_ROOT/firstmate-own-claude
  pi=$TMP_ROOT/firstmate-own-pi
  nm=$TMP_ROOT/firstmate-own-nm
  mkdir -p "$claude" "$pi" "$nm"

  claude_session "$claude" sess-fm "$home" HEAD claude-opus-5 \
    $((EARLY_SPAWN + 30)) 1 2 3 4 0
  claude_session "$claude" sess-old "$home" HEAD claude-opus-5 \
    $((EARLY_SPAWN - 100000)) 9 9 9 9 9

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --stdout) \
    || fail "snapshot failed on the firstmate fixture"
  [ "$(field "$out" sess-fm 1)" = firstmate ] \
    || fail "a session in the primary checkout was not attributed to firstmate"
  [ "$(field "$out" sess-fm 2)" = firstmate ] \
    || fail "the primary-checkout session did not get the firstmate kind"
  assert_contains "$out" "sess-old" "the pre-cutoff session should be present without --since"

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot \
    --since "$(iso_at "$EARLY_SPAWN")" --stdout) \
    || fail "snapshot with --since failed"
  assert_contains "$out" "sess-fm" "--since dropped a session that is inside the window"
  assert_not_contains "$out" "sess-old" "--since kept a session with no turn after the cutoff"
  pass "firstmate's own session is attributed and --since drops earlier sessions"
}

test_snapshot_writes_a_labelled_file_and_totals() {
  local home claude pi nm out
  home=$(make_home labelled)
  claude=$TMP_ROOT/labelled-claude
  pi=$TMP_ROOT/labelled-pi
  nm=$TMP_ROOT/labelled-nm
  mkdir -p "$claude" "$pi" "$nm"

  fm_write_meta "$home/state/gamma.meta" \
    "worktree=$TMP_ROOT/slot/5/gamma" "kind=ship" "spawn_gen=s$EARLY_SPAWN.105.205"
  claude_session "$claude" sess-gamma "$TMP_ROOT/slot/5/gamma" fm/gamma claude-opus-5 \
    $((EARLY_SPAWN + 5)) 10 20 30 40 50
  pi_session "$pi" sess-delta "$TMP_ROOT/slot/6/delta" xai grok-4.6 \
    $((EARLY_SPAWN + 6)) 1 1 1 1 1 0.5

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --label before) \
    || fail "a labelled snapshot failed"
  assert_present "$home/data/token-ledger/before.tsv" \
    "--label did not write data/token-ledger/<label>.tsv"
  assert_grep "sess-gamma" "$home/data/token-ledger/before.tsv" \
    "the written file is missing the Claude row"
  assert_contains "$out" "by harness" "totals by harness are missing"
  assert_contains "$out" "by kind" "totals by kind are missing"
  assert_contains "$out" "unattributed" "the unattributed group is not named in the kind totals"
  assert_contains "$out" "cost_usd=0.50" "the totals did not carry the Pi cost"

  run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --label "../escape" \
    >/dev/null 2>&1 && fail "--label accepted a path escape"
  pass "snapshot writes the labelled file, prints both totals groups, and refuses a path label"
}

test_compare_totals_and_shared_tasks() {
  local home claude pi nm out
  home=$(make_home compare)
  claude=$TMP_ROOT/compare-claude
  pi=$TMP_ROOT/compare-pi
  nm=$TMP_ROOT/compare-nm
  mkdir -p "$claude" "$pi" "$nm"

  # Before: one task spending 100 output tokens, plus a task that later vanishes.
  fm_write_meta "$home/state/shared-task.meta" \
    "worktree=$TMP_ROOT/slot/7/shared" "kind=ship" "spawn_gen=s$EARLY_SPAWN.106.206"
  fm_write_meta "$home/state/dropped-task.meta" \
    "worktree=$TMP_ROOT/slot/8/dropped" "kind=ship" "spawn_gen=s$EARLY_SPAWN.107.207"
  claude_session "$claude" sess-shared-a "$TMP_ROOT/slot/7/shared" fm/shared claude-opus-5 \
    $((EARLY_SPAWN + 1)) 0 0 0 100 0
  claude_session "$claude" sess-dropped "$TMP_ROOT/slot/8/dropped" fm/dropped claude-opus-5 \
    $((EARLY_SPAWN + 2)) 0 0 0 10 0
  run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --label before >/dev/null \
    || fail "the before snapshot failed"

  # After: the shared task spends half as much, the dropped task is gone, and a
  # new task appears.
  rm -f "$claude"/*/sess-shared-a.jsonl "$claude"/*/sess-dropped.jsonl
  rm -f "$home/state/dropped-task.meta"
  fm_write_meta "$home/state/new-task.meta" \
    "worktree=$TMP_ROOT/slot/9/new" "kind=ship" "spawn_gen=s$EARLY_SPAWN.108.208"
  claude_session "$claude" sess-shared-b "$TMP_ROOT/slot/7/shared" fm/shared claude-opus-5 \
    $((EARLY_SPAWN + 3)) 0 0 0 50 0
  claude_session "$claude" sess-new "$TMP_ROOT/slot/9/new" fm/new claude-opus-5 \
    $((EARLY_SPAWN + 4)) 0 0 0 5 0
  run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --label after >/dev/null \
    || fail "the after snapshot failed"

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" compare \
    "$home/data/token-ledger/before.tsv" "$home/data/token-ledger/after.tsv") \
    || fail "compare failed on two written snapshots"

  assert_contains "$out" "output" "compare did not print the output row"
  assert_contains "$out" "-50.0%" "compare did not report the halved shared-task output"
  assert_contains "$out" "shared-task: tokens 100 -> 50" \
    "compare did not print the shared task's before and after"
  assert_contains "$out" "only in a (1): dropped-task" \
    "compare did not name the task that is only in the first file"
  assert_contains "$out" "only in b (1): new-task" \
    "compare did not name the task that is only in the second file"

  run_ledger "$home" "$claude" "$pi" "$nm" compare "$home/data/token-ledger/before.tsv" \
    >/dev/null 2>&1 && fail "compare accepted a single path"
  pass "compare reports totals with percent change and the tasks in both files"
}

test_task_subcommand() {
  local home claude pi nm out
  home=$(make_home task-cmd)
  claude=$TMP_ROOT/task-cmd-claude
  pi=$TMP_ROOT/task-cmd-pi
  nm=$TMP_ROOT/task-cmd-nm
  mkdir -p "$claude" "$pi" "$nm"

  fm_write_meta "$home/state/quoted-task.meta" \
    "worktree=$TMP_ROOT/slot/10/quoted" "kind=ship" "spawn_gen=s$EARLY_SPAWN.109.209"
  claude_session "$claude" sess-q1 "$TMP_ROOT/slot/10/quoted" fm/q claude-opus-5 \
    $((EARLY_SPAWN + 1)) 0 0 0 30 0
  claude_session "$claude" sess-q2 "$TMP_ROOT/slot/10/quoted" fm/q claude-opus-5 \
    $((EARLY_SPAWN + 2)) 0 0 0 70 0
  claude_session "$claude" sess-other "$TMP_ROOT/elsewhere" HEAD claude-opus-5 \
    $((EARLY_SPAWN + 3)) 0 0 0 999 0

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" task quoted-task) \
    || fail "the task subcommand failed"
  assert_contains "$out" "sess-q1" "task dropped one of the task's own sessions"
  assert_contains "$out" "sess-q2" "task dropped one of the task's own sessions"
  assert_not_contains "$out" "sess-other" "task included a session belonging to no task"
  assert_contains "$out" "quoted-task: sessions=2" "task did not print its own totals line"
  assert_contains "$out" "output=100" "task totalled the output column wrong"

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" task no-such-task) \
    || fail "the task subcommand failed on an unknown id"
  assert_contains "$out" "no sessions attributed to no-such-task" \
    "an unknown task id did not report an empty result"
  pass "task prints one task's sessions and its totals"
}

test_compare_rejects_a_non_numeric_cell() {
  local home claude pi nm good bad out
  home=$(make_home bad-cell)
  claude=$TMP_ROOT/bad-cell-claude
  pi=$TMP_ROOT/bad-cell-pi
  nm=$TMP_ROOT/bad-cell-nm
  mkdir -p "$claude" "$pi" "$nm"

  claude_session "$claude" sess-cell "$TMP_ROOT/elsewhere" HEAD claude-opus-5 \
    $((EARLY_SPAWN + 1)) 1 2 3 4 0
  run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since 2026-01-01 --label good >/dev/null \
    || fail "the snapshot that seeds the bad-cell fixture failed"

  good=$home/data/token-ledger/good.tsv
  bad=$home/data/token-ledger/bad.tsv
  awk -F'\t' 'BEGIN {OFS = "\t"} NR > 1 {$15 = "N/A"} {print}' "$good" >"$bad"

  out=$(run_ledger "$home" "$claude" "$pi" "$nm" compare "$good" "$bad" 2>&1)
  expect_code 1 "$?" "compare on a non-numeric cost_usd"
  assert_contains "$out" "non-numeric cost_usd" \
    "compare did not name the bad cost cell in a one-line error"
  assert_not_contains "$out" "Traceback" "compare leaked a Python traceback"
  pass "compare reports a non-numeric cell as a one-line error"
}

test_usage_errors() {
  local home claude pi nm
  home=$(make_home usage)
  claude=$TMP_ROOT/usage-claude
  pi=$TMP_ROOT/usage-pi
  nm=$TMP_ROOT/usage-nm
  mkdir -p "$claude" "$pi" "$nm"

  run_ledger "$home" "$claude" "$pi" "$nm" nonsense >/dev/null 2>&1
  expect_code 2 "$?" "an unknown subcommand"
  run_ledger "$home" "$claude" "$pi" "$nm" snapshot --since not-a-date >/dev/null 2>&1
  expect_code 2 "$?" "an unparseable --since"
  run_ledger "$home" "$claude" "$pi" "$nm" snapshot --unknown >/dev/null 2>&1
  expect_code 2 "$?" "an unknown snapshot option"
  "$LEDGER" --help >/dev/null || fail "--help did not exit 0"
  pass "usage errors exit 2 and --help exits 0"
}

test_claude_columns_and_worker_attribution
test_pi_columns_cost_and_scout_kind
test_pipeline_attribution
test_reused_slot_never_guesses
test_since_never_moves_a_session_onto_another_task
test_a_session_with_no_cwd_stays_unattributed
test_out_of_order_log_attributes_on_its_earliest_turn
test_earlier_occupant_window_closes_at_the_next_spawn
test_firstmate_and_since_filter
test_snapshot_writes_a_labelled_file_and_totals
test_compare_totals_and_shared_tasks
test_task_subcommand
test_compare_rejects_a_non_numeric_cell
test_usage_errors

echo "# all fm-token-ledger tests passed"
