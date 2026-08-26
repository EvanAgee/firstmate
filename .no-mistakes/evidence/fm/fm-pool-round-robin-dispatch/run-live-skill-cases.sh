#!/usr/bin/env bash
# Manual evidence for quota-array-dispatch round-robin selection.
# Same public Pi skill-loading interface as tests/fm-quota-array-dispatch-live-e2e.test.sh,
# but uses an authenticated model available in this environment.
set -u
ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0ZBGE371TMD4EA2400QJCFM"
EVID="/Users/evanagee/.no-mistakes/evidence/01M0ZBGE371TMD4EA2400QJCFM"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-evidence.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
CALLS="$LAB/quota-axi.calls"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN" "$EVID"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != --json ] || [ "$#" -ne 1 ]; then
  printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

run_case() {
  local slug=$1 expected=$2 live_counts=$3 prompt=$4
  shift 4
  local composed out calls status required
  if [ -n "$live_counts" ]; then
    composed="Live workers already dispatched from this same pool in this home: ${live_counts}. ${prompt}"
  else
    composed=$prompt
  fi
  : > "$CALLS"
  echo "=== CASE $slug ===" | tee -a "$EVID/live-skill-transcript.txt"
  echo "expected: $expected" | tee -a "$EVID/live-skill-transcript.txt"
  echo "live_counts: ${live_counts:-(none)}" | tee -a "$EVID/live-skill-transcript.txt"
  set +e
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openrouter/openai/gpt-5.6-sol --thinking high \
          "$composed"
  )
  status=$?
  set -e
  calls=$(cat "$CALLS" 2>/dev/null || true)
  {
    echo "exit: $status"
    echo "quota-axi calls:"
    printf '%s\n' "$calls"
    echo "--- agent output ---"
    printf '%s\n' "$out"
    echo "--- end ---"
  } | tee -a "$EVID/live-skill-transcript.txt"
  printf '%s\n' "$out" > "$EVID/live-skill-${slug}.out"
  if [ "$status" -ne 0 ]; then
    echo "FAIL $slug: pi exited $status" | tee -a "$EVID/live-skill-transcript.txt"
    return 1
  fi
  [ "$calls" = "--json" ] || { echo "FAIL $slug: quota-axi calls were: $calls" | tee -a "$EVID/live-skill-transcript.txt"; return 1; }
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || { echo "FAIL $slug: missing $expected" | tee -a "$EVID/live-skill-transcript.txt"; return 1; }
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || { echo "FAIL $slug: missing $required" | tee -a "$EVID/live-skill-transcript.txt"; return 1; }
  done
  echo "PASS $slug" | tee -a "$EVID/live-skill-transcript.txt"
}

: > "$EVID/live-skill-transcript.txt"

cat > "$FIXTURE" <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]},"effectivePace":[{"scope":"all_models","pace":"ahead","worstReservePercentPoints":-1}]},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]},"effectivePace":[{"scope":"all_models","pace":"ahead","worstReservePercentPoints":-40}]}]}
JSON

run_case \
  "fewest-live-beats-headroom" \
  "SELECTED=claude" \
  "claude=0,codex=3" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|live=0|headroom=1|runway_seconds=10800|reserve=-1 and FACT=codex|live=3|headroom=55|runway_seconds=14400|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|live=0|headroom=1|runway_seconds=10800|reserve=-1" \
  "FACT=codex|live=3|headroom=55|runway_seconds=14400|reserve=-40"

run_case \
  "equal-live-tie-headroom" \
  "SELECTED=codex" \
  "claude=0,codex=0" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|live=0|headroom=1|runway_seconds=10800|reserve=-1 and FACT=codex|live=0|headroom=55|runway_seconds=14400|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|live=0|headroom=1|runway_seconds=10800|reserve=-1" \
  "FACT=codex|live=0|headroom=55|runway_seconds=14400|reserve=-40"

cat > "$FIXTURE" <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"unknown","unmeasurableWindowIds":["weekly"]}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON

run_case \
  "unmeasurable-runway-headroom-tie" \
  "DECISION=CLAUDE" \
  "claude=0,codex=0" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but explicitly unmeasurable runway, while Codex has lower known headroom and established runway that supports completion. Unmeasurable runway does not drop a member; both stay eligible and the uncertainty must be disclosed. Return exact lines FACT=claude|eligible=yes|live=0|headroom=55|runway=unknown|unmeasurable=weekly and FACT=codex|eligible=yes|live=0|headroom=45|runway_seconds=14400|supports_horizon=yes, then an exact final line DECISION=<CLAUDE|CODEX>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|eligible=yes|live=0|headroom=55|runway=unknown|unmeasurable=weekly" \
  "FACT=codex|eligible=yes|live=0|headroom=45|runway_seconds=14400|supports_horizon=yes"

cat > "$FIXTURE" <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"2030-01-01T08:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON

run_case \
  "strongest-reasoning-class" \
  "SELECTED=claude" \
  "" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement. Return exact lines FACT=claude|reasoning=required|headroom=1|runway_seconds=10800 and FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=required|headroom=1|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800"

echo "ALL LIVE SKILL CASES PASSED" | tee -a "$EVID/live-skill-transcript.txt"
