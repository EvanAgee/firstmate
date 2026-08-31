#!/usr/bin/env bash
# fm-review-loop-stop.sh - stop repeated no-mistakes review clusters.
#
# The semantic procedure and cluster definition live in
# .agents/skills/review-loop-stop/SKILL.md. This script owns the private state,
# report, status-event, and threshold mechanics.
#
# Usage:
#   fm-review-loop-stop.sh record <task-id> --run <run-id> --head <reviewed-head> \
#     --changed <summary> --cluster <cluster> [--cluster <cluster>...] \
#     [--threshold <rounds>]
#   fm-review-loop-stop.sh resolve <task-id> --run <run-id> \
#     --decision <root|bank>
#
# record represents one completed Review gate that returned findings.
# --head makes an exact retry idempotent. --changed says what the reviewed code
# changed in this round. Each --cluster is a stable semantic key assigned by the
# invoking agent under the skill's definition.
#
# A cluster trips after it appears in the configured number of consecutive
# recorded rounds. --threshold sets that number for a new run. Otherwise
# FM_REVIEW_LOOP_THRESHOLD sets it, with 3 as the default. The first record pins
# the threshold for that run and later records refuse a conflicting override.
#
# A trip writes state/review-loops/<task-id>-<run-id>-<generation>.md, appends
# one keyed needs-decision event to state/<task-id>.status, prints the report,
# and exits 20. Exact retries and later rounds keep exiting 20 without appending
# another event. The status key plus the saved state close the crash window: a
# retry repairs a missing event but never duplicates one already appended.
#
# resolve records only a decision already supplied by firstmate. Both choices
# archive the stop, clear the reported clusters from prior rounds, and preserve
# active streaks for every other cluster. This command never chooses a path or
# drives no-mistakes itself.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOOP_DIR="$STATE/review-loops"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_slug() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_text() {
  [ -n "$1" ] && [ "${#1}" -le "$2" ] &&
    ! printf '%s' "$1" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1
}

valid_threshold() {
  case "$1" in
    '' | *[!0-9]* | 0) return 1 ;;
    *) return 0 ;;
  esac
}

atomic_write() { # <path> <content>
  local path=$1 content=$2 tmp
  tmp=$(mktemp "$LOOP_DIR/.review-loop.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! mv "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

lock_task() { # <task-id>
  LOCK_DIR="$LOOP_DIR/$1.lock"
  mkdir -p "$LOOP_DIR"
  fm_lock_try_acquire "$LOCK_DIR" || die "review-loop state is busy for task $1"
  trap 'fm_lock_release "$LOCK_DIR" 2>/dev/null || true' EXIT
}

status_key() { # <run-id> <generation>
  printf 'review-loop-%s-%s' "$1" "$2"
}

surface_status() { # <task-id> <key> <clusters-json> <threshold> <report>
  local task=$1 key=$2 clusters=$3 threshold=$4 report=$5 status line cluster_list
  status="$STATE/$task.status"
  cluster_list=$(printf '%s' "$clusters" | jq -r 'map("\u0027" + . + "\u0027") | join(", ")')
  line="needs-decision [key=$key]: review clusters $cluster_list reached $threshold rounds; choose fix at root or bank the remainder; report=$report"
  if [ -f "$status" ] && grep -Fqx "$line" "$status"; then
    return 0
  fi
  mkdir -p "$STATE"
  printf '%s\n' "$line" >> "$status"
}

write_report() { # <path> <state-json> <clusters-json>
  local path=$1 state_json=$2 clusters=$3 threshold run details tmp
  threshold=$(printf '%s' "$state_json" | jq -r '.threshold')
  run=$(printf '%s' "$state_json" | jq -r '.run')
  details=$(printf '%s' "$state_json" | jq -r \
    --argjson clusters "$clusters" --argjson threshold "$threshold" '
      $clusters[] as $cluster
      | "### `\($cluster)`\n\n" +
        ([ .rounds | reverse[]
           | select(.clusters | index($cluster) != null) ][0:$threshold]
         | reverse
         | map("- Round \(.round) reviewed `\(.head)`: \(.changed)")
         | join("\n"))
    ')
  tmp=$(mktemp "$LOOP_DIR/.review-report.XXXXXX") || return 1
  {
    printf '# Repeated review clusters\n\n'
    printf "Run: \`%s\`\n" "$run"
    printf 'Threshold: %s consecutive review rounds\n\n' "$threshold"
    printf '## What each cluster returned against\n\n'
    printf '%s\n' "$details"
    printf '\n## Decision\n\n'
    printf -- '- Fix at root. Repair the owning design before another review round.\n'
    printf -- '- Bank the remainder. Keep the current work and route the unresolved findings to a follow-up.\n'
    printf '\nFirstmate chooses under the task\047s existing authority rules.\n'
  } > "$tmp"
  mv "$tmp" "$path"
}

record_round() { # <task-id> <args...>
  local task=$1 run='' head='' changed='' requested_threshold=${FM_REVIEW_LOOP_THRESHOLD:-}
  local clusters='[]' state_file state_json threshold existing_run existing_threshold
  local new_state triggers generation key report round_count
  shift
  command -v jq >/dev/null 2>&1 || die "jq is required"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)
        [ "$#" -ge 2 ] || die "--run requires a value"
        run=$2
        shift 2
        ;;
      --head)
        [ "$#" -ge 2 ] || die "--head requires a value"
        head=$2
        shift 2
        ;;
      --changed)
        [ "$#" -ge 2 ] || die "--changed requires a value"
        changed=$2
        shift 2
        ;;
      --cluster)
        [ "$#" -ge 2 ] || die "--cluster requires a value"
        valid_text "$2" 240 || die "--cluster must be 1-240 printable characters"
        clusters=$(jq -cn --argjson current "$clusters" --arg cluster "$2" \
          '$current + [$cluster] | unique')
        shift 2
        ;;
      --threshold)
        [ "$#" -ge 2 ] || die "--threshold requires a value"
        requested_threshold=$2
        shift 2
        ;;
      *) die "unknown record option: $1" ;;
    esac
  done

  valid_slug "$task" || die "invalid task id: $task"
  valid_slug "$run" || die "invalid run id: $run"
  valid_slug "$head" || die "invalid reviewed head: $head"
  valid_text "$changed" 1000 || die "--changed must be 1-1000 printable characters"
  [ "$(printf '%s' "$clusters" | jq 'length')" -gt 0 ] || die "record requires at least one --cluster"
  [ -z "$requested_threshold" ] || valid_threshold "$requested_threshold" ||
    die "threshold must be a positive integer"

  lock_task "$task"
  state_file="$LOOP_DIR/$task.json"
  state_json=
  if [ -f "$state_file" ]; then
    state_json=$(cat "$state_file")
    printf '%s' "$state_json" | jq -e '
      .version == 1 and (.task | type == "string") and (.run | type == "string")
        and (.threshold | type == "number") and (.generation | type == "number")
        and (.rounds | type == "array")
    ' >/dev/null || die "invalid review-loop state: $state_file"
  fi

  existing_run=$(printf '%s' "$state_json" | jq -r '.run // empty' 2>/dev/null || true)
  if [ "$existing_run" != "$run" ]; then
    threshold=${requested_threshold:-3}
    state_json=$(jq -cn --arg task "$task" --arg run "$run" --argjson threshold "$threshold" '
      {version: 1, task: $task, run: $run, threshold: $threshold,
       generation: 1, rounds: [], surfaced: null, resolution: null}
    ')
  else
    existing_threshold=$(printf '%s' "$state_json" | jq -r '.threshold')
    if [ -n "$requested_threshold" ] && [ "$requested_threshold" != "$existing_threshold" ]; then
      die "run $run already uses review-loop threshold $existing_threshold"
    fi
    threshold=$existing_threshold
  fi

  if [ "$(printf '%s' "$state_json" | jq -r '.surfaced != null')" = true ]; then
    generation=$(printf '%s' "$state_json" | jq -r '.generation')
    key=$(status_key "$run" "$generation")
    triggers=$(printf '%s' "$state_json" | jq -c '.surfaced.clusters')
    report=$(printf '%s' "$state_json" | jq -r '.surfaced.report')
    surface_status "$task" "$key" "$triggers" "$threshold" "$report"
    printf 'stop: review clusters already surfaced in %s\n' "$report"
    exit 20
  fi

  if printf '%s' "$state_json" | jq -e --arg head "$head" \
    '.rounds[]? | select(.head == $head)' >/dev/null; then
    printf 'continue: reviewed head %s was already recorded\n' "$head"
    return 0
  fi

  new_state=$(printf '%s' "$state_json" | jq -c \
    --arg head "$head" --arg changed "$changed" --argjson clusters "$clusters" '
      .rounds += [{round: ((.rounds | length) + 1), head: $head,
                   changed: $changed, clusters: $clusters}]
    ')
  triggers=$(printf '%s' "$new_state" | jq -c --argjson threshold "$threshold" '
    def trailing_count($rounds; $cluster):
      reduce ($rounds | reverse[]) as $round
        ({count: 0, open: true};
         if .open and ($round.clusters | index($cluster) != null)
         then .count += 1
         elif .open then .open = false
         else .
         end) | .count;
    .rounds as $rounds
    | [ .rounds[-1].clusters[] as $cluster
        | select(trailing_count($rounds; $cluster) >= $threshold)
        | $cluster ]
  ')

  if [ "$(printf '%s' "$triggers" | jq 'length')" -eq 0 ]; then
    atomic_write "$state_file" "$new_state" || die "could not save review-loop state"
    round_count=$(printf '%s' "$new_state" | jq -r '.rounds | length')
    printf 'continue: review round %s recorded; no cluster reached %s rounds\n' \
      "$round_count" "$threshold"
    return 0
  fi

  generation=$(printf '%s' "$new_state" | jq -r '.generation')
  key=$(status_key "$run" "$generation")
  report="$LOOP_DIR/$task-$run-$generation.md"
  new_state=$(printf '%s' "$new_state" | jq -c \
    --argjson clusters "$triggers" --arg report "$report" '
      .surfaced = {clusters: $clusters, report: $report}
    ')
  write_report "$report" "$new_state" "$triggers" || die "could not write review-loop report"
  atomic_write "$state_file" "$new_state" || die "could not save surfaced review-loop state"
  surface_status "$task" "$key" "$triggers" "$threshold" "$report" ||
    die "could not surface review-loop stop"
  cat "$report"
  printf '\nstop: report=%s\n' "$report"
  exit 20
}

resolve_stop() { # <task-id> <args...>
  local task=$1 run='' decision='' state_file state_json state_run surfaced
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)
        [ "$#" -ge 2 ] || die "--run requires a value"
        run=$2
        shift 2
        ;;
      --decision)
        [ "$#" -ge 2 ] || die "--decision requires a value"
        decision=$2
        shift 2
        ;;
      *) die "unknown resolve option: $1" ;;
    esac
  done

  valid_slug "$task" || die "invalid task id: $task"
  valid_slug "$run" || die "invalid run id: $run"
  case "$decision" in root | bank) ;; *) die "--decision must be root or bank" ;; esac
  command -v jq >/dev/null 2>&1 || die "jq is required"
  lock_task "$task"
  state_file="$LOOP_DIR/$task.json"
  [ -f "$state_file" ] || die "no review-loop state for task $task"
  state_json=$(cat "$state_file")
  state_run=$(printf '%s' "$state_json" | jq -r '.run // empty')
  [ "$state_run" = "$run" ] || die "review-loop state belongs to run $state_run"
  surfaced=$(printf '%s' "$state_json" | jq -r '.surfaced != null')
  [ "$surfaced" = true ] || die "run $run has no surfaced review-loop stop"

  state_json=$(printf '%s' "$state_json" | jq -c --arg decision "$decision" '
    .surfaced.clusters as $resolved
    |
    .resolution = {
      choice: $decision,
      generation: .generation,
      clusters: .surfaced.clusters,
      report: .surfaced.report
    }
    | .generation += 1
    | .rounds |= map(.clusters = (.clusters - $resolved))
    | .surfaced = null
  ')
  atomic_write "$state_file" "$state_json" || die "could not save review-loop resolution"
  printf 'resolved: review-loop stop for %s recorded as %s\n' "$run" "$decision"
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  record | resolve)
    [ "$#" -ge 2 ] || die "$1 requires a task id"
    command=$1
    task=$2
    shift 2
    if [ "$command" = record ]; then
      record_round "$task" "$@"
    else
      resolve_stop "$task" "$@"
    fi
    ;;
  '') usage >&2; exit 1 ;;
  *) die "unknown command: $1" ;;
esac
