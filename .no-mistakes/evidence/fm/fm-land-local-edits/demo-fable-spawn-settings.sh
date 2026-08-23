#!/usr/bin/env bash
# Evidence demo: run the real fm-spawn against a fake pane and capture the
# generated worktree .claude/settings.local.json for Fable vs non-Fable models.
set -eu
ROOT="${1:?repo root}"
EVID="${2:?evidence dir}"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-fable-deny-evidence)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse omp pi opencode claude codex
  printf '%s\n' "$fakebin"
}

spawn_one() {
  local name=$1 model=$2
  local case_dir home proj wt fakebin id out settings
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="demo-$name"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  set +e
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --model "$model" 2>&1
  )
  rc=$?
  set -e
  settings="$wt/.claude/settings.local.json"
  printf '=== spawn %s model=%s exit=%s ===\n' "$name" "$model" "$rc"
  printf '%s\n' "$out"
  printf '\n--- generated %s ---\n' "$settings"
  if [ -f "$settings" ]; then
    python3 -m json.tool "$settings"
    cp "$settings" "$EVID/settings.local.$name.json"
  else
    printf 'MISSING settings.local.json\n'
  fi
  printf '\n'
}

{
  spawn_one fable claude-fable-5
  spawn_one sonnet claude-sonnet-5
} > "$EVID/fable-spawn-settings-transcript.txt"
