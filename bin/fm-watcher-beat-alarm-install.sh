#!/usr/bin/env bash
# Consent-guarded installer for the session-independent watcher-beat alert
# (bin/fm-watcher-beat-alarm.sh; contract in docs/wedge-alarm.md's
# "Watcher-beat alarm"). Installs and removes a macOS launchd interval agent
# that runs bin/fm-watcher-beat-alarm.sh --home <FM_HOME> every 120 seconds.
# The checker is alert-only: it never starts, stops, arms, or repairs the
# watcher, it is not a second watcher process, and it keeps running while a
# fully dead agent session cannot alert on its own.
#
# Consent contract: install and uninstall print the exact actions and ask once
# on the terminal; only --yes skips the prompt (for a non-interactive run the
# captain already approved). Nothing is installed or removed silently.
#
# Usage:
#   bin/fm-watcher-beat-alarm-install.sh status
#   bin/fm-watcher-beat-alarm-install.sh install [--yes]
#   bin/fm-watcher-beat-alarm-install.sh uninstall [--yes]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME_OVERRIDE:-${FM_HOME:-$FM_ROOT}}"
INTERVAL=${FM_BEAT_ALARM_INTERVAL:-120}

ACTION=
YES=0

usage() {
  sed -n '2,17p' "$0"
  exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    status|install|uninstall)
      [ -z "$ACTION" ] || { echo "watcher-beat-alarm install: pass at most one action" >&2; usage 2; }
      ACTION=$1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "watcher-beat-alarm install: unknown argument: $1" >&2
      usage 2
      ;;
  esac
done
[ -n "$ACTION" ] || usage 2

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=120 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=120

# The label is stable per home so an FM_HOME can collide even if two homes use
# one checkout; pwd-resolution keeps the label stable across symlink aliases.
home_key=$(printf '%s' "$(cd "$FM_HOME" && pwd -P)" | shasum -a 256 | cut -c1-8 2>/dev/null || true)
[ -n "$home_key" ] || home_key=default
LABEL="com.firstmate.watcher-beat-alarm.$home_key"
PLIST="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/$LABEL.plist"
CHECKER="$SCRIPT_DIR/fm-watcher-beat-alarm.sh"
LOG_PATH="$FM_HOME/state/.beat-alarm.launchd.log"

# Consent gate: print the exact effect and ask once on the terminal. --yes is
# the sentinel that a captain already approved this exact action (non-tty or a
# scripted run records here only that the caller confirmed above).
consent() {  # <verb>
  local verb=$1
  printf 'watcher-beat-alarm %s:\n' "$verb" >&2
  printf '  label:  %s\n' "$LABEL" >&2
  printf '  plist:  %s\n' "$PLIST" >&2
  printf '  action: %s\n' "$2" >&2
  [ "$YES" -eq 1 ] && return 0
  if [ -t 0 ] || [ -c /dev/tty ]; then
    printf 'Proceed? [y/N] ' >&2
    local reply
    read -r reply < /dev/tty 2>/dev/null || read -r reply
    case "$reply" in y|Y|yes|YES) return 0 ;; esac
  fi
  echo "refused: consent not given (pass --yes only when the captain already approved this exact action)" >&2
  return 1
}

require_macos() {
  [ "$(uname)" = Darwin ] && return 0
  echo "watcher-beat-alarm install: launchd agents are macOS-only; on $(uname) wire bin/fm-watcher-beat-alarm.sh from cron or a systemd timer instead (contract stays alert-only)" >&2
  return 1
}

write_plist() {
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$CHECKER</string>
    <string>--home</string>
    <string>$FM_HOME</string>
  </array>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_PATH</string>
  <key>StandardErrorPath</key>
  <string>$LOG_PATH</string>
</dict>
</plist>
EOF
}

is_installed() {
  [ -f "$PLIST" ]
}

case "$ACTION" in
  status)
    if is_installed; then
      printf 'installed: %s (interval %ss, checker %s)\n' "$PLIST" "$INTERVAL" "$CHECKER"
      if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        printf 'launchd: loaded\n'
      else
        printf 'launchd: not loaded (install exists but is not active)\n'
      fi
    else
      printf 'not installed: %s absent\n' "$PLIST"
    fi
    exit 0
    ;;
  install)
    require_macos || exit 1
    if [ ! -d "$FM_HOME/state" ]; then
      printf 'warning: %s/state does not exist yet; it will be created by the first watcher cycle\n' "$FM_HOME" >&2
    fi
    consent "install" "write $PLIST and load it into launchd now (alerts every ${INTERVAL}s; alert-only, never starts or stops anything)" || exit 1
    mkdir -p "$(dirname "$PLIST")" "$FM_HOME/state"
    tmp=$(mktemp "$PLIST.tmp.XXXXXX") || exit 1
    PLIST=$tmp write_plist
    mv -f "$tmp" "$PLIST" || exit 1
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST" || { echo "error: launchctl load failed for $PLIST" >&2; exit 1; }
    printf 'installed: %s (every %ss; alert-only: the checker never starts, stops, or re-arms anything)\n' "$PLIST" "$INTERVAL"
    exit 0
    ;;
  uninstall)
    if [ ! -f "$PLIST" ]; then
      printf 'not installed: %s absent; nothing to remove\n' "$PLIST"
      exit 0
    fi
    consent "uninstall" "unload $LABEL from launchd and delete $PLIST" || exit 1
    launchctl unload -w "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST" || exit 1
    printf 'removed: %s (launchd alerts stopped; the in-session watcher monitoring is untouched)\n' "$PLIST"
    exit 0
    ;;
esac
