#!/usr/bin/env bash
# Consent-guarded installer for bounded, non-inference fm-route.sh refresh,
# independent of any LLM turn (report: "Use the existing system-timer pattern
# for periodic refresh independent of LLM turns"). Same shape as
# bin/fm-watcher-beat-alarm-install.sh: installs and removes a macOS launchd
# interval agent that runs `bin/fm-route.sh refresh` on a bounded interval.
# refresh only reads non-inference health/quota evidence and writes
# state/route.json; it never launches, stops, or supervises anything.
#
# Consent contract: install and uninstall print the exact action and ask once
# on the terminal; only --yes skips the prompt (a non-interactive run the
# captain already approved). Nothing is installed or removed silently.
#
# Usage:
#   bin/fm-route-refresh-install.sh status
#   bin/fm-route-refresh-install.sh install [--yes]
#   bin/fm-route-refresh-install.sh uninstall [--yes]
#   bin/fm-route-refresh-install.sh crontab          # print the Linux cron line
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_ROUTE_HOME_OVERRIDE:-$FM_ROOT}"
INTERVAL=${FM_ROUTE_REFRESH_INTERVAL:-300}

ACTION=
YES=0

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d'
  exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    status|install|uninstall|crontab)
      [ -z "$ACTION" ] || { echo "route-refresh install: pass at most one action" >&2; usage 2; }
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
      echo "route-refresh install: unknown argument: $1" >&2
      usage 2
      ;;
  esac
done
[ -n "$ACTION" ] || usage 2

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=300 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=300

# The label is stable per canonical home so distinct route stores never
# collide, and pwd-resolution keeps it stable across symlink aliases.
home_key=$(printf '%s' "$(cd "$FM_HOME" && pwd -P)" | shasum -a 256 | cut -c1-8 2>/dev/null || true)
[ -n "$home_key" ] || home_key=default
LABEL="com.firstmate.route-refresh.$home_key"
PLIST="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/$LABEL.plist"
REFRESHER="$SCRIPT_DIR/fm-route.sh"
LOG_PATH="$FM_HOME/state/.route-refresh.launchd.log"

consent() {  # <verb> <action-description>
  local verb=$1
  printf 'route-refresh %s:\n' "$verb" >&2
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
  echo "route-refresh install: launchd agents are macOS-only; on $(uname) wire bin/fm-route.sh refresh from cron or a systemd timer instead" >&2
  return 1
}

# home_key is derived from FM_HOME's real path (line above), so installing
# from a different path for what is meant to be the same logical home (for
# example a worktree checkout instead of the primary one) mints a distinct
# label with its own plist. If that worktree is later torn down without
# running `uninstall` first, its plist file disappears but the launchd job
# stays registered forever -- an orphan stuck reporting its last exit code,
# invisible to `status` because status only ever looks at THIS run's own
# label (firstmate issue #127). Every install call sweeps every other
# registered com.firstmate.route-refresh.* label and unloads any whose
# plist file no longer exists, so the fleet self-heals instead of
# accumulating one dead job per relocated home.
#
# The sweep decides an orphan by asking launchd what is registered and then
# asking the filesystem whether that label's plist still exists, so both
# answers must describe the same launchd domain. LAUNCH_AGENTS_DIR redirects
# only the filesystem half; with it pointed anywhere but the real LaunchAgents
# directory, every genuinely installed job looks plistless and the sweep
# unloads the whole fleet. Only sweep when the two halves agree.
#
# Agreement is a question about directories, not about spelling, so both sides
# resolve to a real path first: a trailing slash, a doubled separator or a
# symlinked home all name the same directory and must still sweep. An
# unresolvable path (the directory does not exist yet) falls back to its
# literal form, which can only ever fail the comparison and suppress the
# sweep -- the safe direction.
real_dir() {
  cd "$1" 2>/dev/null && pwd -P || printf '%s\n' "$1"
}

agents_dir_is_launchd_domain() {
  [ "$(real_dir "$1")" = "$(real_dir "$HOME/Library/LaunchAgents")" ]
}

sweep_orphaned_jobs() {
  local agents_dir="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}" label
  command -v launchctl >/dev/null 2>&1 || return 0
  if ! agents_dir_is_launchd_domain "$agents_dir"; then
    printf 'route-refresh install: skipping the orphaned-job sweep: %s is not the launchd agents directory (%s), so a registered job there cannot be judged orphaned\n' \
      "$agents_dir" "$HOME/Library/LaunchAgents" >&2
    return 0
  fi
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    [ "$label" != "$LABEL" ] || continue
    [ -f "$agents_dir/$label.plist" ] && continue
    printf 'route-refresh install: unloading orphaned job %s (no plist at %s/%s.plist)\n' \
      "$label" "$agents_dir" "$label" >&2
    launchctl remove "$label" >/dev/null 2>&1 || true
  done < <(launchctl list 2>/dev/null | awk '{print $3}' | grep '^com\.firstmate\.route-refresh\.')
}

# launchd runs an agent under a minimal built-in PATH with none of the four
# probe tools fm-route.sh's refresh depends on (teamclaude, teamcodex,
# quota-axi, omp): they live under per-tool install locations such as an nvm
# node version, ~/.local/bin, or ~/.bun/bin, never the system default
# (firstmate issue #127). Resolve each one's real directory with `command -v`
# under THIS install run's own (interactive, login-shell-derived) PATH, so
# the plist gets the real current locations instead of one machine's
# hardcoded nvm version, and every probe tool refresh needs is covered even
# if it moves to a different manager later.
# Sets FM_ROUTE_PROBE_PATH (colon-joined directories) and
# FM_ROUTE_UNRESOLVED_TOOLS (space-prefixed tool names) in the caller's shell
# rather than printing, so the caller can warn about what it could not find.
resolve_probe_path() {
  local tool dir seen=" " out="" bin
  FM_ROUTE_UNRESOLVED_TOOLS=
  FM_ROUTE_PROBE_PATH=
  for tool in teamclaude teamcodex quota-axi omp; do
    bin=$(command -v "$tool" 2>/dev/null)
    # `command -v` prints a bare name for a shell function or builtin and an
    # `alias x='...'` string for an alias; only an absolute path names a real
    # directory, and anything else would resolve to the installer's own cwd.
    case "$bin" in
      /*) ;;
      *)
        FM_ROUTE_UNRESOLVED_TOOLS="$FM_ROUTE_UNRESOLVED_TOOLS $tool"
        continue
        ;;
    esac
    dir=$(cd "$(dirname "$bin")" && pwd -P) || {
      FM_ROUTE_UNRESOLVED_TOOLS="$FM_ROUTE_UNRESOLVED_TOOLS $tool"
      continue
    }
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    out="$out:$dir"
  done
  FM_ROUTE_PROBE_PATH=${out#:}
}

write_plist() {
  local probe_path unresolved
  resolve_probe_path
  probe_path=$FM_ROUTE_PROBE_PATH
  unresolved=${FM_ROUTE_UNRESOLVED_TOOLS# }
  if [ -n "$unresolved" ]; then
    printf 'route-refresh install: WARNING: could not resolve these probe tools on this run PATH:%s\n' \
      "$FM_ROUTE_UNRESOLVED_TOOLS" >&2
    printf 'route-refresh install: the scheduled refresh cannot run their health checks, so those routes will read unknown (firstmate issue #127).\n' >&2
    printf 'route-refresh install: install again from a shell where each tool resolves to a real path.\n' >&2
  fi
  if [ -z "$probe_path" ]; then
    printf 'route-refresh install: WARNING: no probe tool resolved at all; falling back to PATH /usr/local/bin, which is unlikely to contain any of them.\n' >&2
    probe_path=/usr/local/bin
  fi
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
    <string>$REFRESHER</string>
    <string>refresh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_ROUTE_HOME_OVERRIDE</key>
    <string>$FM_HOME</string>
    <key>PATH</key>
    <string>$probe_path:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
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
  crontab)
    minutes=$(( INTERVAL / 60 ))
    [ "$minutes" -ge 1 ] || minutes=1
    printf '# Linux: add this line with "crontab -e".\n'
    printf '*/%s * * * * FM_ROUTE_HOME_OVERRIDE=%s %s refresh\n' \
      "$minutes" "$FM_HOME" "$REFRESHER"
    exit 0
    ;;
  status)
    if is_installed; then
      printf 'installed: %s (interval %ss, refresher %s)\n' "$PLIST" "$INTERVAL" "$REFRESHER"
      if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        printf 'launchd: loaded\n'
      else
        printf 'launchd: not loaded (install exists but is not active)\n'
      fi
    else
      printf 'not installed: %s absent\n' "$PLIST"
    fi
    agents_dir="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
    # Same domain agreement the sweep needs: launchd's registry can only be
    # compared against the directory launchd itself reads.
    if agents_dir_is_launchd_domain "$agents_dir"; then
      orphans=$(launchctl list 2>/dev/null | awk '{print $3}' | grep '^com\.firstmate\.route-refresh\.' | grep -v "^$LABEL\$") || orphans=
      while IFS= read -r label; do
        [ -n "$label" ] || continue
        [ -f "$agents_dir/$label.plist" ] && continue
        printf 'orphaned: %s is registered in launchd with no plist at %s/%s.plist (run install to clean it up)\n' \
          "$label" "$agents_dir" "$label"
      done <<< "$orphans"
    fi
    exit 0
    ;;
  install)
    require_macos || exit 1
    if [ ! -d "$FM_HOME/state" ]; then
      printf 'warning: %s/state does not exist yet; it will be created by the first refresh\n' "$FM_HOME" >&2
    fi
    consent "install" "write $PLIST and load it into launchd now (refresh every ${INTERVAL}s; refresh only reads quota/health evidence and writes state/route.json, never launches or stops anything); also unload any orphaned route-refresh job from a relocated home whose plist no longer exists" || exit 1
    sweep_orphaned_jobs
    mkdir -p "$(dirname "$PLIST")" "$FM_HOME/state"
    tmp=$(mktemp "$PLIST.tmp.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT
    PLIST=$tmp write_plist || { echo "error: could not write the agent plist for $PLIST" >&2; exit 1; }
    mv -f "$tmp" "$PLIST" || { echo "error: could not install $PLIST" >&2; exit 1; }
    trap - EXIT
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST" || { echo "error: launchctl load failed for $PLIST" >&2; exit 1; }
    printf 'installed: %s (every %ss; refresh-only: reads quota/health evidence and writes state/route.json)\n' "$PLIST" "$INTERVAL"
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
    printf 'removed: %s (launchd refresh stopped)\n' "$PLIST"
    exit 0
    ;;
esac
