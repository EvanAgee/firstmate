#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# A missing named window must not fall back to the current window's path.
path=$(fm_backend_tmux_current_path "$SESSION:no-such-window-xyz")
[ -z "$path" ] \
  || fail "a missing named window should return an empty current path, got '$path'"
pass "real tmux: a missing named window returns an empty current path"

index=$(tmux display-message -p -t "$TARGET" '#{window_index}')
named_path=$(fm_backend_tmux_current_path "$TARGET")
index_path=$(fm_backend_tmux_current_path "$SESSION:$index")
pane_path=$(fm_backend_tmux_current_path "$SESSION:$index.0")
[ "$index_path" = "$named_path" ] \
  || fail "a numeric window selector should read '$named_path', got '$index_path'"
[ "$pane_path" = "$named_path" ] \
  || fail "a pane-qualified selector should read '$named_path', got '$pane_path'"
pass "real tmux: numeric window and pane-qualified selectors keep working"

# A task id may contain a dot (fm_task_id_path_safe refuses only a leading
# dot), so a dotted window name must still be proven by exact membership
# rather than exempted as a pane selector.
DOTTED="fm-v1.2"
state=$(fm_tmux_named_window_state "$SESSION:$DOTTED")
[ "$state" = missing ] \
  || fail "a gone dotted window name should classify as missing, got '$state'"
path=$(fm_backend_tmux_current_path "$SESSION:$DOTTED")
[ -z "$path" ] \
  || fail "a gone dotted window name should return an empty current path, got '$path'"

dotted_id=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n "$DOTTED" -c /tmp)
state=$(fm_tmux_named_window_state "$SESSION:$DOTTED")
[ "$state" = present ] \
  || fail "a live dotted window name should classify as present, got '$state'"
dotted_name=$(fm_tmux_display_message "$SESSION:$DOTTED" '#{window_name}')
[ "$dotted_name" = "$DOTTED" ] \
  || fail "a live dotted window name should read its own pane, got '$dotted_name'"
dotted_pane=$(fm_tmux_display_message "$dotted_id.0" '#{window_name}')
[ "$dotted_pane" = "$DOTTED" ] \
  || fail "a pane selector on a dotted window name should read it, got '$dotted_pane'"
tmux kill-window -t "$dotted_id" \
  || fail "could not remove the dotted test window '$dotted_id'"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx -- "$DOTTED"; then
  fail "the dotted test window survived kill-window"
fi
pass "real tmux: a dotted window name is proven by membership, not treated as a pane selector"

# A LIVE window whose name is the dotted name minus its numeric suffix must not
# make the gone dotted window look like one of that sibling's panes.
SIBLING="fm-sib"
sibling_id=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n "$SIBLING" -c /tmp)
sibling_pid=$(fm_tmux_display_message "$SESSION:$SIBLING" '#{pane_pid}')
case "$sibling_pid" in
  ''|*[!0-9]*) fail "could not read the live sibling window's pane pid" ;;
esac
state=$(fm_tmux_named_window_state "$SESSION:$SIBLING.0")
[ "$state" = missing ] \
  || fail "a gone dotted window with a live dot-stripped sibling should classify as missing, got '$state'"
path=$(fm_backend_tmux_current_path "$SESSION:$SIBLING.0")
[ -z "$path" ] \
  || fail "a gone dotted window should not read its live sibling's path, got '$path'"
if fm_backend_target_exists tmux "$SESSION:$SIBLING.0"; then
  fail "a gone dotted window should not exist just because its sibling '$SIBLING' does"
fi
leader=$(fm_tmux_display_message "$SESSION:$SIBLING.0" '#{pane_pid}') || leader=""
[ -z "$leader" ] \
  || fail "a gone dotted window resolved pane leader '$leader'; the live sibling's is $sibling_pid, and teardown would signal that process group"
real_pane=$(fm_tmux_display_message "$sibling_id.0" '#{pane_pid}')
[ "$real_pane" = "$sibling_pid" ] \
  || fail "a genuine pane selector on '$SIBLING' should read '$sibling_pid', got '$real_pane'"
pass "real tmux: a gone dotted window is not mistaken for a pane of its live dot-stripped sibling"

cat > "$SHIM_DIR/composer-screen.sh" <<'SH'
#!/usr/bin/env bash
printf '\033[2J\033[H\033[31m%s\033[0m\n' "$1"
printf '╭──────────────────────╮\n│ > %-18s │\n╰──────────────────────╯\n%s\033[3;5H' "$2" "$3"
exec sleep 120
SH
capture_sibling=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n fm-v1 \
  "bash '$SHIM_DIR/composer-screen.sh' sibling-screen '' idle-owner") \
  || fail "could not create the capture sibling"
capture_window=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n fm-v1.0 \
  "bash '$SHIM_DIR/composer-screen.sh' intended-screen pending-owner busy-owner") \
  || fail "could not create the dotted capture window"
tmux set-window-option -t "$capture_sibling" automatic-rename off
tmux set-window-option -t "$capture_window" automatic-rename off
capture_pane=$(tmux display-message -p -t "$capture_window" '#{pane_id}')
capture_sibling_pane=$(tmux display-message -p -t "$capture_sibling" '#{pane_id}')
capture_sibling_pid=$(tmux display-message -p -t "$capture_sibling_pane" '#{pane_pid}')
wait_for_capture_text "$capture_pane" busy-owner || fail "the intended composer did not render"
wait_for_capture_text "$capture_sibling_pane" idle-owner || fail "the sibling composer did not render"
[ "$(tmux display-message -p -t "$capture_pane" '#{window_name}')" = fm-v1.0 ] \
  || fail "the intended capture window lost its canonical name"
[ "$(fm_tmux_composer_state "$SESSION:fm-v1")" = empty ] \
  || fail "the sibling control must have an empty composer"
[ "$(fm_tmux_composer_state "$SESSION:fm-v1.0")" = pending ] \
  || fail "the intended pending composer must not read as the sibling's empty composer"
[ "$(fm_tmux_composer_cursor_row "$SESSION:fm-v1.0")" = \
  "$(tmux display-message -p -t "$capture_pane" '#{cursor_y}')" ] \
  || fail "the dotted composer cursor must belong to the intended pane"
expected_styled=$(tmux capture-pane -e -p -t "$capture_pane" -S 0 -E -)
expected_plain=$(tmux capture-pane -p -t "$capture_pane" -S -20)
[ "$(fm_tmux_composer_capture "$SESSION:fm-v1.0")" = "$expected_styled" ] \
  || fail "styled capture must belong to the intended pane"
[ "$(fm_backend_tmux_capture "$SESSION:fm-v1.0" 20)" = "$expected_plain" ] \
  || fail "plain capture must belong to the intended pane"
[ "$(FM_BUSY_REGEX='^busy-owner$' fm_pane_busy_state "$SESSION:fm-v1.0")" = busy ] \
  || fail "busy capture must read the intended pane's footer"
[ "$(FM_BUSY_REGEX='^busy-owner$' fm_pane_busy_state "$SESSION:fm-v1")" = idle ] \
  || fail "busy capture must keep the sibling's idle footer distinct"
pass "real tmux: dotted composer, cursor, styled capture, plain capture, and busy tail belong to one pane"

tmux rename-window -t "$capture_window" editor.0
if missing_capture=$(fm_backend_tmux_capture "$SESSION:fm-v1.0" 20); then
  fail "plain capture must refuse the missing canonical window"
fi
[ -z "$missing_capture" ] || fail "a missing canonical window returned plain capture bytes"
if missing_capture=$(fm_tmux_composer_capture "$SESSION:fm-v1.0"); then
  fail "styled capture must refuse the missing canonical window"
fi
[ -z "$missing_capture" ] || fail "a missing canonical window returned styled capture bytes"
[ "$(fm_tmux_composer_state "$SESSION:fm-v1.0")" = unknown ] \
  || fail "the missing canonical composer must remain unknown"
[ "$(FM_BUSY_REGEX='^busy-owner$' fm_pane_busy_state "$SESSION:fm-v1.0")" = unknown ] \
  || fail "the missing canonical busy state must remain unknown"
capture_index=$(tmux display-message -p -t "$capture_pane" '#{window_index}')
for selector in "$capture_pane" "$capture_window.0" "$SESSION:$capture_index.0" "$SESSION:editor.0.0"; do
  [ "$(fm_backend_tmux_capture "$selector" 20)" = "$expected_plain" ] \
    || fail "plain capture failed for explicit pane selector '$selector'"
  [ "$(fm_tmux_composer_capture "$selector")" = "$expected_styled" ] \
    || fail "styled capture failed for explicit pane selector '$selector'"
  [ "$(fm_tmux_composer_state "$selector")" = pending ] \
    || fail "composer state failed for explicit pane selector '$selector'"
  [ "$(FM_BUSY_REGEX='^busy-owner$' fm_pane_busy_state "$selector")" = busy ] \
    || fail "busy state failed for explicit pane selector '$selector'"
done
tmux kill-window -t "$capture_window"
kill -0 "$capture_sibling_pid" || fail "the sibling died during capture checks"
[ "$(tmux display-message -p -t "$capture_sibling_pane" '#{window_name}')" = fm-v1 ] \
  || fail "capture cleanup changed the sibling window"
tmux kill-window -t "$capture_sibling"
pass "real tmux: missing canonical captures fail closed while explicit pane selectors keep working"

cat > "$SHIM_DIR/submit-screen.py" <<'PYUI'
import os
import sys
import tty

marker, text, log_path = sys.argv[1:]
tty.setraw(sys.stdin.fileno())

def render():
    sys.stdout.write("\033[2J\033[H" + marker + "\r\n╭" + "─" * 22 + "╮\r\n")
    sys.stdout.write("│ > " + text.ljust(18) + " │\r\n╰" + "─" * 22 + "╯\033[3;5H")
    sys.stdout.flush()

with open(log_path, "ab", buffering=0) as received:
    render()
    while True:
        key = os.read(sys.stdin.fileno(), 1)
        if not key:
            break
        received.write(key)
        if key not in (b"\r", b"\n"):
            text += key.decode("ascii")
        render()
PYUI
submit_sibling=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n fm-v1 \
  "python3 '$SHIM_DIR/submit-screen.py' sibling-submit sibling-pending '$SHIM_DIR/sibling-input'") \
  || fail "could not create the submit sibling"
submit_window=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n fm-v1.0 \
  "python3 '$SHIM_DIR/submit-screen.py' intended-submit '' '$SHIM_DIR/intended-input'") \
  || fail "could not create the dotted submit window"
tmux set-window-option -t "$submit_sibling" automatic-rename off
tmux set-window-option -t "$submit_window" automatic-rename off
submit_pane=$(tmux display-message -p -t "$submit_window" '#{pane_id}')
submit_sibling_pane=$(tmux display-message -p -t "$submit_sibling" '#{pane_id}')
wait_for_capture_text "$submit_pane" intended-submit || fail "the intended submit composer did not render"
wait_for_capture_text "$submit_sibling_pane" sibling-submit || fail "the sibling submit composer did not render"
[ "$(fm_tmux_composer_state "$SESSION:fm-v1.0")" = empty ] \
  || fail "the intended submit composer must start empty"
[ "$(fm_tmux_composer_state "$SESSION:fm-v1")" = pending ] \
  || fail "the sibling submit composer must start pending"
submit_sibling_screen=$(tmux capture-pane -p -t "$submit_sibling_pane" -S 0 -E -)
verdict=$(fm_tmux_submit_core "$SESSION:fm-v1.0" owned-message 2 1 1)
[ "$verdict" = pending ] \
  || fail "a retained message in the intended pane must stay pending, got '$verdict'"
printf 'owned-message\r\r' > "$SHIM_DIR/expected-input"
cmp -s "$SHIM_DIR/expected-input" "$SHIM_DIR/intended-input" \
  || fail "typing and both Enter attempts must reach only the intended pane"
[ ! -s "$SHIM_DIR/sibling-input" ] || fail "submit sent input to the sibling pane"
verdict=$(fm_tmux_submit_enter_core "$SESSION:fm-v1.0" 1 1)
[ "$verdict" = pending ] || fail "Enter-only submission must verify the intended pane"
printf '\r' >> "$SHIM_DIR/expected-input"
cmp -s "$SHIM_DIR/expected-input" "$SHIM_DIR/intended-input" \
  || fail "direct Enter submission must reach the intended pane"
[ ! -s "$SHIM_DIR/sibling-input" ] || fail "Enter-only submission touched the sibling pane"
[ "$(tmux capture-pane -p -t "$submit_sibling_pane" -S 0 -E -)" = "$submit_sibling_screen" ] \
  || fail "submission changed the sibling's composer"

tmux rename-window -t "$submit_window" submitted.0
[ "$(fm_tmux_submit_core "$SESSION:fm-v1.0" refused 1 0 0)" = send-failed ] \
  || fail "typing must refuse a missing canonical task window"
[ "$(fm_tmux_submit_enter_core "$SESSION:fm-v1.0" 1 0)" = send-failed ] \
  || fail "Enter must refuse a missing canonical task window"
cmp -s "$SHIM_DIR/expected-input" "$SHIM_DIR/intended-input" \
  || fail "missing-window submission sent input to the renamed pane"
[ ! -s "$SHIM_DIR/sibling-input" ] || fail "missing-window submission touched the sibling pane"
tmux kill-window -t "$submit_window"
[ "$(tmux display-message -p -t "$submit_sibling_pane" '#{window_name}')" = fm-v1 ] \
  || fail "submit cleanup removed the sibling window"
tmux kill-window -t "$submit_sibling"
pass "real tmux: typing, Enter retries, and verification share the intended pane; missing tasks refuse input"

tmux new-session -d -s prefix-other -n fm-prefix -c "$HOME"
path=$(fm_backend_tmux_current_path "prefix:fm-prefix")
[ -z "$path" ] \
  || fail "a missing exact session should not read from its prefix match, got '$path'"
fm_backend_tmux_create_task prefix fm-prefix "$HOME" >/dev/null \
  || fail "a missing exact session should be created beside its prefix match"
tmux has-session -t '=prefix' \
  || fail "fm_backend_tmux_create_task did not create the exact requested session"
tmux list-windows -t '=prefix' -F '#{window_name}' | grep -Fqx fm-prefix \
  || fail "the recreated window did not land in the exact requested session"
pass "real tmux: session prefix matches cannot redirect reads or task creation"

# fm_backend_target_exists must not answer for the client's current window
# when the named window is gone.
fm_backend_target_exists tmux "$TARGET" \
  || fail "fm_backend_target_exists should report a live named window as existing"
if fm_backend_target_exists tmux "$SESSION:no-such-window-xyz"; then
  fail "fm_backend_target_exists should report a missing named window as gone"
fi
pass "real tmux: fm_backend_target_exists reports a missing named window as gone"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

tmux kill-server
path=$(fm_backend_tmux_current_path "$TARGET")
[ -z "$path" ] \
  || fail "a missing tmux server should return an empty current path, got '$path'"
pass "real tmux: a missing server returns an empty current path"

if fm_backend_target_exists tmux "$TARGET"; then
  fail "fm_backend_target_exists should report a gone tmux server as gone"
fi
pass "real tmux: fm_backend_target_exists reports a missing server as gone"

cleanup_all
trap - EXIT
