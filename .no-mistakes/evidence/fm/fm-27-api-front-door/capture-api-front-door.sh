#!/usr/bin/env bash
# Capture reviewer-visible HTTP and lifecycle evidence for the API front door.
# Writes artifacts next to this script. Does not modify the worktree.
set -eu
EVIDENCE_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$EVIDENCE_DIR/../../worktrees/b99440365b40/01M0XTZR91Z8B6K15B0EJ5HNZ2" && pwd)
# Prefer the current worktree if this script is invoked from there.
if [ -x "$PWD/bin/fm-api.sh" ]; then
  ROOT=$PWD
fi
cd "$ROOT"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-api-evidence.XXXXXX")
cleanup() {
  FM_HOME="$WORKDIR/primary/home" "$ROOT/bin/fm-api.sh" stop >/dev/null 2>&1 || true
  FM_HOME="$WORKDIR/session/home" "$ROOT/bin/fm-api.sh" stop >/dev/null 2>&1 || true
  FM_HOME="$WORKDIR/secondmate/home" "$ROOT/bin/fm-api.sh" stop >/dev/null 2>&1 || true
  kill "${HOLDER_PID:-}" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

http_get() {
  local port=$1 path=$2
  node -e '
const http = require("http");
const port = process.argv[1];
const reqPath = process.argv[2];
const req = http.request({ host: "127.0.0.1", port, path: reqPath, method: "GET" }, (res) => {
  const chunks = [];
  res.on("data", (c) => chunks.push(c));
  res.on("end", () => {
    process.stdout.write("HTTP/1.1 " + res.statusCode + "\n");
    for (const [k, v] of Object.entries(res.headers)) process.stdout.write(k + ": " + v + "\n");
    process.stdout.write("\n" + Buffer.concat(chunks).toString("utf8"));
  });
});
req.on("error", (err) => {
  process.stdout.write("CONNECT_FAILED " + err.message + "\n");
  process.exit(0);
});
req.setTimeout(2000, () => { req.destroy(); process.stdout.write("CONNECT_FAILED timeout\n"); });
req.end();
' "$port" "$path"
}

make_home() {
  local dest=$1
  mkdir -p "$dest/state" "$dest/data" "$dest/config"
  printf '0\n' > "$dest/config/api-port"
}

# --- 1. start + health + 404 + malformed URL + stop ------------------------
PRIMARY="$WORKDIR/primary/home"
make_home "$PRIMARY"
{
  echo "=== fm-api.sh start (throwaway home) ==="
  FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start
  echo
  echo "=== persisted state ==="
  echo "port=$(cat "$PRIMARY/state/.api.port")"
  echo "pid=$(cat "$PRIMARY/state/.api.pid")"
  echo "session-pid-file=$(cat "$PRIMARY/state/.api.session-pid")"
  echo "home=$PRIMARY"
} > "$EVIDENCE_DIR/01-start.txt"

PORT=$(cat "$PRIMARY/state/.api.port")
http_get "$PORT" /health > "$EVIDENCE_DIR/02-health.http"
http_get "$PORT" /unknown > "$EVIDENCE_DIR/03-not-found.http"

node -e '
const net = require("net");
const port = Number(process.argv[1]);
const sock = net.connect(port, "127.0.0.1", () => {
  sock.write("GET //[ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
});
const chunks = [];
sock.on("data", (c) => chunks.push(c));
sock.on("error", (err) => { process.stdout.write("CONNECT_FAILED " + err.message + "\n"); });
sock.on("end", () => process.stdout.write(Buffer.concat(chunks).toString("utf8")));
' "$PORT" > "$EVIDENCE_DIR/04-malformed-url.http"

http_get "$PORT" /health > "$EVIDENCE_DIR/05-health-after-malformed.http"

{
  echo "=== fm-api.sh status while running ==="
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-api.sh" status
  echo
  echo "=== fm-api.sh stop ==="
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-api.sh" stop
  echo
  echo "=== health after stop ==="
  http_get "$PORT" /health
  echo
  echo "=== fm-api.sh status after stop ==="
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-api.sh" status
} > "$EVIDENCE_DIR/06-stop.txt"

# --- 2. symlink refusal ----------------------------------------------------
SYMLINK_HOME="$WORKDIR/symlink/home"
make_home "$SYMLINK_HOME"
printf '0\n' > "$SYMLINK_HOME/config/api-port-real"
rm -f "$SYMLINK_HOME/config/api-port"
ln -s "$SYMLINK_HOME/config/api-port-real" "$SYMLINK_HOME/config/api-port"
{
  echo "=== config/api-port is a symlink ==="
  ls -l "$SYMLINK_HOME/config/api-port"
  echo
  echo "=== fm-api.sh start ==="
  set +e
  FM_HOME="$SYMLINK_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-api.sh" start
  status=$?
  set -e
  echo "exit=$status"
  echo "pid-file-exists=$([ -f "$SYMLINK_HOME/state/.api.pid" ] && echo yes || echo no)"
} > "$EVIDENCE_DIR/07-symlink-refusal.txt" 2>&1

# --- 3. session-start primary vs secondmate --------------------------------
# Minimal fixture matching tests/fm-session-start.test.sh API cases.
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

install_fake_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    printf '/usr/local/bin/claude\n'
    ;;
  *)
    printf '%s claude\n' "${pid:-1}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
}

install_real_node() {
  local fakebin=$1 real
  real=$(command -v node)
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$fakebin/node"
}

install_quiet_tools() {
  local fakebin=$1
  for tool in tmux gh treehouse chrome-devtools-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' '0.1.46'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' '0.1.29'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version|-v|-V) printf '%s\n' '0.2.4'; exit 0 ;;
  ready)
    printf 'count: 0\nready[0]{id,state,kind,repo,title}:\nready_public_followups: 0 delivery-ready obligations\nhelp[1]:\n  - none\n'
    exit 0
    ;;
  list)
    printf 'count: 0\ntasks[0]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\nhelp[1]:\n  - none\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

setup_session_world() {
  local dest=$1
  mkdir -p "$dest/home/state" "$dest/home/data" "$dest/home/config" "$dest/fakebin" "$dest/root"
  git init -q -b main "$dest/root"
  git -C "$dest/root" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -q --allow-empty -m init
  printf '0\n' > "$dest/home/config/api-port"
  install_fake_ps "$dest/fakebin"
  install_real_node "$dest/fakebin"
  install_quiet_tools "$dest/fakebin"
}

setup_session_world "$WORKDIR/session"
SESSION_HOME="$WORKDIR/session/home"
SESSION_ROOT="$WORKDIR/session/root"
SESSION_FAKE="$WORKDIR/session/fakebin"

{
  echo "=== locked primary session start (FM_API=1) ==="
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_API=1 FM_HOME="$SESSION_HOME" FM_ROOT_OVERRIDE="$SESSION_ROOT" \
    PATH="$SESSION_FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-session-start.sh" | tee "$WORKDIR/session-out.txt" | grep -E '^(api:|# |● |READ-ONLY)' || true
  echo
  echo "=== api lines from digest ==="
  grep -E '^api:' "$WORKDIR/session-out.txt" || echo "(no api: lines)"
  echo
  echo "=== state after session start ==="
  if [ -f "$SESSION_HOME/state/.api.port" ]; then
    echo "port=$(cat "$SESSION_HOME/state/.api.port")"
    echo "pid=$(cat "$SESSION_HOME/state/.api.pid")"
    PORT2=$(cat "$SESSION_HOME/state/.api.port")
    echo
    echo "=== GET /health after session start ==="
    http_get "$PORT2" /health
  else
    echo "MISSING .api.port"
  fi
} > "$EVIDENCE_DIR/08-session-start-primary.txt" 2>&1

setup_session_world "$WORKDIR/secondmate"
printf 'sm-fixture\n' > "$WORKDIR/secondmate/home/.fm-secondmate-home"
{
  echo "=== secondmate session start (FM_API=1, .fm-secondmate-home present) ==="
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_API=1 FM_HOME="$WORKDIR/secondmate/home" FM_ROOT_OVERRIDE="$WORKDIR/secondmate/root" \
    PATH="$WORKDIR/secondmate/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-session-start.sh" | tee "$WORKDIR/secondmate-out.txt" | grep -E '^(api:|# |● |READ-ONLY)' || true
  echo
  echo "=== api lines from digest ==="
  grep -E '^api:' "$WORKDIR/secondmate-out.txt" || echo "(no api: lines)"
  echo
  echo "=== pid file after secondmate session start ==="
  if [ -f "$WORKDIR/secondmate/home/state/.api.pid" ]; then
    echo "UNEXPECTED pid=$(cat "$WORKDIR/secondmate/home/state/.api.pid")"
  else
    echo "no .api.pid (API not started)"
  fi
} > "$EVIDENCE_DIR/09-session-start-secondmate.txt" 2>&1

# Keep session-start digest excerpts smaller for the PR.
{
  echo "CONTEXT.md is committed at repo root."
  git -C "$ROOT" ls-files CONTEXT.md
  echo
  echo "First 12 lines:"
  sed -n '1,12p' "$ROOT/CONTEXT.md"
} > "$EVIDENCE_DIR/10-context.md.txt"

printf 'evidence capture complete\n'
