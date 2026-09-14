#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/evanagee/.no-mistakes/evidence/01M2GX2XPZVRC2M9PGWACBTVH1
LAB=$(mktemp -d "$ROOT/.test-tmp/walk.XXXXXX")
REAL_TMUX=$(command -v tmux)
SOCKET="fm-relaunch-evidence-$$"
ID="evidence-$$.0"
cleanup() {
  result=$?
  if [ "$result" -ne 0 ]; then
    printf '\nFailure diagnostics (real pane capture):\n'
    for pane in $("$REAL_TMUX" -L "$SOCKET" list-panes -a -F '#{pane_id}' 2>/dev/null); do
      "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$pane" -S -15 || true
    done
    [ ! -f "$LAB/receipt" ] || cat "$LAB/receipt"
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB" "/tmp/fm-$ID"
}
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/worker" "$LAB/home/state" "$LAB/home/data/$ID" "$LAB/home/config"
cat > "$LAB/bin/tmux" <<EOF
#!/bin/bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
cat > "$LAB/bin/claude" <<EOF
#!/bin/bash
printf 'pane=%s\ncwd=%s\n' "\$TMUX_PANE" "\$(pwd -P)" > "$LAB/receipt"
printf 'replacement running in %s on %s\n' "\$(pwd -P)" "\$TMUX_PANE"
exec -a "$LAB/worker/claude" /bin/sleep 120
EOF
chmod +x "$LAB/bin/"*
export PATH="$LAB/bin:$PATH"
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$LAB/home/state"
export FM_DATA_OVERRIDE="$LAB/home/data" FM_CONFIG_OVERRIDE="$LAB/home/config"
export FM_PROJECTS_OVERRIDE="$LAB/home/projects" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1
export FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE=1 FM_API=0 FM_GUARD_READ_ONLY=1
export FM_CONTROL_LAUNCH_WAIT=10 FM_CONTROL_POLL=0.1
unset TMUX TMUX_PANE
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
git init -q -b main "$LAB/project"
git -C "$LAB/project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m fixture
git -C "$LAB/project" worktree add -q -b fm/evidence "$LAB/worktree"
WT=$(cd "$LAB/worktree" && pwd -P)
printf 'Continue the relaunch evidence task.\n' > "$LAB/home/data/$ID/brief.md"
cat > "$LAB/home/state/$ID.meta" <<EOF
window=evidence:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$LAB/project
backend=tmux
harness=claude
kind=ship
mode=local-only
yolo=off
model=default
effort=default
EOF
start_server() {
  tmux new-session -d -s evidence -n fm-evidence-sibling -c "$LAB/project" '/bin/bash --noprofile --norc'
  tmux set-option -g default-shell /bin/bash
  tmux set-option -g default-command '/bin/bash --noprofile --norc'
  tmux set-environment -g PATH "$PATH"
}
receipt_check() {
  local pane
  pane=$(fm_tmux_display_message "evidence:fm-$ID" '#{pane_id}')
  for i in $(seq 1 50); do [ -f "$LAB/receipt" ] && break; sleep 0.1; done
  test "$(cat "$LAB/receipt")" = "$(printf 'pane=%s\ncwd=%s' "$pane" "$WT")"
  cat "$LAB/receipt"
  printf 'agent_state=%s\n' "$(fm_backend_agent_state tmux "evidence:fm-$ID")"
  tmux capture-pane -p -t "$pane" -S -8
  rm "$LAB/receipt"
}
printf 'Task: fm-relaunch-after-restart\nReal tmux; local stand-in for the agent, no model/network calls.\n'
start_server
sibling=$(tmux display-message -p -t '=evidence:=fm-evidence-sibling' '#{pane_pid}')
printf '\nScenario: missing exact window with live sibling\n'
printf 'before: state=%s current_path=<%s>\n' "$(fm_backend_agent_state tmux "evidence:fm-$ID")" "$(fm_backend_tmux_current_path "evidence:fm-$ID")"
printf '$ fm-control.sh %s relaunch --note "recover missing window"\n' "$ID"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'recover missing window'
receipt_check
kill -0 "$sibling"
printf 'sibling_pid=%s survived=true\n' "$sibling"
printf '\nScenario: missing server\n'
tmux kill-server
sleep 0.2
printf 'before: state=%s current_path=<%s>\n' "$(fm_backend_agent_state tmux "evidence:fm-$ID")" "$(fm_backend_tmux_current_path "evidence:fm-$ID")"
# No server settings survive. A private config gives the recreated server a clean shell.
cat > "$LAB/tmux.conf" <<EOF
set -g default-shell /bin/bash
set -g default-command '/bin/bash --noprofile --norc'
EOF
cat > "$LAB/bin/tmux" <<EOF
#!/bin/bash
exec "$REAL_TMUX" -f "$LAB/tmux.conf" -L "$SOCKET" "\$@"
EOF
printf '$ fm-control.sh %s relaunch --note "recover missing server"\n' "$ID"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'recover missing server'
receipt_check
printf '\nScenario: existing window in wrong directory\n'
pane=$(fm_tmux_display_message "evidence:fm-$ID" '#{pane_id}')
tmux respawn-pane -k -t "$pane" -c "$LAB/project" '/bin/bash --noprofile --norc'
sleep 0.3
cp "$LAB/home/state/$ID.meta" "$LAB/meta-before"
set +e
out=$(bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'must refuse wrong directory' 2>&1)
rc=$?
set -e
printf '%s\nexit=%s\n' "$out" "$rc"
test "$rc" -ne 0
case "$out" in *'not its recorded worktree'*) ;; *) exit 1;; esac
cmp "$LAB/meta-before" "$LAB/home/state/$ID.meta"
test ! -e "$LAB/receipt"
printf 'metadata_unchanged=true replacement_launched=false\n'
printf '\nScenario: relative selectors\n'
tmux new-window -d -t '=evidence:' -n relative -c "$LAB/project" '/bin/bash --noprofile --norc'
tmux select-window -t "$pane"
expected=$(tmux display-message -p -t '=evidence:+1' '#{pane_id}')
actual=$(fm_tmux_display_message 'evidence:+1' '#{pane_id}')
test "$expected" = "$actual"
printf 'evidence:+1 resolved=%s native=%s\n' "$actual" "$expected"
