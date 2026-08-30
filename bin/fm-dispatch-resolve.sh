#!/usr/bin/env bash
# Resolve one crewmate or scout dispatch class from config/crew-dispatch.json.
# Usage: fm-dispatch-resolve.sh --class <class> [--home <FM_HOME>]
# Prints exactly one successful result:
#   harness=<h> model=<m> effort=<e> reason=<pin|round-robin|default-pin|default>
# A class absent from rules uses the default pool.
# Pins select their exact pool member when enabled.
# Unpinned pools select the enabled member with the fewest matching live
# state/*.meta workers in this home, excluding kind=secondmate, with list order
# breaking ties.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH_CLASS=
DISPATCH_HOME=${FM_HOME:-$FM_ROOT}
want_value=

for arg in "$@"; do
  if [ -n "$want_value" ]; then
    case "$arg" in
      --*) echo "error: --$want_value requires a value" >&2; exit 2 ;;
    esac
    case "$want_value" in
      class) DISPATCH_CLASS=$arg ;;
      home) DISPATCH_HOME=$arg ;;
    esac
    want_value=
    continue
  fi
  case "$arg" in
    --class) want_value=class ;;
    --class=*) DISPATCH_CLASS=${arg#--class=} ;;
    --home) want_value=home ;;
    --home=*) DISPATCH_HOME=${arg#--home=} ;;
    -h|--help)
      sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
[ -n "$DISPATCH_CLASS" ] || { echo "error: --class requires a non-empty value" >&2; exit 2; }
[ -n "$DISPATCH_HOME" ] || { echo "error: --home requires a non-empty value" >&2; exit 2; }
case "$DISPATCH_HOME" in
  /*) : ;;
  *)
    DISPATCH_HOME=$(CDPATH='' cd -- "$DISPATCH_HOME" 2>/dev/null && pwd -P) || {
      echo "error: home directory cannot be resolved: $DISPATCH_HOME" >&2
      exit 1
    }
    ;;
esac

CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$DISPATCH_HOME/config}/crew-dispatch.json"
STATE_DIR="${FM_STATE_OVERRIDE:-$DISPATCH_HOME/state}"
[ -f "$CONFIG_FILE" ] || {
  echo "error: no config/crew-dispatch.json in $DISPATCH_HOME" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to resolve crew dispatch" >&2
  exit 1
}
jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || {
  echo "error: config/crew-dispatch.json is malformed" >&2
  exit 1
}

MATCH_COUNT=$(jq -r --arg class "$DISPATCH_CLASS" '
  [(.rules // [])[]? | select(.class == $class)] | length
' "$CONFIG_FILE")
if [ "$MATCH_COUNT" -gt 1 ]; then
  echo "error: dispatch class '$DISPATCH_CLASS' appears more than once" >&2
  exit 1
fi

if [ "$MATCH_COUNT" -eq 1 ]; then
  POOL_KIND=class
  PIN_KEY=pin
  PIN_REASON=pin
  ROUND_REASON=round-robin
else
  POOL_KIND=default
  PIN_KEY=defaultPin
  PIN_REASON=default-pin
  ROUND_REASON=default
fi

profiles_tsv() {
  jq -r --arg class "$DISPATCH_CLASS" --arg kind "$POOL_KIND" '
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    if $kind == "class" then
      [(.rules // [])[]? | select(.class == $class)][0].use
    else
      .default
    end
    | profiles(.)[]?
    | [(.harness // ""), (.model // "default"), (.effort // "default"), (if .enabled? == false then "false" else "true" end)]
    | @tsv
  ' "$CONFIG_FILE"
}

PIN_TSV=$(jq -r --arg class "$DISPATCH_CLASS" --arg kind "$POOL_KIND" --arg pin "$PIN_KEY" '
  if $kind == "class" then
    [(.rules // [])[]? | select(.class == $class)][0][$pin]
  else
    .[$pin]
  end
  | if type == "object" then [(.harness // ""), (.model // "default"), (.effort // "default")] | @tsv else "" end
' "$CONFIG_FILE")

if [ -n "$PIN_TSV" ]; then
  IFS=$'\t' read -r PIN_HARNESS PIN_MODEL PIN_EFFORT <<< "$PIN_TSV"
  PIN_FOUND=0
  PIN_ENABLED=0
  while IFS=$'\t' read -r harness model effort enabled; do
    [ -n "$harness" ] || continue
    if [ "$harness" = "$PIN_HARNESS" ] && [ "$model" = "$PIN_MODEL" ] && [ "$effort" = "$PIN_EFFORT" ]; then
      PIN_FOUND=1
      if [ "$enabled" = false ]; then
        PIN_ENABLED=0
      else
        PIN_ENABLED=1
      fi
      break
    fi
  done < <(profiles_tsv)
  [ "$PIN_FOUND" -eq 1 ] || {
    echo "error: $PIN_KEY for '$DISPATCH_CLASS' is not a member of its pool" >&2
    exit 1
  }
  [ "$PIN_ENABLED" -eq 1 ] || {
    echo "error: $PIN_KEY for '$DISPATCH_CLASS' names a switched-off member" >&2
    exit 1
  }
  printf 'harness=%s model=%s effort=%s reason=%s\n' "$PIN_HARNESS" "$PIN_MODEL" "$PIN_EFFORT" "$PIN_REASON"
  exit 0
fi

BEST_HARNESS=
BEST_MODEL=
BEST_EFFORT=
BEST_COUNT=
while IFS=$'\t' read -r harness model effort enabled; do
  [ -n "$harness" ] || continue
  [ "$enabled" = false ] && continue
  count=0
  for meta in "$STATE_DIR"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
    [ "$kind" != secondmate ] || continue
    meta_harness=$(sed -n 's/^harness=//p' "$meta" | head -n 1)
    meta_model=$(sed -n 's/^model=//p' "$meta" | head -n 1)
    meta_effort=$(sed -n 's/^effort=//p' "$meta" | head -n 1)
    [ -n "$meta_model" ] || meta_model=default
    [ -n "$meta_effort" ] || meta_effort=default
    if [ "$meta_harness" = "$harness" ] && [ "$meta_model" = "$model" ] && [ "$meta_effort" = "$effort" ]; then
      count=$((count + 1))
    fi
  done
  if [ -z "$BEST_COUNT" ] || [ "$count" -lt "$BEST_COUNT" ]; then
    BEST_HARNESS=$harness
    BEST_MODEL=$model
    BEST_EFFORT=$effort
    BEST_COUNT=$count
  fi
done < <(profiles_tsv)

[ -n "$BEST_HARNESS" ] || {
  echo "error: dispatch pool for '$DISPATCH_CLASS' has no enabled member" >&2
  exit 1
}
printf 'harness=%s model=%s effort=%s reason=%s\n' "$BEST_HARNESS" "$BEST_MODEL" "$BEST_EFFORT" "$ROUND_REASON"
