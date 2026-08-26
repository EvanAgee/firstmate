#!/usr/bin/env bash
# fm-api.sh - start, stop, and inspect firstmate's localhost API server.
#
# Usage:
#   fm-api.sh start     start or attach to this home's API; print one status line
#   fm-api.sh stop      stop this home's API if it is ours
#   fm-api.sh status    print running or stopped
#   fm-api.sh --help    print this usage
#
# The server binds 127.0.0.1 only. Port comes from FM_API_PORT, else the first
# non-empty non-comment line of config/api-port, else 18787. Port 0 asks the
# kernel for an ephemeral port. The served home is the resolved FM_HOME; there
# are no hardcoded filesystem paths. bin/fm-api-server.mjs is the Node process.
# This wrapper owns pid identity, attach, and stop.
#
# start attaches only when the recorded session pid is the current live lock
# holder; otherwise it stops the old process and starts one this session owns.
# Stop is explicit. A session-bound server stays up while state/.lock names a
# live holder and exits when there is no live holder.
#
# State files under $STATE, owned here:
#   .api.pid .api.pid-identity .api.port .api.session-pid .api.log .api.lock
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SERVER="$SCRIPT_DIR/fm-api-server.mjs"
DEFAULT_PORT=18787
START_TIMEOUT=${FM_API_START_TIMEOUT:-5}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PID_FILE="$STATE/.api.pid"
IDENTITY_FILE="$STATE/.api.pid-identity"
PORT_FILE="$STATE/.api.port"
SESSION_PID_FILE="$STATE/.api.session-pid"
LOG_FILE="$STATE/.api.log"
LOCK_DIR="$STATE/.api.lock"

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'api: FAILED - %s\n' "$1" >&2
  exit 1
}

read_port_config() {
  local line
  [ -f "$CONFIG/api-port" ] || return 0
  [ -L "$CONFIG/api-port" ] && die "config/api-port must not be a symlink"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/api-port"
}

resolve_port() {
  local port=${FM_API_PORT:-}
  if [ -z "$port" ]; then
    port=$(read_port_config) || port=
  fi
  port=${port:-$DEFAULT_PORT}
  case "$port" in
    ''|*[!0-9]*) die "port must be an integer: $port" ;;
  esac
  if [ "$port" -gt 65535 ]; then
    die "port out of range: $port"
  fi
  printf '%s\n' "$port"
}

node_ok() {
  local out
  command -v node >/dev/null 2>&1 || return 1
  out=$(node -e 'process.stdout.write("fm-api-node-ok")' 2>/dev/null) || return 1
  [ "$out" = "fm-api-node-ok" ]
}

recorded_pid() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

pid_command() {
  local pid=$1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline"
    return 0
  fi
  /bin/ps -p "$pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//'
}

pid_is_ours() {
  local pid=$1 identity current cmd
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$IDENTITY_FILE" 2>/dev/null) || identity=
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || current=
    if [ -n "$current" ]; then
      [ "$current" = "$identity" ]
      return
    fi
  fi
  cmd=$(pid_command "$pid") || return 1
  case "$cmd" in
    *fm-api-server.mjs*) return 0 ;;
  esac
  return 1
}

health_ok() {
  local port=$1
  node -e '
const http = require("http");
const port = process.argv[1];
const req = http.get({ host: "127.0.0.1", port, path: "/health" }, (res) => {
  process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on("error", () => process.exit(1));
req.setTimeout(1000, () => {
  req.destroy();
  process.exit(1);
});
' "$port" >/dev/null 2>&1
}

bound_port() {
  local port
  port=$(cat "$PORT_FILE" 2>/dev/null) || return 1
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$port"
}

clear_records() {
  rm -f "$PID_FILE" "$IDENTITY_FILE" "$PORT_FILE" "$SESSION_PID_FILE"
}

session_lock_pid() {
  local pid
  [ -f "$STATE/.lock" ] || return 1
  pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

recorded_session_pid() {
  local pid
  pid=$(cat "$SESSION_PID_FILE" 2>/dev/null) || pid=
  case "$pid" in
    ''|*[!0-9]*) pid= ;;
  esac
  printf '%s\n' "$pid"
}

api_is_attachable() {
  local pid=$1 bound recorded current
  pid_is_ours "$pid" || return 1
  bound=$(bound_port) || return 1
  [ -n "$bound" ] || return 1
  health_ok "$bound" || return 1
  recorded=$(recorded_session_pid)
  current=$(session_lock_pid) || current=
  [ "$recorded" = "$current" ]
}

api_status_line() {
  local kind=$1 pid port home
  pid=$(recorded_pid) || pid='?'
  port=$(bound_port) || port='?'
  home=$(cd "$FM_HOME" && pwd)
  printf 'api: %s pid=%s port=%s home=%s\n' "$kind" "$pid" "$port" "$home"
}

cmd_status() {
  local pid port
  pid=$(recorded_pid) || pid=
  if [ -n "$pid" ] && pid_is_ours "$pid"; then
    port=$(bound_port) || port=
    if [ -n "$port" ] && health_ok "$port"; then
      api_status_line running
      return 0
    fi
  fi
  printf 'api: stopped\n'
  return 0
}

cmd_stop() {
  local pid port i
  pid=$(recorded_pid) || pid=
  if [ -n "$pid" ] && pid_is_ours "$pid"; then
    kill "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ]; do
      fm_pid_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    if fm_pid_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  port=$(bound_port) || port=
  if [ -n "$port" ]; then
    i=0
    while [ "$i" -lt 20 ]; do
      health_ok "$port" || break
      sleep 0.1
      i=$((i + 1))
    done
  fi
  clear_records
  printf 'api: stopped\n'
}

cmd_start() {
  local home port pid identity child i bound session_pid
  node_ok || die "node is not a usable Node.js"
  [ -f "$SERVER" ] || die "missing API server $SERVER"
  mkdir -p "$STATE" "$CONFIG"
  home=$(cd "$FM_HOME" && pwd) || die "cannot resolve FM_HOME"
  FM_HOME=$home
  port=$(resolve_port)

  pid=$(recorded_pid) || pid=
  if [ -n "$pid" ] && api_is_attachable "$pid"; then
    api_status_line attached
    return 0
  fi
  if [ -n "$pid" ] && pid_is_ours "$pid"; then
    cmd_stop >/dev/null
  elif [ -n "$pid" ]; then
    clear_records
  fi

  i=0
  while ! fm_lock_try_acquire "$LOCK_DIR"; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || die "could not acquire start lock"
    sleep 0.1
  done
  # shellcheck disable=SC2064
  trap 'fm_lock_release "$LOCK_DIR"' EXIT

  pid=$(recorded_pid) || pid=
  if [ -n "$pid" ] && api_is_attachable "$pid"; then
    api_status_line attached
    return 0
  fi
  if [ -n "$pid" ] && pid_is_ours "$pid"; then
    cmd_stop >/dev/null
  elif [ -n "$pid" ]; then
    clear_records
  fi

  rm -f "$PORT_FILE"
  session_pid=$(session_lock_pid) || session_pid=
  : >>"$LOG_FILE"
  if [ -n "$session_pid" ]; then
    node "$SERVER" --home "$home" --port "$port" --state "$STATE" --session-pid "$session_pid" >>"$LOG_FILE" 2>&1 &
  else
    node "$SERVER" --home "$home" --port "$port" --state "$STATE" >>"$LOG_FILE" 2>&1 &
  fi
  child=$!
  identity=$(fm_pid_identity "$child") || identity=
  printf '%s\n' "$child" > "$PID_FILE"
  printf '%s\n' "$identity" > "$IDENTITY_FILE"
  printf '%s\n' "$session_pid" > "$SESSION_PID_FILE"

  i=0
  bound=
  while [ "$i" -lt $((START_TIMEOUT * 10)) ]; do
    if ! fm_pid_alive "$child"; then
      die "server exited during start$(tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/: /')"
    fi
    bound=$(bound_port) || bound=
    if [ -n "$bound" ] && health_ok "$bound"; then
      api_status_line started
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$child" 2>/dev/null || true
  clear_records
  die "server did not become ready within ${START_TIMEOUT}s"
}

cmd=${1:-}
case "$cmd" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *)
    printf 'usage: fm-api.sh start|stop|status\n' >&2
    exit 2
    ;;
esac
