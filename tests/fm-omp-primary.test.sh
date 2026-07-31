#!/usr/bin/env bash
# OMP primary identity and native extension behavior tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-primary)
trap 'rm -rf "$TMP_ROOT"' EXIT
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_process_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
self_dir=$(cd "$(dirname "$0")" && pwd)
case "$pid:$field" in
  700:comm=) printf '%s\n' "${FM_TEST_OMP_COMM:-bun}" ;;
  700:args=)
    case "${FM_TEST_OMP_SHAPE:-exact}" in
      exact) printf '%s %s\n' "$self_dir/bun" "$self_dir/omp --model openai-codex/gpt-5.6-sol" ;;
      helper) printf '%s %s\n' "$self_dir/bun" "$self_dir/omp-helper --model test" ;;
      prefixed) printf '%s %s\n' "$self_dir/bun" "$self_dir/xomp --model test" ;;
      incidental) printf '%s %s\n' "$self_dir/bun" "$self_dir/tool.js --label omp" ;;
    esac
    ;;
  700:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash -c firstmate-tool' ;;
  *:ppid=) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
self_dir=$(cd "$(dirname "$0")" && pwd)
printf 'n%s/bun\n' "$self_dir"
SH
  chmod +x "$fakebin/lsof"
  for name in bun omp omp-helper xomp tool.js; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$name"
    chmod +x "$fakebin/$name"
  done
  printf '%s\n' "$fakebin"
}

test_resolve_path_uses_node_when_readlink_f_is_unavailable() {
  local fixture fakebin expected resolved
  fixture="$TMP_ROOT/resolve-path"
  fakebin=$(fm_fakebin "$fixture")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/target"
  chmod +x "$fixture/target"
  ln -s "$fixture/target" "$fixture/link"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/readlink"
  chmod +x "$fakebin/readlink"
  expected=$(fm_test_realpath "$fixture/link")
  resolved=$(PATH="$fakebin:$(dirname "$(command -v node)"):$BASE_PATH" \
    bash -c '. "$0/bin/fm-omp-process-lib.sh"; fm_omp_process_resolve_path "$1"' \
      "$ROOT" "$fixture/link") || fail "Node realpath fallback did not resolve a symlink"
  [ "$resolved" = "$expected" ] \
    || fail "Node realpath fallback returned '$resolved', expected '$expected'"
  pass "OMP path resolution stays canonical when readlink -f is unavailable"
}

test_exact_bun_omp_primary_identity() {
  local fakebin got shape
  fakebin=$(make_process_fakebin "$TMP_ROOT/process")
  export FM_OMP_PROCESS_EXPECTED_BUN="$fakebin/bun"
  export FM_OMP_PROCESS_EXPECTED_BIN="$fakebin/omp"

  got=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$got" = 700 ] || fail "exact bun-launched OMP ancestry resolved '$got', expected 700"
  PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 700' "$ROOT" \
    || fail "exact bun-launched OMP lock owner was rejected"

  got=$(PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$got" = omp ] || fail "exact OMP ancestry did not outrank inherited foreign markers: $got"

  got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$got" = 700 ] || fail "OMP process-title comm with exact Bun argv resolved '$got', expected 700"
  PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 700' "$ROOT" \
    || fail "OMP process-title comm with exact Bun argv was rejected"

  for shape in helper prefixed incidental; do
    if PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_SHAPE="$shape" bash -c \
      '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 700' "$ROOT"; then
      fail "inexact bun OMP shape was accepted: $shape"
    fi
    got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_SHAPE="$shape" \
      PI_CODING_AGENT=true CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
    [ "$got" != omp ] || fail "inexact OMP ancestry was classified as OMP: $shape"
    if PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp FM_TEST_OMP_SHAPE="$shape" bash -c \
      '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 700' "$ROOT"; then
      fail "OMP process-title comm bypassed the Bun argv boundary: $shape"
    fi
  done
  unset FM_OMP_PROCESS_EXPECTED_BUN FM_OMP_PROCESS_EXPECTED_BIN
  pass "OMP primary identity requires launch-bound Bun and OMP realpaths plus the exact argv boundary"
}

test_primary_scope_allows_only_absent_canonical_state() {
  local fixture external out
  fixture="$TMP_ROOT/fresh-primary-scope"
  external="$TMP_ROOT/external-state"
  mkdir -p "$fixture/bin" "$external"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  FM_TEST_ROOT="$fixture" FM_TEST_STATE="$fixture/state" bash -c \
    '. "$0/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_TEST_ROOT" "$FM_TEST_STATE"' "$ROOT" \
    || fail "fresh plain checkout did not admit its absent canonical state path"
  [ ! -e "$fixture/state" ] || fail "primary scope predicate created state instead of leaving creation to the extension core"
  if FM_TEST_ROOT="$fixture" FM_TEST_STATE="$external/missing" bash -c \
    '. "$0/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_TEST_ROOT" "$FM_TEST_STATE"' "$ROOT"; then
    fail "primary scope accepted an absent state override outside the checkout"
  fi
  ln -s "$external" "$fixture/state"
  if FM_TEST_ROOT="$fixture" FM_TEST_STATE="$fixture/state" bash -c \
    '. "$0/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_TEST_ROOT" "$FM_TEST_STATE"' "$ROOT"; then
    fail "primary scope accepted a symlinked canonical state path"
  fi
  rm "$fixture/state"
  mkdir -p "$fixture/.omp/extensions" "$fixture/state"
  printf 'marker-target-must-stay-unchanged\n' > "$external/marker-target"
  ln -s "$external/marker-target" "$fixture/state/.omp-primary-extension-loaded"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" node --input-type=module 2>&1 <<'JS'
import { lstatSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
process.argv[1] = process.execPath;
let registrations = 0;
const api = {
  zod: { object: () => ({}) },
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?fresh=${Date.now()}`);
extension.default(api);
const marker = `${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`;
const lines = readFileSync(marker, "utf8").trim().split("\n");
if (registrations < 8) throw new Error(`fresh extension registered only ${registrations} lifecycle surfaces`);
if (lines.length !== 4 || lines[1] !== String(process.pid)) throw new Error(`fresh marker shape ${lines.join("|")}`);
if (!lstatSync(marker).isFile() || lstatSync(marker).isSymbolicLink()) throw new Error("primary marker remained a symlink");
if (readFileSync(`${process.env.FM_HOME}/../external-state/marker-target`, "utf8") !== "marker-target-must-stay-unchanged\n") {
  throw new Error("primary marker publication overwrote the symlink target");
}
console.log("fresh-lifecycle-ok");
JS
  ) || fail "fresh plain-checkout OMP primary lifecycle did not initialize: $out"
  assert_contains "$out" fresh-lifecycle-ok "fresh OMP lifecycle did not publish its four-line identity marker"
  pass "OMP fresh primary lifecycle creates canonical state and atomically replaces a marker symlink without following it"
}

test_primary_marker_refuses_whitespace_identity() {
  local fixture entry out
  fixture="$TMP_ROOT/whitespace-primary"
  entry="$fixture/omp entry.ts"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/state"
  cp "$ROOT/AGENTS.md" "$fixture/AGENTS.md"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  : > "$entry"
  git init -q -b main "$fixture"
  set +e
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" OMP_ENTRY="$entry" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
process.argv[1] = process.env.OMP_ENTRY;
const api = {
  zod: { object: () => ({}) },
  on() {},
  registerCommand() {},
  registerTool() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?space=${Date.now()}`);
extension.default(api);
JS
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "OMP primary marker accepted a whitespace-bearing entrypoint"
  assert_contains "$out" 'OMP primary identity paths containing whitespace are unsupported' \
    "OMP primary whitespace refusal was not actionable"
  [ ! -e "$fixture/state/.omp-primary-extension-loaded" ] \
    || fail "OMP primary published a marker for a whitespace-bearing identity"
  pass "OMP primary refuses whitespace-bearing identity before marker publication"
}

test_native_primary_extension_contract() {
  local fixture inert out status
  fixture="$TMP_ROOT/extension"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/home/state" "$fixture/home/config"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cat > "$fixture/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_is_gate_agent() { [ "${FM_TEST_GATE_AGENT:-0}" = 1 ]; }
SH
  cat > "$fixture/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { [ "${FM_TEST_PRIMARY_SCOPE:-1}" = 1 ]; }
SH
  cat > "$fixture/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
kind=$2
content=$(cat)
printf 'encoded:%s:%s' "$kind" "$content"
SH
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
[ -e "${FM_STATE_OVERRIDE:?}/.lock" ] || printf 'OMP_PRIMARY_STARTUP_NUDGE\n'
SH
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
[ ! -e "$state/watch-trigger-consumed" ] || : > "$state/watch-successor-ready"
printf 'watcher: started pid=%s\n' "$$"
trap 'exit 0' TERM INT
if [ ! -e "$state/watch-trigger-consumed" ]; then
  while [ ! -e "$state/watch-trigger" ]; do sleep 0.02; done
  mv "$state/watch-trigger" "$state/watch-trigger-consumed"
  printf 'signal: omp-actionable\n'
  exit 0
fi
while :; do sleep 1; done
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "${FM_TEST_GUARD_PAYLOADS:?}"
printf 'guard says supervision is absent\n' >&2
exit 2
SH
  cat > "$fixture/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" != task ] || { printf 'delegation denied\n' >&2; exit 2; }
exit 0
SH
  cat > "$fixture/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *'cd projects/'*) printf 'directory denied\n' >&2; exit 2 ;; esac
exit 0
SH
  cat > "$fixture/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *fm-watch-arm.sh*) printf 'watcher arm denied\n' >&2; exit 2 ;; esac
exit 0
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FIXTURE="$fixture" \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    FM_TEST_GUARD_PAYLOADS="$fixture/guard-payloads" FM_OMP_ARM_READY_TIMEOUT_MS=500 \
    FM_OMP_SESSION_POINTER="$fixture/home/state/.omp-session" \
    node --input-type=module 2>&1 <<'JS'
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const commands = new Map();
const tools = new Map();
const customMessages = [];
const userMessages = [];
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand(name, value) { commands.set(name, value); },
  registerTool(value) { tools.set(value.name, value); },
  sendMessage(message) { customMessages.push(message); },
  sendUserMessage(content, options) { userMessages.push({ content, options }); },
};
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?test=${Date.now()}`);
await extension.default(api);
for (const required of ["session_start", "session_switch", "before_agent_start", "session_stop", "tool_call", "session_shutdown"]) {
  if (!handlers.has(required)) throw new Error(`missing OMP native handler ${required}`);
}
if (!commands.has("fm-watch-arm-omp") || !tools.has("fm_watch_arm_omp")) {
  throw new Error("OMP watcher arm command/tool was not registered");
}

const marker = `${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`;
const expectedVersion = `sha256:${createHash("sha256").update(readFileSync(process.env.EXTENSION)).digest("hex")}`;
let markerLines = readFileSync(marker, "utf8").trim().split("\n");
if (markerLines.length !== 4 || markerLines[0] !== expectedVersion || markerLines[1] !== String(process.pid)) {
  throw new Error(`invalid OMP primary marker ${markerLines.join("|")}`);
}
const extensionContext = { sessionManager: { getSessionFile: () => `${process.env.FIXTURE}/omp-session.jsonl` } };
await handlers.get("session_start")({ type: "session_start" }, extensionContext);
if (readFileSync(process.env.FM_OMP_SESSION_POINTER, "utf8").trim() !== `${process.env.FIXTURE}/omp-session.jsonl`) {
  throw new Error("OMP primary integration did not publish the exact secondmate session pointer");
}
const startup = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (startup?.message?.customType !== "firstmate-sessionstart-nudge" || startup.message.content !== "OMP_PRIMARY_STARTUP_NUDGE" || startup.message.attribution !== "agent") {
  throw new Error(`startup nudge was not bound to the first provider turn: ${JSON.stringify(startup)}`);
}
if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("startup nudge repeated within one OMP session");
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, extensionContext);
const newStartup = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (newStartup?.message?.customType !== "firstmate-sessionstart-nudge" || newStartup.message.attribution !== "agent") {
  throw new Error(`in-process OMP /new lost its once-only startup instruction: ${JSON.stringify(newStartup)}`);
}
if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("in-process OMP /new repeated its startup instruction");
}
await handlers.get("session_switch")({ type: "session_switch", reason: "resume" }, extensionContext);
const resumeStartup = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (resumeStartup?.message?.customType !== "firstmate-sessionstart-nudge" || resumeStartup.message.attribution !== "agent") {
  throw new Error(`in-process OMP /resume lost its once-only startup instruction: ${JSON.stringify(resumeStartup)}`);
}
if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("in-process OMP /resume repeated its startup instruction");
}

const signal = new AbortController().signal;
const stop = await handlers.get("session_stop")({
  type: "session_stop",
  messages: [],
  turn_id: 1,
  session_id: "omp-session",
  stop_hook_active: false,
  signal,
});
if (stop?.continue !== true || !stop.additionalContext.includes("encoded:turn-end-guard:TURN WOULD END BLIND")) {
  throw new Error(`OMP session_stop did not request one guarded continuation: ${JSON.stringify(stop)}`);
}
const bounded = await handlers.get("session_stop")({
  type: "session_stop",
  messages: [],
  turn_id: 2,
  session_id: "omp-session",
  stop_hook_active: true,
  signal,
});
if (bounded !== undefined) throw new Error("OMP session_stop recursed after stop_hook_active");

const delegation = await handlers.get("tool_call")({ type: "tool_call", toolName: "task", input: {} });
if (delegation?.block !== true || !delegation.reason.includes("delegation denied")) {
  throw new Error("OMP delegation-shaped tool was not blocked");
}
const directory = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "cd projects/demo" } });
if (directory?.block !== true || !directory.reason.includes("directory denied")) {
  throw new Error("OMP persistent directory change was not blocked");
}
const foregroundArm = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh" } });
if (foregroundArm?.block !== true || !foregroundArm.reason.includes("watcher arm denied")) {
  throw new Error("OMP foreground watcher arm was not blocked");
}

const toolResult = await tools.get("fm_watch_arm_omp").execute();
if (!toolResult.details.ok || !toolResult.content[0].text.includes("OMP extension")) {
  throw new Error(`OMP watcher tool did not route through the shared core: ${JSON.stringify(toolResult)}`);
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-trigger`, "go\n");
for (let i = 0; i < 100 && userMessages.length === 0; i += 1) {
  await new Promise(resolve => setTimeout(resolve, 20));
}
if (userMessages.length !== 1 || !userMessages[0].content.includes("signal: omp-actionable")) {
  throw new Error(`OMP actionable watcher close was not delivered once: ${JSON.stringify(userMessages)}`);
}
if (!existsSync(`${process.env.FM_STATE_OVERRIDE}/watch-successor-ready`)) {
  throw new Error("OMP actionable notification arrived before successor readiness");
}
await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
await new Promise(resolve => setTimeout(resolve, 80));
console.log(JSON.stringify({ startupMessages: 3, guarded: true, tools: tools.size, userMessages: userMessages.length, customMessages: customMessages.length }));
JS
)
  status=$?
  expect_code 0 "$status" "OMP native primary extension contract"
  assert_contains "$out" '"startupMessages":3' "OMP primary runtime result lost once-only startup delivery across start, new, and resume"
  assert_contains "$out" '"guarded":true' "OMP primary runtime result lost stop guard evidence"

  rm -f "$fixture/home/state/.omp-primary-extension-loaded"
  inert=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_TEST_PRIMARY_SCOPE=0 \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
let handlers = 0;
let tools = 0;
const api = {
  zod: { object: () => ({}) },
  on() { handlers += 1; },
  registerCommand() { tools += 1; },
  registerTool() { tools += 1; },
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?inert=${Date.now()}`);
extension.default(api);
if (handlers !== 0 || tools !== 0) throw new Error(`out-of-scope adapter registered handlers=${handlers} tools=${tools}`);
if (existsSync(`${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`)) {
  throw new Error("out-of-scope adapter published a primary loaded marker");
}
console.log("inert-scope-ok");
JS
)
  status=$?
  expect_code 0 "$status" "OMP native extension primary-scope guard"
  assert_contains "$inert" "inert-scope-ok" "OMP linked-task scope did not stay inert"

  inert=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_TEST_GATE_AGENT=1 \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
let registrations = 0;
const api = {
  zod: { object: () => ({}) },
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?gate=${Date.now()}`);
extension.default(api);
if (registrations !== 0) throw new Error(`gate-agent adapter registered ${registrations} surfaces`);
if (existsSync(`${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`)) {
  throw new Error("gate-agent adapter published a primary loaded marker");
}
console.log("inert-gate-ok");
JS
)
  status=$?
  expect_code 0 "$status" "OMP native extension gate-agent guard"
  assert_contains "$inert" "inert-gate-ok" "OMP gate-agent scope did not stay inert"
  pass "OMP native extension binds startup, guarded stop, watcher, safety, marker, and shutdown surfaces"
}

test_resolve_path_uses_node_when_readlink_f_is_unavailable
test_exact_bun_omp_primary_identity
test_primary_scope_allows_only_absent_canonical_state
test_primary_marker_refuses_whitespace_identity
test_native_primary_extension_contract
