#!/usr/bin/env bash
# Opt-in real OMP primary, worker, scout, and secondmate lifecycle in one guarded Herdr lab.
set -u

if [ "${FM_OMP_HERDR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_HERDR_LIVE_E2E=1 to run the isolated OMP Herdr role matrix"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v treehouse >/dev/null 2>&1 || fail "treehouse not found"

OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
REAL_HERDR=$(command -v herdr)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"

LAB=$(fm_test_tmproot fm-omp-herdr-live)
SESSION="fm-lab-omp-matrix-$$-${RANDOM:-0}"
WRAPPER_BIN="$LAB/bin"
WRAPPER_LOG="$LAB/herdr-wrapper.log"
BASE_PATH=$PATH
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
DRIVER_ROOT="$LAB/driver-root"
PRIMARY_HOME="$HOME_DIR"
PRIMARY_PROJECT="$DRIVER_ROOT"
SECOND_HOME="$LAB/secondmate-home"
WORKER_ID="omp-herdr-worker-$$"
SCOUT_ID="omp-herdr-scout-$$"
SECONDMATE_ID="omp-herdr-secondmate-$$"
WORKER_WT=
SCOUT_WT=
TEARDOWN_DONE=0

cleanup_pid_file() { # <file>
  local file=$1 pid
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || true
}

cleanup_worktree() { # <path>
  local wt=$1 project_head wt_head
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 1
  project_head=$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || true)
  wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  [ -n "$project_head" ] && [ "$project_head" = "$wt_head" ] || return 1
  ( cd "$PROJECT" && treehouse return --force "$wt" ) >/dev/null 2>&1
}

cleanup() {
  local cleanup_ok=1
  if [ "${FM_OMP_HERDR_KEEP_FAILED:-0}" = 1 ] && [ "$TEARDOWN_DONE" -ne 1 ]; then
    echo "diagnostic: preserving failed lab $SESSION at $LAB" >&2
    return
  fi
  cleanup_pid_file "$PRIMARY_HOME/state/.watch.lock/pid"
  cleanup_pid_file "$SECOND_HOME/state/.watch.lock/pid"
  if [ "$TEARDOWN_DONE" -ne 1 ]; then
    FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
      "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || cleanup_ok=0
  fi
  cleanup_worktree "$WORKER_WT" || cleanup_ok=0
  cleanup_worktree "$SCOUT_WT" || cleanup_ok=0
  if [ "$cleanup_ok" -eq 1 ]; then
    rm -rf "/tmp/fm-$WORKER_ID" "/tmp/fm-$SCOUT_ID" "/tmp/fm-$SECONDMATE_ID" "$LAB"
  else
    echo "not ok - OMP Herdr fixture cleanup incomplete; preserving $LAB and its task roots" >&2
    trap - EXIT
    exit 1
  fi
}
trap cleanup EXIT

mkdir -p "$WRAPPER_BIN" "$PROJECT" "$DRIVER_ROOT" "$HOME_DIR/data/$WORKER_ID" "$HOME_DIR/data/$SCOUT_ID" \
  "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
git archive HEAD | tar -x -C "$DRIVER_ROOT"
git init -q -b main "$DRIVER_ROOT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$DRIVER_ROOT" add .
git -C "$DRIVER_ROOT" commit -qm init

cat > "$WRAPPER_BIN/herdr" <<SH
#!/usr/bin/env bash
set -u
real='$REAL_HERDR'
helper='$HERDR_LAB_HELPER'
session='$SESSION'
base_path='$BASE_PATH'
wrapper_bin='$WRAPPER_BIN'
log='$WRAPPER_LOG'
if [ "\${FM_HERDR_LAB_INNER:-0}" = 1 ]; then
  if [ "\${1:-}" = server ]; then
    exec env -u FM_HERDR_LAB_INNER "\$real" "\$@"
  fi
  exec "\$real" "\$@"
fi
case "\${1:-}" in
  --version|-V|version) exec "\$real" "\$@" ;;
esac
if [ "\$#" -eq 2 ] && [ "\$1" = status ] && [ "\$2" = --json ] \
  && [ "\${HERDR_SESSION:-}" = "\$session" ]; then
  set -- "\$@" --session "\$session"
fi
printf '%q ' "\$@" >> "\$log"
printf '\n' >> "\$log"
argc=\$#
[ "\$argc" -ge 2 ] || { echo "OMP Herdr fixture refused a command without explicit session binding" >&2; exit 96; }
args=("\$@")
penultimate=\${args[\$((argc - 2))]}
last=\${args[\$((argc - 1))]}
[ "\$penultimate" = --session ] && [ "\$last" = "\$session" ] \
  || { echo "OMP Herdr fixture refused a command outside its exact lab session" >&2; exit 96; }
set -- "\${args[@]:0:\$((argc - 2))}"
case "\${1:-}" in
  server|session)
    echo "OMP Herdr fixture refused an unguarded lifecycle command" >&2
    exit 97
    ;;
esac
exec env FM_HERDR_LAB_INNER=1 PATH="\$wrapper_bin:\$base_path" "\$helper" run "\$session" "\$@"
SH

chmod +x "$WRAPPER_BIN/herdr"

# Launch the server through the guarded helper while giving every pane the
# session-enforcing Herdr wrapper and deterministic treehouse fixture.
FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
  "$HERDR_LAB_HELPER" provision "$SESSION" >/dev/null \
  || fail "could not provision the guarded Herdr role-matrix lab"

lab() {
  FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
    "$HERDR_LAB_HELPER" run "$SESSION" "$@"
}

fm_env() {
  env PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_SESSION="$SESSION" OMP_SKIP_SETUP=1 \
    FM_BACKEND=herdr FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$DRIVER_ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$@"
}

pane_id() { printf '%s' "${1#*:}"; }

agent_json() {
  lab agent get "$(pane_id "$1")" 2>/dev/null
}

agent_is() { # <target> <identity> <state-pattern>
  local info identity state
  info=$(agent_json "$1" || true)
  identity=$(printf '%s' "$info" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  state=$(printf '%s' "$info" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$identity" = "$2" ] || return 1
  case " $3 " in *" $state "*) return 0 ;; *) return 1 ;; esac
}

pane_missing() {
  local out
  out=$(lab pane get "$(pane_id "$1")" 2>&1 || true)
  printf '%s' "$out" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1
}

session_file_for() {
  agent_json "$1" | jq -r 'select(.result.agent.agent_session.kind == "path") | .result.agent.agent_session.value // empty' 2>/dev/null
}

session_has_exact_steer_after() { # <file> <offset> <text>
  local file=$1 offset=$2 text=$3 start
  start=$((offset + 1))
  tail -c "+$start" "$file" 2>/dev/null \
    | jq -se --arg text "$text" 'any(.[]; .type == "message" and .message.role == "user" and .message.attribution == "user" and .message.steering == true and .message.content[0].text == $text)' \
      >/dev/null 2>&1
}

wait_for() { # <description> <command...>
  local description=$1 i=0
  shift
  while [ "$i" -lt 600 ]; do
    "$@" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  fail "timed out waiting for $description"
}

file_exists() { [ -f "$1" ]; }
file_nonempty() { [ -s "$1" ]; }
file_has() { grep -F -- "$2" "$1" >/dev/null 2>&1; }

send_task() {
  fm_env FM_SEND_SLEEP=0.2 FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$@" >/dev/null
}

spawn_task() { # <id> [--scout]
  local id=$1
  shift
  fm_env FM_SPAWN_NO_GUARD=1 FM_OMP_LAUNCH_ACK_INTERVAL=0.25 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --harness omp \
      --model openai-codex/gpt-5.6-sol --effort low "$@"
}

# --- real primary ------------------------------------------------------------
mkdir -p "$PRIMARY_HOME/sessions"
printf 'herdr\n' > "$PRIMARY_HOME/config/backend"
printf 'omp\n' > "$PRIMARY_HOME/config/crew-harness"
primary_create=$(lab workspace create --cwd "$PRIMARY_PROJECT" --label omp-primary-live --no-focus) \
  || fail "could not create the guarded OMP primary workspace"
PRIMARY_PANE=$(printf '%s' "$primary_create" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PRIMARY_PANE" ] || fail "primary workspace returned no pane"
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
printf -v primary_launch \
  "exec env PATH=%q OMP_SKIP_SETUP=1 FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q %q --model openai-codex/gpt-5.6-sol --thinking low --session-dir %q --auto-approve -e %q %q" \
  "$WRAPPER_BIN:$BASE_PATH" "$PRIMARY_HOME" "$PRIMARY_PROJECT" "$PRIMARY_HOME/state" "$PRIMARY_HOME/config" \
  "$OMP_BIN" "$PRIMARY_HOME/sessions" "$PRIMARY_PROJECT/.omp/extensions/fm-primary-omp.ts" \
  "Follow the injected startup instruction exactly once, call the fm_watch_arm_omp tool, then reply exactly OMP_HERDR_PRIMARY_READY."
lab pane run "$PRIMARY_PANE" "$primary_launch" >/dev/null || fail "could not launch the real OMP primary"
wait_for "exact idle OMP primary identity" agent_is "$PRIMARY_TARGET" omp 'idle done'
wait_for "OMP primary integration marker" file_nonempty "$PRIMARY_HOME/state/.omp-primary-extension-loaded"
wait_for "OMP primary session lock" file_nonempty "$PRIMARY_HOME/state/.lock"
PRIMARY_SESSION=$(session_file_for "$PRIMARY_TARGET")
case "$PRIMARY_SESSION" in "$PRIMARY_HOME/sessions/"*.jsonl) ;; *) fail "primary Herdr identity did not bind its controlled native session" ;; esac
wait_for "OMP primary guarded response" file_has "$PRIMARY_SESSION" OMP_HERDR_PRIMARY_READY

# Keep the real primary and its home-scoped watcher alive while it supervises
# the worker, scout, and secondmate role evidence below.

# --- production worker and scout --------------------------------------------
printf 'Remember OMP_HERDR_CONTEXT_73. Reply exactly OMP_HERDR_WORKER_READY.\n' > "$HOME_DIR/data/$WORKER_ID/brief.md"
printf 'Reply exactly OMP_HERDR_SCOUT_READY.\n' > "$HOME_DIR/data/$SCOUT_ID/brief.md"
printf '%s\n' '- project [direct-PR] - OMP Herdr live fixture (added 2026-07-30)' > "$HOME_DIR/data/projects.md"
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm init
git init -q --bare "$LAB/project-origin.git"
git -C "$PROJECT" remote add origin "$LAB/project-origin.git"
git -C "$PROJECT" push -qu origin main

spawn_task "$WORKER_ID" >/dev/null || fail "production OMP Herdr worker spawn failed"
WORKER_META="$HOME_DIR/state/$WORKER_ID.meta"
WORKER_TARGET=$(sed -n 's/^window=//p' "$WORKER_META")
WORKER_WT=$(sed -n 's/^worktree=//p' "$WORKER_META")
[ -n "$WORKER_WT" ] && [ "$WORKER_WT" != "$PROJECT" ] && [ -d "$WORKER_WT" ] \
  || fail "Herdr worker did not acquire a distinct isolated worktree"
assert_grep 'harness=omp' "$WORKER_META" "Herdr worker metadata lost exact OMP identity"
assert_grep 'backend=herdr' "$WORKER_META" "Herdr worker metadata lost its backend"
assert_grep "worktree=$WORKER_WT" "$WORKER_META" "Herdr worker did not enter its isolated worktree"
wait_for "worker extension readiness" file_exists "$HOME_DIR/state/$WORKER_ID.omp-ready"
wait_for "worker first turn" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended"
wait_for "exact idle worker identity" agent_is "$WORKER_TARGET" omp 'idle done'
WORKER_SESSION=$(session_file_for "$WORKER_TARGET")
case "$WORKER_SESSION" in "/tmp/fm-$WORKER_ID/omp-sessions/"*.jsonl) ;; *) fail "worker Herdr identity did not bind its task-owned session" ;; esac
file_has "$WORKER_SESSION" OMP_HERDR_WORKER_READY || fail "worker launch brief did not complete"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
send_task "$WORKER_ID" 'Run this exact bash command: sleep 4. Then reply exactly OMP_HERDR_BUSY_FIRST.' \
  || fail "worker busy-turn setup was not submitted"
wait_for "native working worker state" agent_is "$WORKER_TARGET" omp working
steer_offset=$(wc -c < "$WORKER_SESSION" | tr -d '[:space:]')
send_task "$WORKER_ID" 'After the tool finishes, reply exactly OMP_HERDR_BUSY_STEER.' \
  || fail "worker busy steering was not event-confirmed"
wait_for "worker exact native steering event" session_has_exact_steer_after \
  "$WORKER_SESSION" "$steer_offset" 'After the tool finishes, reply exactly OMP_HERDR_BUSY_STEER.'
wait_for "worker busy turn completion" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended"
wait_for "worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
worker_exit_offset=$(wc -c < "$WORKER_SESSION" | tr -d '[:space:]')
send_task "$WORKER_ID" /exit || fail "production worker /exit was not event-confirmed"
wait_for "exact worker pane absence" pane_missing "$WORKER_TARGET"
tail -c "+$((worker_exit_offset + 1))" "$WORKER_SESSION" \
  | jq -se 'any(.[]; .type == "custom" and .customType == "session_exit" and .data.kind == "normal")' >/dev/null \
  || fail "worker did not append a normal session_exit"
fm_env "$ROOT/bin/fm-teardown.sh" "$WORKER_ID" >/dev/null \
  || fail "production cleanup refused the clean, unchanged OMP Herdr worker"
[ ! -e "$WORKER_META" ] && [ ! -e "$HOME_DIR/state/$WORKER_ID.omp-ext.ts" ] && [ ! -e "/tmp/fm-$WORKER_ID" ] \
  || fail "worker cleanup left generated OMP artifacts behind"
WORKER_WT=

spawn_task "$SCOUT_ID" --scout >/dev/null || fail "production OMP Herdr scout spawn failed"
SCOUT_META="$HOME_DIR/state/$SCOUT_ID.meta"
SCOUT_TARGET=$(sed -n 's/^window=//p' "$SCOUT_META")
SCOUT_WT=$(sed -n 's/^worktree=//p' "$SCOUT_META")
[ -n "$SCOUT_WT" ] && [ "$SCOUT_WT" != "$PROJECT" ] && [ -d "$SCOUT_WT" ] \
  || fail "Herdr scout did not acquire a distinct isolated worktree"
assert_grep 'harness=omp' "$SCOUT_META" "Herdr scout metadata lost exact OMP identity"
assert_grep 'kind=scout' "$SCOUT_META" "Herdr scout changed delivery semantics"
assert_grep "worktree=$SCOUT_WT" "$SCOUT_META" "Herdr scout did not enter its isolated worktree"
wait_for "scout extension readiness" file_exists "$HOME_DIR/state/$SCOUT_ID.omp-ready"
wait_for "scout first turn" file_exists "$HOME_DIR/state/$SCOUT_ID.turn-ended"
wait_for "exact idle scout identity" agent_is "$SCOUT_TARGET" omp 'idle done'
SCOUT_SESSION=$(session_file_for "$SCOUT_TARGET")
file_has "$SCOUT_SESSION" OMP_HERDR_SCOUT_READY || fail "scout launch brief did not complete"
scout_exit_offset=$(wc -c < "$SCOUT_SESSION" | tr -d '[:space:]')
send_task "$SCOUT_ID" /exit || fail "production scout /exit was not event-confirmed"
wait_for "exact scout pane absence" pane_missing "$SCOUT_TARGET"
tail -c "+$((scout_exit_offset + 1))" "$SCOUT_SESSION" \
  | jq -se 'any(.[]; .type == "custom" and .customType == "session_exit" and .data.kind == "normal")' >/dev/null \
  || fail "scout did not append a normal session_exit"
printf 'OMP Herdr scout lifecycle evidence complete.\n' > "$HOME_DIR/data/$SCOUT_ID/report.md"
fm_env "$ROOT/bin/fm-decision-hold.sh" complete "$SCOUT_ID" --none >/dev/null \
  || fail "scout unresolved-decision inventory did not complete"
fm_env "$ROOT/bin/fm-teardown.sh" "$SCOUT_ID" >/dev/null \
  || fail "production cleanup refused the clean, reported OMP Herdr scout"
[ ! -e "$SCOUT_META" ] && [ ! -e "$HOME_DIR/state/$SCOUT_ID.omp-ext.ts" ] && [ ! -e "/tmp/fm-$SCOUT_ID" ] \
  || fail "scout cleanup left generated OMP artifacts behind"
SCOUT_WT=

# --- production persistent secondmate ---------------------------------------
git clone -q "$DRIVER_ROOT" "$SECOND_HOME"
mkdir -p "$SECOND_HOME/data" "$SECOND_HOME/state" "$SECOND_HOME/config" "$SECOND_HOME/projects"
printf '%s\n' "$SECONDMATE_ID" > "$SECOND_HOME/.fm-secondmate-home"
printf 'omp openai-codex/gpt-5.6-sol low\n' > "$HOME_DIR/config/secondmate-harness"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_SECONDMATE_CHARTER='Wait for marked lifecycle-test requests and return correlated answers to the parent.' \
  FM_SECONDMATE_SCOPE='Guarded OMP Herdr lifecycle verification only.' \
  "$ROOT/bin/fm-brief.sh" "$SECONDMATE_ID" --secondmate --no-projects >/dev/null

spawn_secondmate() {
  fm_env FM_OMP_SECONDMATE_ACK_POLLS=600 FM_OMP_LAUNCH_ACK_INTERVAL=0.25 \
    "$ROOT/bin/fm-spawn.sh" "$SECONDMATE_ID" "$SECOND_HOME" --secondmate
}

spawn_secondmate >/dev/null || fail "production OMP Herdr secondmate spawn failed"
SECONDMATE_META="$HOME_DIR/state/$SECONDMATE_ID.meta"
SECONDMATE_TARGET=$(sed -n 's/^window=//p' "$SECONDMATE_META")
assert_grep 'harness=omp' "$SECONDMATE_META" "Herdr secondmate metadata lost exact OMP identity"
assert_grep 'kind=secondmate' "$SECONDMATE_META" "Herdr secondmate metadata lost its role"
wait_for "secondmate primary integration" file_nonempty "$SECOND_HOME/state/.omp-primary-extension-loaded"
wait_for "exact idle secondmate identity" agent_is "$SECONDMATE_TARGET" omp 'idle done'
send_task "$SECONDMATE_ID" 'Return exactly OMP_HERDR_ROUTED_REPLY through the correlated parent status path.' \
  || fail "marked secondmate request was not submitted"
wait_for "correlated secondmate reply" file_has "$HOME_DIR/state/$SECONDMATE_ID.status" OMP_HERDR_ROUTED_REPLY
wait_for "secondmate return to idle" agent_is "$SECONDMATE_TARGET" omp 'idle done'
SECONDMATE_SESSION=$(cat "$SECOND_HOME/state/.omp-session" 2>/dev/null || true)
case "$SECONDMATE_SESSION" in "$SECOND_HOME/state/omp-sessions/"*.jsonl) ;; *) fail "secondmate did not publish an exact durable OMP session" ;; esac
send_task "$SECONDMATE_TARGET" /exit || fail "production secondmate /exit was not event-confirmed"
wait_for "exact secondmate pane absence" pane_missing "$SECONDMATE_TARGET"

spawn_secondmate >/dev/null || fail "production OMP Herdr secondmate exact-session recovery failed"
RESUMED_TARGET=$(sed -n 's/^window=//p' "$SECONDMATE_META")
wait_for "resumed exact secondmate identity" agent_is "$RESUMED_TARGET" omp 'idle done'
[ "$(cat "$SECOND_HOME/state/.omp-session")" = "$SECONDMATE_SESSION" ] \
  || fail "secondmate recovery changed the retained session identity"
set +e
duplicate=$(spawn_secondmate 2>&1)
duplicate_rc=$?
set -e
[ "$duplicate_rc" -ne 0 ] || fail "live OMP Herdr secondmate accepted a duplicate launch"
assert_contains "$duplicate" 'already has a live agent' "secondmate duplicate refusal was not authoritative"
send_task "$RESUMED_TARGET" /exit || fail "resumed OMP Herdr secondmate did not exit cleanly"
wait_for "resumed secondmate pane absence" pane_missing "$RESUMED_TARGET"

primary_offset=$(wc -c < "$PRIMARY_SESSION" | tr -d '[:space:]')
primary_verdict=$(PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_SESSION="$SESSION" \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit "$1" /exit 1 0.2 0 "" omp' \
    "$DRIVER_ROOT" "$PRIMARY_TARGET")
[ "$primary_verdict" = empty ] || fail "real OMP primary /exit was not event-confirmed"
wait_for "exact primary pane absence" pane_missing "$PRIMARY_TARGET"
tail -c "+$((primary_offset + 1))" "$PRIMARY_SESSION" \
  | jq -se 'any(.[]; .type == "custom" and .customType == "session_exit" and .data.kind == "normal")' >/dev/null \
  || fail "real OMP primary did not append a normal session_exit"

# Every production Herdr command logged by the wrapper was accepted only with
# the exact trailing named-session binding. The helper owns final teardown and
# its default-session tripwire.
[ -s "$WRAPPER_LOG" ] || fail "production role matrix issued no Herdr commands through the wrapper"
awk -v session="$SESSION" '$(NF - 1) != "--session" || $NF != session { bad = 1 } END { exit bad }' "$WRAPPER_LOG" \
  || fail "a production Herdr command escaped the exact lab session"
FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
  "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null \
  || fail "guarded Herdr role-matrix teardown or default-session tripwire failed"
TEARDOWN_DONE=1

pass "real Herdr OMP role matrix: primary, worker, scout, secondmate, busy steering, normal exits, recovery, duplicate refusal, and guarded teardown"
