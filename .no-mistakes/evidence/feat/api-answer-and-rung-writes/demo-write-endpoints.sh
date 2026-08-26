#!/usr/bin/env bash
# Manual product-level demo of POST /decisions/answer and POST /rigs/rung.
# Speaks real HTTP against a throwaway firstmate home, same as the dashboard.
set -eu
ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M1015Y99ACE6QY71N4PP4FD6"
EVIDENCE="/Users/evanagee/.no-mistakes/evidence/01M1015Y99ACE6QY71N4PP4FD6"
. "$ROOT/tests/api-helpers.sh"

OUT="$EVIDENCE/write-endpoints-transcript.txt"
: > "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT"; }
section() { log ""; log "======== $* ========"; }

home=$(fm_test_api_home api-write-demo)
printf 'needs-decision: which target? [key=deploy-target]\n' > "$home/state/sample-task.status"
mkdir -p "$home/config"
cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {
      "when": "builder class: ordinary",
      "use": [
        { "harness": "codex", "model": "gpt-5.6", "effort": "high" },
        { "harness": "claude", "model": "opus", "effort": "high" }
      ]
    }
  ],
  "default": [
    { "harness": "codex", "model": "gpt-5.5", "effort": "medium" },
    { "harness": "pi", "model": "anthropic/claude-sonnet-5", "effort": "medium" }
  ]
}
EOF

port=$(fm_test_api_start "$home")
token=$(fm_test_api_token "$home")

log "home=$home"
log "port=$port"
log "token_present=$([ -n "$token" ] && echo yes || echo no)"

hit() {
  local label=$1 path=$2 method=$3 auth=$4 body=$5
  local resp code body_out
  section "$label"
  log "REQUEST $method $path"
  if [ -n "$auth" ]; then
    log "Authorization: Bearer <redacted>"
  else
    log "Authorization: (none)"
  fi
  log "Body: $body"
  HTTP_BODY=$body HTTP_AUTHORIZATION=$auth \
    resp=$(fm_test_api_http "$port" "$path" "$method")
  code=$(printf '%s\n' "$resp" | sed -n '1p')
  body_out=$(printf '%s\n' "$resp" | sed '1d')
  log "STATUS $code"
  log "RESPONSE $body_out"
}

hit "answer without token" /decisions/answer POST "" \
  '{"task":"sample-task","key":"deploy-target","text":"ship to prod"}'
hit "answer with wrong token" /decisions/answer POST "Bearer definitely-not-the-token" \
  '{"task":"sample-task","key":"deploy-target","text":"ship to prod"}'
hit "answer unknown task" /decisions/answer POST "Bearer $token" \
  '{"task":"ghost-task","key":"deploy-target","text":"ship to prod"}'
hit "answer with token" /decisions/answer POST "Bearer $token" \
  '{"task":"sample-task","key":"deploy-target","text":"ship to prod"}'

section "wake queue after authorized answer"
if [ -f "$home/state/.wake-queue" ]; then
  cp "$home/state/.wake-queue" "$EVIDENCE/wake-queue-after-answer.txt"
  log "persisted $home/state/.wake-queue:"
  cat "$home/state/.wake-queue" | tee -a "$OUT"
  encoded=$(awk -F '\t' '{print $4}' "$home/state/.wake-queue" | sed 's/^check: decision-answer: //')
  log ""
  log "decoded operational-input payload:"
  printf '%s' "$encoded" | "$ROOT/bin/fm-operational-input.sh" decode 2>/dev/null | tee -a "$OUT" || log "(decode failed)"
else
  log "MISSING wake queue"
fi

hit "GET /rigs (shape the dashboard already consumes)" /rigs GET "" ""

section "crew-dispatch.json before rung writes"
cp "$home/config/crew-dispatch.json" "$EVIDENCE/crew-dispatch-before.json"
cat "$home/config/crew-dispatch.json" | tee -a "$OUT"

hit "rung toggle without token" /rigs/rung POST "" \
  '{"rig":"builder class: ordinary","rung":1,"enabled":false}'
hit "turn off rung 1 (authorized)" /rigs/rung POST "Bearer $token" \
  '{"rig":"builder class: ordinary","rung":1,"enabled":false}'

section "crew-dispatch.json after turning off rung 1"
cp "$home/config/crew-dispatch.json" "$EVIDENCE/crew-dispatch-rung1-off.json"
cat "$home/config/crew-dispatch.json" | tee -a "$OUT"

hit "turn rung 1 back on" /rigs/rung POST "Bearer $token" \
  '{"rig":"builder class: ordinary","rung":1,"enabled":true}'
hit "turn off rung 0 so rung 1 is last on" /rigs/rung POST "Bearer $token" \
  '{"rig":"builder class: ordinary","rung":0,"enabled":false}'
hit "refuse last enabled rung" /rigs/rung POST "Bearer $token" \
  '{"rig":"builder class: ordinary","rung":1,"enabled":false}'

section "crew-dispatch.json after last-rung refusal (must still have rung 1 on)"
cp "$home/config/crew-dispatch.json" "$EVIDENCE/crew-dispatch-after-last-rung-refusal.json"
cat "$home/config/crew-dispatch.json" | tee -a "$OUT"

hit "toggle default ladder rung 0" /rigs/rung POST "Bearer $token" \
  '{"rig":"default","rung":0,"enabled":false}'

section "crew-dispatch.json after default ladder toggle"
cp "$home/config/crew-dispatch.json" "$EVIDENCE/crew-dispatch-default-rung0-off.json"
cat "$home/config/crew-dispatch.json" | tee -a "$OUT"

fm_test_api_stop "$home"
log ""
log "demo complete"
