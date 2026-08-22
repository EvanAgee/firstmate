# shellcheck shell=bash
# Shared loader for this home's supervision environment knobs.
# Usage: . bin/fm-supervision-env-lib.sh; fm_supervision_env_load "$CONFIG"
#
# Supervision tuning (FM_GUARD_GRACE, FM_POLL, FM_HEARTBEAT, FM_HEARTBEAT_MAX,
# and the rest of the FM_* runtime knobs in docs/configuration.md) used to reach
# a script only through the environment of whatever shell launched it. A Claude
# primary inherited them from .claude/settings.local.json, another harness only
# from an interactive .zshrc, and a cron or launchd context - which has neither -
# inherited nothing. The same home therefore answered "is the beacon stale?"
# with different numbers depending on who asked, which is exactly the drift an
# external watchdog must not have.
#
# This is the one mechanism the supervision scripts themselves read, so every
# harness and every scheduler context resolves the same values for a home.
# The optional local, gitignored config/supervision.env holds one `NAME=value`
# assignment per line, with `#` comments and blank lines ignored.
#
# PRECEDENCE: a real environment variable always wins over the file. A knob
# already present and non-empty in the environment is left exactly as inherited,
# so an explicit per-invocation override (a test, a one-off run, a harness
# setting) is never silently overwritten by the file. The file supplies only the
# knobs the caller's environment did not already set.
#
# The file is PARSED, never dot-sourced. Sourcing would run whatever the file
# contains, so one malformed line could abort the read and silently drop every
# valid knob after it - the failure mode that hides a wrong grace value behind a
# typo. Parsing takes each well-formed assignment on its own and skips only the
# lines it cannot understand, and a config file can never execute code.
# Values are exported, so a script that loads this passes the same resolved
# knobs down to every helper it runs.

# fm_supervision_env_file [config-dir]: print the path this loader would read.
# Resolves the effective home the same way the supervision scripts do when the
# caller passes no explicit config dir.
fm_supervision_env_file() {
  local config=${1:-} libdir root home
  if [ -z "$config" ]; then
    libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || libdir=.
    root="${FM_ROOT_OVERRIDE:-$(cd "$libdir/.." && pwd 2>/dev/null)}"
    home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
    config="${FM_CONFIG_OVERRIDE:-$home/config}"
  fi
  printf '%s\n' "$config/supervision.env"
}

# fm_supervision_env_load [config-dir]
# Applies config/supervision.env for the home whose config dir is $1 (default:
# the effective config dir). Always returns 0: a missing or unreadable file
# simply leaves the environment alone, because every knob carries its own
# default at its point of use and a supervision script must never fail to start
# over an optional tuning file.
fm_supervision_env_load() {
  local file line name value
  file=$(fm_supervision_env_file "${1:-}")
  [ -f "$file" ] && [ -r "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    # Strip an optional leading `export ` and surrounding blanks, then require a
    # shell-identifier name and an `=`. Anything else is skipped without
    # affecting the lines around it.
    line=${line#"${line%%[![:space:]]*}"}
    case $line in
      ''|'#'*) continue ;;
      export\ *) line=${line#export }; line=${line#"${line%%[![:space:]]*}"} ;;
    esac
    name=${line%%=*}
    [ "$name" != "$line" ] || continue
    case $name in
      ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
    esac
    value=${line#*=}
    # Trim one matched pair of surrounding quotes and any trailing blanks, so a
    # quoted value reads the same as a bare one.
    value=${value%"${value##*[![:space:]]}"}
    case $value in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    # Indirect read of the CURRENT environment: set and non-empty means the
    # caller already decided this knob, so the file does not apply.
    [ -n "${!name:-}" ] && continue
    [ -n "$value" ] || continue
    export "$name=$value"
  done < "$file"
  return 0
}
