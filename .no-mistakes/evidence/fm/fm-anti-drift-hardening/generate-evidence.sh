#!/usr/bin/env bash
# Manual end-user evidence for fm-anti-drift-hardening. Drives the public
# binaries the same way a home would, never grepping implementation source.
set -u
EVIDENCE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$EVIDENCE_DIR/../../worktrees/b99440365b40/01M0JG59ZXVW9PW711KWT0YA5F" && pwd)"
# The evidence dir is outside the worktree; resolve ROOT from known worktree.
if [ ! -x "$ROOT/bin/fm-wake-drain.sh" ]; then
  ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0JG59ZXVW9PW711KWT0YA5F"
fi
HOME_ROOT=$(mktemp -d /tmp/fm-anti-drift-evidence.XXXXXX)
cleanup() { rm -rf "$HOME_ROOT"; }
trap cleanup EXIT

. "$ROOT/tests/wake-helpers.sh"
. "$ROOT/bin/fm-classify-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CHECKER="$ROOT/bin/fm-watcher-beat-alarm.sh"
INSTALLER="$ROOT/bin/fm-watcher-beat-alarm-install.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
BRIEF="$ROOT/bin/fm-brief.sh"

make_home() {
  local name=$1 dir
  dir="$HOME_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/root"
  printf '# Captain preferences (home-local)\n\n## Working style\n\n- batch updates\n- no fable for scouts\n- prefer durable notes over chat memory\n\n## Other\nx\n' \
    > "$dir/data/captain.md"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:t" "kind=ship"
  printf 'working: x\n' > "$dir/state/task.status"
  printf '%s' "$dir"
}

{
  echo "=== ITEM 1+2: heartbeat drain prints ANCHOR; signal drain does not ==="
  dir=$(make_home heartbeat)
  append_wake "$dir/state" heartbeat - "no changes"
  echo "--- heartbeat drain ---"
  env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" "$DRAIN" 2>/dev/null
  echo "--- odometer after first heartbeat ---"
  cat "$dir/state/.session-odometer"
  echo "--- last-anchor exists? ---"
  [ -f "$dir/state/.last-anchor" ] && echo "yes: $dir/state/.last-anchor" || echo "NO"

  dir=$(make_home signal)
  printf 'blocked [key=creds]: waiting on credits\n' > "$dir/state/task.status"
  append_wake "$dir/state" signal task "task.status"
  echo "--- signal drain (must not contain ANCHOR) ---"
  env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" "$DRAIN" 2>/dev/null
  echo "--- last-anchor after signal? ---"
  [ -f "$dir/state/.last-anchor" ] && echo "unexpected last-anchor" || echo "absent (correct)"

  echo
  echo "=== ITEM 2: odometer advice when age threshold exceeded ==="
  dir=$(make_home advice)
  printf 'pid=whatever\nstarted_epoch=1\nwakes=0\n' > "$dir/state/.session-odometer"
  printf 'whatever\n' > "$dir/state/.lock"
  append_wake "$dir/state" heartbeat - "no changes"
  env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_ODOMETER_MAX_AGE=3600 "$DRAIN" 2>/dev/null

  echo
  echo "=== ITEM 1: flags surface ==="
  dir=$(make_home flags)
  printf '2026-08-21T00:00:00Z\n' > "$dir/state/.github-down"
  printf 'guard-key\n' > "$dir/state/.guard-watcher-stale-banner"
  append_wake "$dir/state" heartbeat - "no changes"
  env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" "$DRAIN" 2>/dev/null

  echo
  echo "=== ITEM 3+5: supervision protocol duty lines ==="
  for harness in claude codex pi; do
    echo "--- harness $harness (steer + cadence) ---"
    "$RENDER" --harness "$harness" | grep -E 'Steer capture:|Heartbeat cadence:|data/captain.md|fleet status board|batch a captain'
  done
  echo "--- read-only must omit duties ---"
  if "$RENDER" --harness codex --read-only 1 | grep -E 'Steer capture:|Heartbeat cadence:'; then
    echo "UNEXPECTED duties in read-only"
  else
    echo "omitted (correct)"
  fi

  echo
  echo "=== ITEM 7: generated brief Rules standing rule ==="
  bhome="$HOME_ROOT/brief-home"
  mkdir -p "$bhome/data"
  cat > "$bhome/data/projects.md" <<'EOF'
- some-proj [direct-PR] - fixture
EOF
  FM_HOME="$bhome" "$BRIEF" brief-demo some-proj --mode no-mistakes >/dev/null
  echo "--- Rules section excerpt ---"
  awk 'BEGIN{p=0} $0=="# Rules"{p=1} p && /^# / && $0!="# Rules"{p=0} p{print}' "$bhome/data/brief-demo/brief.md"
  echo "--- scout Rules excerpt ---"
  FM_HOME="$bhome" "$BRIEF" brief-scout some-proj --scout >/dev/null
  awk 'BEGIN{p=0} $0=="# Rules"{p=1} p && /^# / && $0!="# Rules"{p=0} p{print}' "$bhome/data/brief-scout/brief.md"

  echo
  echo "=== ITEM 4: watcher-beat alarm once per episode ==="
  rec="$HOME_ROOT/rec"
  rec_log="$HOME_ROOT/rec.log"
  cat > "$rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
exit 0
REC
  chmod +x "$rec"
  : > "$rec_log"
  dir=$(make_home beat)
  backdate=$(date -v-30S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '30 seconds ago' '+%Y%m%d%H%M.%S')
  touch -t "$backdate" "$dir/state/.last-watcher-beat"
  echo "--- first stale check ---"
  env FM_HOME_OVERRIDE="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_BEAT_ALARM_GRACE=8 \
    FM_WEDGE_ALARM_EXEC="$rec" FM_WEDGE_ALARM_LOG="$rec_log" \
    "$CHECKER" --home "$dir"
  echo "notifier log:"; cat "$rec_log"
  echo "marker:"; cat "$dir/state/.beat-alarm-fired"
  echo "--- second same-episode check (must stay silent) ---"
  env FM_HOME_OVERRIDE="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_BEAT_ALARM_GRACE=8 \
    FM_WEDGE_ALARM_EXEC="$rec" FM_WEDGE_ALARM_LOG="$rec_log" \
    "$CHECKER" --home "$dir"
  echo "notifier log after second run:"; cat "$rec_log"
  echo "--- installer without consent ---"
  agents="$HOME_ROOT/launch-agents"
  mkdir -p "$agents"
  FM_HOME_OVERRIDE="$dir" LAUNCH_AGENTS_DIR="$agents" "$INSTALLER" install < /dev/null || true
  echo "plist count: $(find "$agents" -name 'com.firstmate.watcher-beat-alarm*' | wc -l | tr -d ' ')"

  echo
  echo "=== ITEM 6: captain repro fold (trailing + bare bracket) ==="
  f="$HOME_ROOT/repro.status"
  printf 'blocked: the pipeline daemon is out of credits and the user cannot add credits [key=nm-openai-credits]\n' > "$f"
  echo "trailing-key open:"
  status_open_decisions "$f"
  printf 'resolved [key=nm-openai-credits]: answered: captain refilled\n' >> "$f"
  echo "after canonical resolve:"
  status_open_decisions "$f" | sed 's/^$/<empty>/'
  printf 'needs-decision [died-resume-fold]: reviewer flagged TurnDied double-render\n' > "$f"
  echo "bare-bracket open:"
  status_open_decisions "$f"

  echo
  echo "=== ITEM 6: mid-note prose vs last-token key (captain option A) ==="
  f="$HOME_ROOT/triage.status"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1] in passing\nneeds-decision [key=bad key]: malformed\n' > "$f"
  echo "--- mid-note: resolved: docs still mention [key=q1] in passing ---"
  echo "open set:"
  status_open_decisions "$f" | sed 's/\t/ | /g'
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\n' > "$f"
  echo "--- last-token: resolved: docs still mention [key=q1] ---"
  echo "open set:"
  status_open_decisions "$f" | sed 's/\t/ | /g'
} > "$EVIDENCE_DIR/end-user-surfaces.txt" 2>&1
echo "wrote $EVIDENCE_DIR/end-user-surfaces.txt"
