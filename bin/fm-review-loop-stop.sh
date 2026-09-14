#!/usr/bin/env bash
# fm-review-loop-stop.sh - stop repeating or widening no-mistakes review clusters.
#
# The semantic procedure and cluster definition live in
# .agents/skills/review-loop-stop/SKILL.md. This script owns the private state,
# report, status-event, and threshold mechanics.
#
# Usage:
#   fm-review-loop-stop.sh record <task-id> --run <run-id> --head <reviewed-head> \
#     --changed <summary> --cluster <cluster> [--cluster <cluster>...] \
#     [--targeted <cluster>...] [--threshold <rounds>] \
#     [--widening-threshold <rounds>]
#   fm-review-loop-stop.sh resolve <task-id> --run <run-id> \
#     --decision <root|bank>
#
# record represents one completed Review gate that returned findings.
# --changed says what the reviewed code changed in this round. Each --cluster is
# a stable defect-identity key assigned by the invoking agent under the skill's
# definition; pass one per returned finding cluster at any severity.
#
# --targeted names each cluster this call's change tried to close. A cluster's
# loop count advances only across a trailing run of rounds where that cluster was
# both returned and targeted, so a defect that merely reappears without a fix
# aimed at it is recorded but does not advance toward a stop. Every --targeted
# value must also be a --cluster of the same call. Omitting --targeted entirely
# targets every cluster this call names.
#
# --head identifies the reviewed commit, and a record against an already recorded
# head has exactly two outcomes. It is an idempotent no-op when it adds nothing:
# its clusters are already in that round and the clusters it targets are already
# targeted there. Targeting counts the same whether --targeted names it or an
# omitted --targeted implies it, so both spellings of one request get the same
# answer. This is what makes a crash-recovery replay safe. It is an error when it
# would add a cluster or new targeting, because a fix round produces a new
# commit; record that cluster or targeting against the current head instead. The
# error names what was new. A recorded round is never rewritten.
#
# A cluster trips after the configured number of consecutive targeted-and-
# returned rounds. --threshold sets that number for a new run. Otherwise
# FM_REVIEW_LOOP_THRESHOLD sets it, with 3 as the default. The first record pins
# the threshold for that run and later records refuse a conflicting override.
#
# A run also stops on the widening shape, where the review keeps returning new
# clusters under one module or invariant. A prefix is the cluster key before
# its last ":". A round widens it when every cluster the previous round returned
# under that prefix was targeted on that previous round and is absent from the
# current round, which returns at least one cluster never seen before under it.
# A prefix's first appearance is opening context and does not count toward the
# widening threshold. A round that returns only
# already-seen clusters, or that leaves the previous round's clusters open, ends
# the count. A round that answers with a new cluster still counts even if it
# also re-returns one the run saw in some earlier round, because the frontier
# moved; only the previous round's clusters have to be closed.
# --widening-threshold sets how many consecutive
# widening rounds trip it for a new run. Otherwise
# FM_REVIEW_LOOP_WIDENING_THRESHOLD sets it, with 3 as the default. The first
# record pins it for that run and later records refuse a conflicting override,
# exactly the way --threshold behaves. A round's returned set includes the
# clusters a decision moved aside, so a resolved round still counts as a round
# that returned findings; its aimed set grows only by the clusters that round
# actually aimed at, which the decision records, so a resolve never invents a
# closure.
# The private widening report contains shape: widening, the shared prefix, and
# each round's new clusters in round order. It uses the same keyed status-event
# format as a streak stop. A cluster streak takes precedence when both trip.
#
# A trip writes state/review-loops/<task-id>-<run-id>-<generation>.md, appends
# one keyed needs-decision event to state/<task-id>.status, prints the report,
# and exits 20. Exact retries and later rounds keep exiting 20 without appending
# another event. The status key plus the saved state close the crash window: a
# retry repairs a missing event but never duplicates one already appended.
#
# resolve records only a decision already supplied by firstmate. Both choices
# archive the stop, clear the reported clusters from both the returned and the
# targeted set of every prior round, and preserve active streaks for every other
# cluster. A widening stop resolves per prefix instead: both choices move that
# prefix past the recorded rounds so it starts a fresh widening count, and every
# other prefix keeps its own. Its clusters stay on their rounds, because they are
# the record of what this run has already seen.
# Each round saves decided clusters in resolved and their previously targeted
# subset in resolved_aimed. A same-head retry uses that subset to reject added
# targeting even after resolution; an explicit empty subset grants none.
# Legacy rounds without resolved_aimed retain their prior replay semantics by
# treating resolved as previously targeted, including after later resolutions.
# Identical retries remain no-ops. Resolved clusters start a fresh streak count
# from the next recorded head but remain seen for widening detection.
# This command never chooses a path or drives no-mistakes itself.
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

# Widening detection follows the round and prefix contract in the header.
read -r -d '' WIDENING_JQ <<'JQ' || true
def prefix_of($cluster):
  ($cluster | rindex(":")) as $i
  | if $i == null then $cluster else $cluster[0:$i] end;

# A streak resolution moves decided clusters off .clusters and .targeted onto
# .resolved, so a read of what a round returned must union it. Otherwise a
# resolved round looks empty and the round after it loses the widening credit
# its aimed change earned.
def returned($round): $round.clusters + ($round.resolved // []);

# Aimedness is not recoverable from .resolved, because a resolution strips a
# cluster from .targeted whether or not the round ever aimed at it. The
# resolution records the aimed subset it moved as .resolved_aimed; a run
# recorded before that field existed has none and reads as untargeted, which is
# the conservative answer rule 4 asks for.
def aimed($round):
  ($round.targeted // $round.clusters) + ($round.resolved_aimed // []);

.rounds as $rounds
| (.widened // {}) as $widened
| [ $rounds[] | returned(.)[] | prefix_of(.) ] | unique
| . as $prefixes
| [ $prefixes[]
    | . as $prefix
    | ($widened[$prefix] // 0) as $floor
    # Rounds are 1-based; $floor is the last round a decision already answered
    # for this prefix, so only rounds after it can count toward a new stop.
    | [ range(0; $rounds | length)
        | select(. + 1 > $floor)
        | { index: ., round: $rounds[.],
            previous: (if . == 0 then null else $rounds[. - 1] end) } ] as $window
    | [ $window[]
        | . as $entry
        | (returned($entry.round) | map(select(prefix_of(.) == $prefix))) as $returned
        | (if $entry.previous == null then []
           else (returned($entry.previous) | map(select(prefix_of(.) == $prefix)))
           end) as $before
        # Every earlier cluster under this prefix was aimed at and is now gone.
        | ((($before | length) > 0)
           and (($before - aimed($entry.previous)) | length) == 0
           and (($before - returned($entry.round)) | length) == ($before | length)) as $closed
        # Clusters this run has already returned under this prefix, whether they
        # are still open on their round or a decision moved them to .resolved.
        # A cluster firstmate already answered is not a new frontier.
        | [ $rounds[0:$entry.index][] | returned(.)[]
            | select(prefix_of(.) == $prefix) ] as $seen
        | ($returned - $seen) as $fresh
        | { index: $entry.index,
            widened: ($closed and (($fresh | length) > 0)),
            fresh: $fresh }
      ] as $marks
    | (reduce ($marks | reverse[]) as $mark
        ({credited: [], open: true};
         if .open and $mark.widened then .credited += [$mark.index]
         elif .open then .open = false
         else . end) | .credited | sort) as $credited
    | select(($credited | length) >= $threshold)
    | { prefix: $prefix,
        floor: $floor,
        credited: $credited,
        clusters: ([ $marks[]
                     | select(.index as $i | $credited | index($i) != null)
                     | .fresh[] ] | unique) }
  ]
JQ

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

# The widening report answers a different question than the streak report: not
# "which defect survived repeated fixes" but "which module kept producing new
# ones". It lists each widening round's fresh clusters in order so the reader can
# see the frontier moving, and offers the same two paths.
write_widening_report() { # <path> <state-json> <run>
  local path=$1 state_json=$2 run=$3 threshold prefix floor credited rounds tmp
  threshold=$(printf '%s' "$state_json" | jq -r '.surfaced.threshold // .widening_threshold')
  prefix=$(printf '%s' "$state_json" | jq -r '.surfaced.prefix')
  floor=$(printf '%s' "$state_json" | jq -r '.surfaced.floor // 0')
  credited=$(printf '%s' "$state_json" | jq -c '.surfaced.credited // []')
  # List exactly the rounds the detector credited, so the report and the status
  # event always describe the same stop. The round that opened the prefix after
  # the floor is shown above them as context, because it had no earlier finding
  # for a fix to close and so never counted toward the streak. It is shown only
  # when it sits directly before the credited window, so the listing is always
  # one unbroken span of rounds rather than a gapped set with no marker.
  rounds=$(printf '%s' "$state_json" | jq -r --arg prefix "$prefix" \
    --argjson floor "$floor" --argjson credited "$credited" '
    def prefix_of($cluster):
      ($cluster | rindex(":")) as $i
      | if $i == null then $cluster else $cluster[0:$i] end;
    def returned($round): $round.clusters + ($round.resolved // []);
    def seen_before($rounds; $i):
      [ $rounds[0:$i][] | returned(.)[]
        | select(prefix_of(.) == $prefix) ];
    def fresh_at($rounds; $i):
      (returned($rounds[$i]) | map(select(prefix_of(.) == $prefix)))
      - seen_before($rounds; $i);
    .rounds as $rounds
    | ($credited | min) as $first
    | [ range(0; $rounds | length)
        | select(. + 1 > $floor)
        | select($first == null or . < $first)
        | select((fresh_at($rounds; .) | length) > 0) ] as $before_credited
    | ($before_credited | last) as $candidate
    | (if $candidate != null and $first != null and $candidate + 1 == $first
       then { index: $candidate,
              opened: (($before_credited | first) == $candidate) }
       else null end) as $opening
    | [ (if $opening == null then empty else $opening.index end), $credited[] ]
    | [ .[] as $i
        | $rounds[$i] as $round
        | fresh_at($rounds; $i) as $fresh
        | "- Round \($round.round) reviewed `\($round.head)`: \($round.changed)"
          + (if $opening != null and $i == $opening.index
             then (if $opening.opened
                   then " (first findings under this prefix)"
                   else " (earlier findings under this prefix, not counted)"
                   end)
             else "" end)
          + "\n"
          + ($fresh | sort | map("  - new `" + . + "`") | join("\n")) ]
    | join("\n")
  ')
  tmp=$(mktemp "$LOOP_DIR/.review-report.XXXXXX") || return 1
  {
    printf '# Widening review findings\n\n'
    printf 'shape: widening\n'
    printf "Run: \`%s\`\n" "$run"
    printf "Prefix: \`%s\`\n" "$prefix"
    printf 'Threshold: %s consecutive widening review rounds\n\n' "$threshold"
    printf 'Each round below closed the previous round\047s findings under this prefix, and the review answered with at least one defect never seen before under it. Each round lists only those new defects; a round may also have re-returned a cluster from an earlier round, which does not stop the frontier from moving. The module or invariant these defects share is what keeps failing.\n\n'
    printf '## What this prefix returned, round by round\n\n'
    printf '%s\n' "$rounds"
    printf '\n## Decision\n\n'
    printf -- '- Fix at root. Repair the owning design before another review round.\n'
    printf -- '- Bank the remainder. Keep the current work and route the unresolved findings to a follow-up.\n'
    printf '\nFirstmate chooses under the task\047s existing authority rules.\n'
  } > "$tmp"
  mv "$tmp" "$path"
}

write_report() { # <path> <state-json> <clusters-json>
  local path=$1 state_json=$2 clusters=$3 threshold run details tmp shape
  shape=$(printf '%s' "$state_json" | jq -r '.surfaced.shape // "streak"')
  run=$(printf '%s' "$state_json" | jq -r '.run')
  if [ "$shape" = widening ]; then
    write_widening_report "$path" "$state_json" "$run" || return 1
    return 0
  fi
  threshold=$(printf '%s' "$state_json" | jq -r '.threshold')
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
  local task=$1 run='' head='' changed='' requested_threshold='' targeted_given=0
  local requested_widening=''
  local clusters='[]' targeted='[]'
  local state_file state_json threshold existing_run existing_threshold
  local new_state triggers generation key report round_count missing_target added
  local widening_threshold widening shape=streak widened_prefix='' active_threshold
  local ambient_widening widened_floor=0 widened_credited='[]'
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
      --targeted)
        [ "$#" -ge 2 ] || die "--targeted requires a value"
        valid_text "$2" 240 || die "--targeted must be 1-240 printable characters"
        targeted_given=1
        targeted=$(jq -cn --argjson current "$targeted" --arg cluster "$2" \
          '$current + [$cluster] | unique')
        shift 2
        ;;
      --threshold)
        [ "$#" -ge 2 ] || die "--threshold requires a value"
        requested_threshold=$2
        shift 2
        ;;
      --widening-threshold)
        [ "$#" -ge 2 ] || die "--widening-threshold requires a value"
        requested_widening=$2
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
  [ -z "$requested_widening" ] || valid_threshold "$requested_widening" ||
    die "widening threshold must be a positive integer"

  # No --targeted means this call was a fix attempt aimed at every cluster it
  # names. An explicit --targeted set must name only this call's clusters.
  if [ "$targeted_given" -eq 0 ]; then
    targeted=$clusters
  else
    missing_target=$(jq -rn --argjson clusters "$clusters" --argjson targeted "$targeted" \
      '($targeted - $clusters) | join(", ")')
    [ -z "$missing_target" ] || die "--targeted names clusters that are not --cluster values: $missing_target"
  fi

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
    threshold=${requested_threshold:-${FM_REVIEW_LOOP_THRESHOLD:-3}}
    valid_threshold "$threshold" || die "threshold must be a positive integer"
    widening_threshold=${requested_widening:-${FM_REVIEW_LOOP_WIDENING_THRESHOLD:-3}}
    valid_threshold "$widening_threshold" || die "widening threshold must be a positive integer"
    state_json=$(jq -cn --arg task "$task" --arg run "$run" --argjson threshold "$threshold" \
      --argjson widening "$widening_threshold" '
      {version: 1, task: $task, run: $run, threshold: $threshold,
       widening_threshold: $widening, generation: 1, rounds: [],
       widened: {}, surfaced: null, resolution: null}
    ')
  else
    existing_threshold=$(printf '%s' "$state_json" | jq -r '.threshold')
    if [ -n "$requested_threshold" ] && [ "$requested_threshold" != "$existing_threshold" ]; then
      die "run $run already uses review-loop threshold $existing_threshold"
    fi
    threshold=$existing_threshold
  fi
  # A run recorded before widening detection existed has no widening threshold
  # and no reset marker. Fall back to the ambient value so an in-flight run picks
  # the rule up without a schema migration.
  ambient_widening=${FM_REVIEW_LOOP_WIDENING_THRESHOLD:-3}
  widening_threshold=$(printf '%s' "$state_json" | jq -r '.widening_threshold // empty')
  if [ -n "$widening_threshold" ]; then
    if [ -n "$requested_widening" ] && [ "$requested_widening" != "$widening_threshold" ]; then
      die "run $run already uses review-loop widening threshold $widening_threshold"
    fi
  else
    widening_threshold=${requested_widening:-$ambient_widening}
  fi
  valid_threshold "$widening_threshold" || die "widening threshold must be a positive integer"
  state_json=$(printf '%s' "$state_json" | jq -c \
    --argjson widening "$widening_threshold" '.widening_threshold = $widening')
  active_threshold=$threshold

  if [ "$(printf '%s' "$state_json" | jq -r '.surfaced != null')" = true ]; then
    generation=$(printf '%s' "$state_json" | jq -r '.generation')
    key=$(status_key "$run" "$generation")
    triggers=$(printf '%s' "$state_json" | jq -c '.surfaced.clusters')
    report=$(printf '%s' "$state_json" | jq -r '.surfaced.report')
    shape=$(printf '%s' "$state_json" | jq -r '.surfaced.shape // "streak"')
    if [ "$shape" = widening ]; then
      active_threshold=$widening_threshold
    fi
    surface_status "$task" "$key" "$triggers" "$active_threshold" "$report"
    printf 'stop: review clusters already surfaced in %s\n' "$report"
    exit 20
  fi

  if printf '%s' "$state_json" | jq -e --arg head "$head" \
    '.rounds[]? | select(.head == $head)' >/dev/null; then
    # A retry of an already recorded head repeats a review round we have. It is
    # an idempotent no-op when it adds nothing, and an error when it would add a
    # cluster or targeting, because a fix round produces a new head to record
    # against instead.
    if printf '%s' "$state_json" | jq -e --arg head "$head" \
      --argjson clusters "$clusters" --argjson targeted "$targeted" '
      [.rounds[] | select(.head == $head)][-1] as $round
      | (($round.clusters + ($round.resolved // []))) as $recorded
      | (($round.targeted // $round.clusters) + ($round.resolved_aimed // $round.resolved // [])) as $aimed
      | ((($clusters - $recorded) | length) == 0)
        and ((($targeted - $aimed) | length) == 0)
    ' >/dev/null; then
      printf 'continue: reviewed head %s was already recorded\n' "$head"
      return 0
    fi
    added=$(printf '%s' "$state_json" | jq -r --arg head "$head" \
      --argjson clusters "$clusters" --argjson targeted "$targeted" '
      [.rounds[] | select(.head == $head)][-1] as $round
      | (($round.clusters + ($round.resolved // []))) as $recorded
      | (($round.targeted // $round.clusters) + ($round.resolved_aimed // $round.resolved // [])) as $aimed
      | [ (($clusters - $recorded) | map("cluster " + .))[],
          (($targeted - $aimed) | map("targeting for " + .))[] ]
      | join(", ")
    ')
    die "reviewed head $head is already recorded and a same-head retry cannot add clusters or change targeting; record $added against the current head instead"
  else
    new_state=$(printf '%s' "$state_json" | jq -c \
      --arg head "$head" --arg changed "$changed" \
      --argjson clusters "$clusters" --argjson targeted "$targeted" '
        .rounds += [{round: ((.rounds | length) + 1), head: $head,
                     changed: $changed, clusters: $clusters, targeted: $targeted}]
      ')
  fi
  triggers=$(printf '%s' "$new_state" | jq -c \
    --argjson threshold "$threshold" --argjson recorded "$clusters" '
    def trailing_count($rounds; $cluster):
      reduce ($rounds | reverse[]) as $round
        ({count: 0, open: true};
         if .open
            and ($round.clusters | index($cluster) != null)
            and ((($round.targeted // $round.clusters)) | index($cluster) != null)
         then .count += 1
         elif .open then .open = false
         else .
         end) | .count;
    .rounds as $rounds
    | [ $recorded[] as $cluster
        | select(trailing_count($rounds; $cluster) >= $threshold)
        | $cluster ]
  ')

  # A cluster streak takes precedence: it names one defect that survived repeated
  # aimed fixes, which is a sharper finding than the module-level shape below.
  if [ "$(printf '%s' "$triggers" | jq 'length')" -eq 0 ]; then
    widening=$(printf '%s' "$new_state" | jq -c \
      --argjson threshold "$widening_threshold" "$WIDENING_JQ")
    if [ "$(printf '%s' "$widening" | jq 'length')" -gt 0 ]; then
      shape=widening
      widened_prefix=$(printf '%s' "$widening" | jq -r '.[0].prefix')
      widened_floor=$(printf '%s' "$widening" | jq -r '.[0].floor')
      widened_credited=$(printf '%s' "$widening" | jq -c '.[0].credited')
      triggers=$(printf '%s' "$widening" | jq -c '.[0].clusters')
      active_threshold=$widening_threshold
    fi
  fi

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
    --argjson clusters "$triggers" --arg report "$report" \
    --arg shape "$shape" --arg prefix "$widened_prefix" \
    --argjson floor "${widened_floor:-0}" \
    --argjson credited "$widened_credited" \
    --argjson widening_threshold "$widening_threshold" '
      .surfaced = {clusters: $clusters, report: $report, shape: $shape}
      | if $shape == "widening" then
          .surfaced.prefix = $prefix
          | .surfaced.floor = $floor
          | .surfaced.credited = $credited
          | .surfaced.threshold = $widening_threshold
        else . end
    ')
  write_report "$report" "$new_state" "$triggers" || die "could not write review-loop report"
  atomic_write "$state_file" "$new_state" || die "could not save surfaced review-loop state"
  surface_status "$task" "$key" "$triggers" "$active_threshold" "$report" ||
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

  # A widening stop is answered per prefix, not per cluster. Its clusters are the
  # only record of which defects this run has already seen, so stripping them the
  # way a streak resolution does would make old defects look new and re-trip the
  # rule. Move the prefix floor past the recorded rounds instead: that prefix
  # starts a fresh widening count while every other prefix keeps its own.
  if [ "$(printf '%s' "$state_json" | jq -r '.surfaced.shape // "streak"')" = widening ]; then
    state_json=$(printf '%s' "$state_json" | jq -c --arg decision "$decision" '
      .resolution = {
        choice: $decision,
        shape: "widening",
        generation: .generation,
        prefix: .surfaced.prefix,
        clusters: .surfaced.clusters,
        report: .surfaced.report
      }
      | .generation += 1
      | .widened = ((.widened // {}) + {(.surfaced.prefix): (.rounds | length)})
      | .surfaced = null
    ')
    atomic_write "$state_file" "$state_json" || die "could not save review-loop resolution"
    printf 'resolved: review-loop stop for %s recorded as %s\n' "$run" "$decision"
    return 0
  fi

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
    | .rounds |= map(
        ((.targeted // .clusters) - ((.targeted // .clusters) - $resolved)) as $aimed
        | .resolved_aimed = (((.resolved_aimed // .resolved // []) + $aimed) | unique)
        | .resolved = (((.resolved // []) + (.clusters - (.clusters - $resolved)))
                     | unique)
        | .clusters = (.clusters - $resolved)
        | .targeted = ((.targeted // .clusters) - $resolved))
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
