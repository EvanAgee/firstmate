#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/evanagee/.no-mistakes/evidence/01M2GFF9WRNQCNB4766W0KEP3E
LAB=$(mktemp -d "$ROOT/.tmux-walk.XXXXXX")
REAL_TMUX=$(command -v tmux)
SOCKET="fm-validation-walk-$$"
ID="walk$$.0"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    "$REAL_TMUX" -L "$SOCKET" list-panes -a -F '#{pane_id} #{window_name} #{pane_current_command} #{pane_current_path}' || true
    for diag_pane in $("$REAL_TMUX" -L "$SOCKET" list-panes -a -F '#{pane_id}' 2>/dev/null); do
      "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$diag_pane" | sed '/^$/d' || true
    done
    cat "$LAB/receipt" 2>/dev/null || true
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
  [ ! -d "/tmp/fm-$ID" ] || rm -rf "/tmp/fm-$ID"
}
trap cleanup EXIT
mkdir -p "$LAB/shim" "$LAB/runtime" "$LAB/home/state" "$LAB/home/data/$ID" "$LAB/project" "$LAB/wrong"
cat > "$LAB/tmux.conf" <<'CONF'
set -g default-shell /bin/bash
set -g default-command '/bin/bash --noprofile --norc'
set -g automatic-rename off
CONF
cat > "$LAB/shim/tmux" <<SH
#!/bin/bash
exec "$REAL_TMUX" -L "$SOCKET" -f "$LAB/tmux.conf" "\$@"
SH
ln -s /bin/sleep "$LAB/runtime/claude"
cat > "$LAB/shim/claude" <<SH
#!/bin/bash
printf 'worker started pane=%s cwd=%s\n' "\$TMUX_PANE" "\$PWD" >> '$LAB/receipt'
printf 'LOCAL STAND-IN WORKER STARTED\n'
exec '$LAB/runtime/claude' 300
SH
chmod +x "$LAB/shim/"*
export PATH="$LAB/shim:$PATH"
export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" FM_DATA_OVERRIDE="$LAB/home/data" FM_CONFIG_OVERRIDE="$LAB/home/config" FM_PROJECTS_OVERRIDE="$LAB/home/projects"
export FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_CHROME_DEVTOOLS_AXI_SKIP_LIVE=1 FM_API=0 FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=15
export CLAUDE_CONFIG_DIR="$LAB/home/claude"
unset TMUX OMPCODE || true
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
git -C "$LAB/project" init -q
git -C "$LAB/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m "test: initialize scratch fixture"
git -C "$LAB/project" worktree add -q -b scratch "$LAB/wt"
printf 'scratch content\n' > "$LAB/wt/scratch.txt"
printf 'Continue the local scratch test.\n' > "$LAB/home/data/$ID/brief.md"
cat > "$LAB/home/state/$ID.meta" <<META
window=walk:fm-$ID
endpoint_task_id=$ID
backend=tmux
worktree=$LAB/wt
project=$LAB/project
harness=claude
kind=ship
mode=local-only
yolo=off
model=default
effort=default
META
printf '## What I walked\n\n'
printf 'Private tmux server, public fm-control relaunch, local stand-in worker. No model API or primary session used.\n'
new_server() {
  tmux new-session -d -s walk -n control -x 140 -y 30 '/bin/bash --noprofile --norc'
  tmux set-option -g default-command '/bin/bash --noprofile --norc'
  tmux set-option -g default-shell /bin/bash
  tmux set-option -g automatic-rename off
  tmux set-environment -g PATH "$PATH"
}
new_server
sibling=$(tmux new-window -dP -F '#{window_id}' -t walk: -n "fm-${ID%.0}" -c "$LAB/wrong" '/bin/bash --noprofile --norc')
sibling_pane=$(tmux display-message -p -t "$sibling" '#{pane_id}')
sibling_pid=$(tmux display-message -p -t "$sibling" '#{pane_pid}')
printf '\n$ current_path walk:fm-%s  # canonical window absent; sibling pane 0 alive\n' "$ID"
path=$(fm_backend_tmux_current_path "walk:fm-$ID")
printf 'current_path=<%s>\n' "$path"
[ -z "$path" ]
printf '\n$ fm-control.sh %s relaunch --note "continue after window loss"\n' "$ID"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'continue after window loss'
cat "$LAB/receipt"
[ "$(fm_backend_tmux_current_path "walk:fm-$ID")" = "$LAB/wt" ]
kill -0 "$sibling_pid"
printf 'Sibling remains alive: pane=%s pid=%s cwd=%s\n' "$sibling_pane" "$sibling_pid" "$(tmux display-message -p -t "$sibling" '#{pane_current_path}')"
wid=$(fm_tmux_display_message "walk:fm-$ID" '#{window_id}')
pid=$(fm_tmux_display_message "walk:fm-$ID" '#{pane_id}')
printf 'Resolved intended window=%s pane=%s canonical=%s\n' "$wid" "$pid" "$(fm_tmux_display_message "walk:fm-$ID" '#{window_name}')"
printf '\n$ tmux capture-pane -p -t %s\n' "$pid"
tmux capture-pane -p -t "$pid" | sed '/^$/d'
for selector in 'walk:+1' 'walk:-1'; do
  native=$(tmux display-message -p -t "$selector" '#{pane_id}')
  resolved=$(fm_tmux_display_message "$selector" '#{pane_id}')
  printf 'Relative selector %s: native=%s shared=%s\n' "$selector" "$native" "$resolved"
  [ "$native" = "$resolved" ]
done
printf '\n$ tmux kill-window -t %s; create same name in wrong directory\n' "$wid"
tmux kill-window -t "$wid"
wrong=$(tmux new-window -dP -F '#{window_id}' -t walk: -n "fm-$ID" -c "$LAB/wrong" '/bin/bash --noprofile --norc')
printf '\n$ fm-control.sh %s relaunch --note "wrong directory must refuse"\n' "$ID"
set +e
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'wrong directory must refuse' > "$LAB/refusal" 2>&1
rc=$?
set -e
cat "$LAB/refusal"
printf 'exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
grep -q 'not its recorded worktree' "$LAB/refusal"
[ "$(wc -l < "$LAB/receipt" | tr -d ' ')" = 1 ]
kill -0 "$sibling_pid"
printf 'No replacement started; sibling remains alive.\n'
printf '\n$ tmux kill-server\n'
tmux kill-server
sleep 0.3
path=$(fm_backend_tmux_current_path "walk:fm-$ID")
printf 'current_path after server loss=<%s>\n' "$path"
[ -z "$path" ]
printf '\n$ fm-control.sh %s relaunch --note "continue after server loss"\n' "$ID"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'continue after server loss'
cat "$LAB/receipt"
[ "$(wc -l < "$LAB/receipt" | tr -d ' ')" = 2 ]
[ "$(fm_backend_tmux_current_path "walk:fm-$ID")" = "$LAB/wt" ]
printf '\nPersisted task record:\n'
grep -E '^(window|worktree|backend|harness)=' "$LAB/home/state/$ID.meta"
printf 'Preserved scratch content: '
cat "$LAB/wt/scratch.txt"
printf '\nWalk completed. Private server and scratch fixtures removed on exit.\n'
