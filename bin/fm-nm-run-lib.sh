#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Seconds represented by an axi duration such as "12s", "51m55s", "15h29m", or
# "2d3h". Prints the total, or nothing when the string holds no recognized unit.
# Verified against real `axi status` output on the installed binary: the
# active_steps table renders ages in exactly this compact form. ONE owner for
# this parse, shared by bin/fm-watch.sh's pipeline-activity check and
# bin/fm-crew-state.sh's stalled-pipeline classification.
fm_nm_age_secs() {  # <duration>
  local raw=$1 total=0 num unit rest matched=0
  rest=$raw
  while [ -n "$rest" ]; do
    num=${rest%%[!0-9]*}
    [ -n "$num" ] || break
    rest=${rest#"$num"}
    # The unit is exactly one letter. A longer run (1ms, 2mo) is not a duration
    # axi emits, and silently reading its first letter would answer 60 for a
    # millisecond and 120 for two months.
    unit=${rest%%[0-9]*}
    [ ${#unit} -eq 1 ] || return 0
    rest=${rest#"$unit"}
    case "$unit" in
      s) total=$(( total + num )); matched=1 ;;
      m) total=$(( total + num * 60 )); matched=1 ;;
      h) total=$(( total + num * 3600 )); matched=1 ;;
      d) total=$(( total + num * 86400 )); matched=1 ;;
      *) break ;;
    esac
  done
  [ "$matched" = 1 ] || return 0
  printf '%s' "$total"
}

# The first active_steps[N]{...} row whose status matches <status-regex> (an
# extended-regex alternation, e.g. "running|fixing"), as
# "<step>|<status>|<active_for>|<last_activity>|<agent_pid>". Empty when the
# table is absent or no row matches. Scoped to ONLY the active_steps table's
# own declared row count: axi status renders sibling TOON tables (gates[N],
# findings[N]) from the same output, and a matching row in one of those must
# never be read as a pipeline step.
fm_nm_active_step_row() {  # <toon-output> <status-regex>
  printf '%s\n' "$1" | awk -v statre="$2" '
    /^[[:space:]]*active_steps\[[0-9]+\]\{/ {
      n = $0; sub(/^[^[]*\[/, "", n); sub(/\].*$/, "", n)
      left = n + 0; intable = 1; next
    }
    intable && /^[[:space:]]*[A-Za-z_][A-Za-z_]*\[[0-9]+\]\{/ { intable = 0 }
    intable {
      if ($0 !~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*,/) next
      if (left <= 0) { intable = 0; next }
      left--
      if ($0 ~ "^[[:space:]]*[a-z_]+,(" statre "),") { print; exit }
    }
  ' | head -1
}

# Parse one fm_nm_active_step_row() row into
# "<step>|<last_activity_secs_or_empty>|<agent_pid_or_none>|<age_text>". Both
# last_activity and agent_pid are quoted columns - last_activity's note can
# itself contain commas, so quote-delimited extraction (not a comma split) is
# the only safe way to reach agent_pid after it. last_activity is
# "<age> ago: <note>", optionally prefixed "quiet " when the step has gone
# silent; empty secs means unreadable, never "fresh". age_text is that same
# "<age>" (e.g. "51m55s"), unparsed, for a human-readable detail string.
# agent_pid is "none" when blank, "-", or absent (a step reported with no
# attached agent).
fm_nm_active_step_parse() {  # <row>
  local row=$1 step rest activity age secs pid
  step=$(fm_nm_trim "${row%%,*}")
  rest=${row#*\"}   # up to (not including) last_activity's opening quote
  activity=${rest%%\"*}
  rest=${rest#*\"}  # past last_activity's closing quote
  secs=""
  age=""
  case "$activity" in *" ago"*)
    age=${activity#quiet }
    age=${age%% ago*}
    secs=$(fm_nm_age_secs "$age")
    ;;
  esac
  case "$rest" in
    *\"*)
      pid=${rest#*\"}
      pid=${pid%%\"*}
      ;;
    *) pid="" ;;
  esac
  [ -n "$pid" ] && [ "$pid" != - ] || pid=none
  printf '%s|%s|%s|%s' "$step" "$secs" "$pid" "$age"
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}
