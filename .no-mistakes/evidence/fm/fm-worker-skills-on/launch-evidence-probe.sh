#!/usr/bin/env bash
set -u
export PROBE_ROOT=$1
EVIDENCE=$2
probe_owns_tmp=0
if [ -z "${PROBE_TMPDIR:-}" ]; then
  PROBE_TMPDIR=$(mktemp -d /tmp/fm-launch-evidence.XXXXXX) || exit 1
  probe_owns_tmp=1
fi
export TMPDIR="$PROBE_TMPDIR"
# Reuse only the existing fixture definitions, then execute the public spawn CLI.
awk '/^test_no_profile_keeps_claude_profile_defaults\(\)/ {exit} {print}' \
  "$PROBE_ROOT/tests/fm-spawn-dispatch-profile.test.sh" |
  sed 's|\. "$(dirname "${BASH_SOURCE\[0\]}")/lib.sh"|. "$PROBE_ROOT/tests/lib.sh"|' > "$TMPDIR/launch-fixtures.sh"
. "$TMPDIR/launch-fixtures.sh"
probe_cleanup() {
  cleanup
  fm_test_cleanup
  [ "$probe_owns_tmp" -eq 0 ] || rm -rf "$PROBE_TMPDIR"
}
trap probe_cleanup EXIT
TRANSCRIPT="$EVIDENCE/worker-launch-transcript.txt"
[ "${PROBE_RESUME:-0}" = 1 ] || printf 'Real fm-spawn CLI with fixture terminal and worker binaries. Commands below were captured at terminal delivery; no live model was started.\n' > "$TRANSCRIPT"
for scenario in ${PROBE_SCENARIOS:-claude pi pi-signed omp omp-fallback codex grok cursor muse opencode one-missing both-missing raw secondmate}; do
  harness=$scenario
  case "$scenario" in omp-fallback) harness=omp ;; one-missing|both-missing|raw|secondmate) harness=claude ;; esac
  id=$(profile_id "profile-evidence-$scenario")
  rec=$(make_spawn_case "evidence-$scenario" "$harness" "$id") || exit 1
  read_case_record "$rec"
  if [ "$harness" = muse ]; then
    fm_fake_exit0 "$FAKEBIN_DIR" muse
    mkdir -p "$CASE_DIR/worker-home/.config/muse" "$CASE_DIR/worker-home/.local/share"
    printf '{"schema_version":1}\n' > "$CASE_DIR/worker-home/.config/muse/auth.json"
  fi
  case "$scenario" in
    one-missing) rm "$CASE_DIR/worker-home/.agents/skills/ponytail/SKILL.md" ;;
    both-missing) rm "$CASE_DIR/worker-home/.agents/skills/ponytail/SKILL.md" "$CASE_DIR/worker-home/.agents/skills/caveman/SKILL.md" ;;
  esac
  export FM_TEST_KEEP_TASK_TMP=1
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  export FM_TEST_OMP_APPEND=yes
  [ "$scenario" != omp-fallback ] || export FM_TEST_OMP_APPEND=no
  case "$scenario" in
    raw) out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 'custom-agent --flag') ;;
    secondmate)
      make_seeded_secondmate_home "$CASE_DIR/secondmate-home" "$id"
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$CASE_DIR/secondmate-home" --secondmate) ;;
    *) out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") ;;
  esac
  rc=$?
  [ "$rc" -eq 0 ] || fail "$scenario evidence launch failed: $out"
  tasktmp="/tmp/fm-$id"
  {
    printf '\nScenario: %s\nCLI response:\n%s\nTerminal command:\n' "$scenario" "$out"
    cat "$LAUNCH_LOG"
    for generated in "$tasktmp"/worker-skills.???????? "$tasktmp"/brief.????????; do
      [ -f "$generated" ] || continue
      printf 'Delivered file: %s\n' "$generated"
      cat "$generated"
    done
    printf 'Persisted launch identity:\n'
    sed -n '/^kind=/p; /^harness=/p; /^model=/p; /^tasktmp=/p' "$HOME_DIR/state/$id.meta"
  } >> "$TRANSCRIPT"
  case "$scenario" in
    one-missing|both-missing)
      [ "$(printf '%s\n' "$out" | grep -c '^SKILLS:')" -eq 1 ] || fail 'missing skills must have one diagnostic' ;;
    raw)
      [ "$(cat "$LAUNCH_LOG")" = 'custom-agent --flag' ] || fail 'raw launch changed' ;;
    secondmate)
      assert_no_grep 'append-system-prompt' "$LAUNCH_LOG" 'secondmate got worker injection' ;;
  esac
  rm -rf "$tasktmp"
  printf 'Captured %s launch\n' "$scenario"
done
for variant in ship scout secondmate; do
  id="evidence-$variant"
  home="$TMP_ROOT/generated-$variant"
  mkdir -p "$home/data"
  case "$variant" in
    ship) FM_HOME="$home" /bin/bash "$ROOT/bin/fm-brief.sh" "$id" sample --mode no-mistakes ;;
    scout) FM_HOME="$home" /bin/bash "$ROOT/bin/fm-brief.sh" "$id" sample --scout ;;
    secondmate) FM_HOME="$home" FM_SECONDMATE_CHARTER=sample /bin/bash "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects ;;
  esac || exit 1
  cp "$home/data/$id/brief.md" "$EVIDENCE/generated-$variant-brief.md" || exit 1
done
