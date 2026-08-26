#!/usr/bin/env bash
# fm-builder-split.sh - choose one healthy rung from an ordinary builder split.
#
# The caller has already matched one crew-dispatch rule and judged the task tier.
# This helper does not classify tasks, inspect quota, or decide candidate health.
# It reads only the matched rule's split weights, accepts the healthy harnesses
# established by quota-array-dispatch, and advances one durable per-home counter.
#
# A high-tier builder prints `bypass` and leaves the counter untouched.
# An ordinary builder prints the selected harness, or `fallback` when no split
# harness is healthy so the caller can continue down the configured ladder.
# Missing or malformed split weights use codex=50 and pi=50 and emit a note on
# stderr. The counter starts at zero when absent. A malformed counter also resets
# to zero with a note. Counter writes use an atomic rename.
#
# Usage:
#   fm-builder-split.sh --rule-index <zero-based-index> [--config <path>]
#     [--healthy <harness>]... [--high-tier]
#
# Environment:
#   FM_HOME             home whose state counter is updated
#   FM_ROOT_OVERRIDE    tracked code root override used by tests and secondmates
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="$FM_HOME/state"
CONFIG="$FM_HOME/config/crew-dispatch.json"
COUNTER_FILE="$STATE/.builder-dispatch-counter"
RULE_INDEX=
HIGH_TIER=0
declare -a HEALTHY=()

usage() {
  cat <<'EOF'
fm-builder-split.sh - choose an ordinary builder's weighted split harness

Usage:
  fm-builder-split.sh --rule-index <zero-based-index> [--config <path>]
    [--healthy <harness>]... [--high-tier]

The caller supplies each split harness that current quota and authentication
evidence found healthy. The script prints a harness name, `fallback` when none
of the split harnesses is healthy, or `bypass` for a high-tier builder.

Ordinary calls advance FM_HOME/state/.builder-dispatch-counter. High-tier calls
do not read or change it. Missing or malformed split weights use the built-in
codex=50 and pi=50 split and print a note on stderr.
EOF
}

die_usage() {
  printf 'fm-builder-split: %s\n' "$1" >&2
  printf 'usage: fm-builder-split.sh --rule-index <zero-based-index> [--config <path>] [--healthy <harness>]... [--high-tier]\n' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rule-index)
      [ $# -ge 2 ] || die_usage "--rule-index needs a value"
      RULE_INDEX=$2
      shift 2
      ;;
    --config)
      [ $# -ge 2 ] || die_usage "--config needs a value"
      CONFIG=$2
      shift 2
      ;;
    --healthy)
      [ $# -ge 2 ] || die_usage "--healthy needs a harness"
      HEALTHY+=("$2")
      shift 2
      ;;
    --high-tier)
      HIGH_TIER=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
done

[ "$HIGH_TIER" -eq 1 ] && { printf 'bypass\n'; exit 0; }

case "$RULE_INDEX" in
  ''|*[!0-9]*) die_usage "--rule-index must be a zero-based integer" ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf 'fm-builder-split: jq is required\n' >&2
  exit 1
}

DEFAULT_SPLIT='{"codex":50,"pi":50}'
SPLIT_JSON=
SPLIT_STATE=invalid

if [ -f "$CONFIG" ] && jq -e --argjson index "$RULE_INDEX" \
  '.rules | type == "array" and .[$index] != null' "$CONFIG" >/dev/null 2>&1; then
  if jq -e --argjson index "$RULE_INDEX" '.rules[$index] | has("split")' \
    "$CONFIG" >/dev/null 2>&1; then
    SPLIT_JSON=$(jq -c --argjson index "$RULE_INDEX" '.rules[$index].split' \
      "$CONFIG" 2>/dev/null || true)
    SPLIT_STATE=present
  else
    SPLIT_STATE=absent
  fi
fi

split_is_valid() {
  printf '%s\n' "$1" | jq -e --argjson index "$RULE_INDEX" --slurpfile config "$CONFIG" '
    . as $split
    | ($config[0].rules[$index].use
       | if type == "array" then . else [.] end
       | map(select((.enabled // true) == true) | .harness)) as $enabled
    | type == "object"
      and length >= 2
      and ([to_entries[]
            | (.key | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
              and (.value | type == "number" and floor == . and . > 0)
              and (.key as $key | $enabled | index($key) != null)] | all)
      and ([.[]] | add == 100)
  ' >/dev/null 2>&1
}

if [ "$SPLIT_STATE" = present ] && split_is_valid "$SPLIT_JSON"; then
  WEIGHTS=$SPLIT_JSON
elif [ "$SPLIT_STATE" = absent ]; then
  WEIGHTS=$DEFAULT_SPLIT
  printf 'BUILDER_DISPATCH: split absent for rule %s; using codex=50, pi=50\n' "$RULE_INDEX" >&2
else
  WEIGHTS=$DEFAULT_SPLIT
  printf 'BUILDER_DISPATCH: split malformed for rule %s; using codex=50, pi=50\n' "$RULE_INDEX" >&2
fi

mkdir -p "$STATE" || {
  printf 'fm-builder-split: could not create state directory %s\n' "$STATE" >&2
  exit 1
}

COUNTER=0
if [ -e "$COUNTER_FILE" ]; then
  IFS= read -r COUNTER < "$COUNTER_FILE" || COUNTER=
  case "$COUNTER" in
    ''|*[!0-9]*)
      printf 'BUILDER_DISPATCH: malformed counter; resetting to zero\n' >&2
      COUNTER=0
      ;;
  esac
fi

PLAN=$(printf '%s\n' "$WEIGHTS" | jq -r 'to_entries[] | [.key, .value] | @tsv' | awk -F '\t' -v counter="$COUNTER" '
  {
    count++
    name[count] = $1
    weight[count] = $2
    total += $2
  }
  END {
    target = counter % total
    for (step = 0; step <= target; step++) {
      selected = 1
      for (i = 1; i <= count; i++) {
        current[i] += weight[i]
        if (current[i] > current[selected]) {
          selected = i
        }
      }
      current[selected] -= total
    }
    print name[selected]
  }
')

is_healthy() {
  local candidate
  for candidate in "${HEALTHY[@]+"${HEALTHY[@]}"}"; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

SELECTED=fallback
if is_healthy "$PLAN"; then
  SELECTED=$PLAN
else
  while IFS= read -r candidate; do
    if is_healthy "$candidate"; then
      SELECTED=$candidate
      break
    fi
  done < <(printf '%s\n' "$WEIGHTS" | jq -r 'keys_unsorted[]')
fi

NEXT_COUNTER=$((10#$COUNTER + 1))
TMP_COUNTER=$(mktemp "$STATE/.builder-dispatch-counter.tmp.XXXXXX") || {
  printf 'fm-builder-split: could not create counter update\n' >&2
  exit 1
}
cleanup() {
  [ -z "${TMP_COUNTER:-}" ] || rm -f "$TMP_COUNTER"
}
trap cleanup EXIT HUP INT TERM
printf '%s\n' "$NEXT_COUNTER" > "$TMP_COUNTER"
mv "$TMP_COUNTER" "$COUNTER_FILE"
TMP_COUNTER=
trap - EXIT HUP INT TERM

printf '%s\n' "$SELECTED"
