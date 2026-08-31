#!/usr/bin/env bash
# Resolve one crewmate or scout dispatch class from config/crew-dispatch.json.
# Usage: fm-dispatch-resolve.sh --class <class> [--home <FM_HOME>] [--override-harness <harness>] [--override-model <model>] [--override-effort <effort>]
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
OVERRIDE_HARNESS=
OVERRIDE_MODEL=
OVERRIDE_EFFORT=
OVERRIDE_HARNESS_SET=0
OVERRIDE_MODEL_SET=0
OVERRIDE_EFFORT_SET=0
want_value=

for arg in "$@"; do
  if [ -n "$want_value" ]; then
    case "$arg" in
      --*) echo "error: --$want_value requires a value" >&2; exit 2 ;;
    esac
    case "$want_value" in
      class) DISPATCH_CLASS=$arg ;;
      home) DISPATCH_HOME=$arg ;;
      override-harness) OVERRIDE_HARNESS=$arg; OVERRIDE_HARNESS_SET=1 ;;
      override-model) OVERRIDE_MODEL=$arg; OVERRIDE_MODEL_SET=1 ;;
      override-effort) OVERRIDE_EFFORT=$arg; OVERRIDE_EFFORT_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$arg" in
    --class) want_value=class ;;
    --class=*) DISPATCH_CLASS=${arg#--class=} ;;
    --home) want_value=home ;;
    --home=*) DISPATCH_HOME=${arg#--home=} ;;
    --override-harness) want_value=override-harness ;;
    --override-harness=*) OVERRIDE_HARNESS=${arg#--override-harness=}; OVERRIDE_HARNESS_SET=1 ;;
    --override-model) want_value=override-model ;;
    --override-model=*) OVERRIDE_MODEL=${arg#--override-model=}; OVERRIDE_MODEL_SET=1 ;;
    --override-effort) want_value=override-effort ;;
    --override-effort=*) OVERRIDE_EFFORT=${arg#--override-effort=}; OVERRIDE_EFFORT_SET=1 ;;
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
[ "$OVERRIDE_HARNESS_SET" -eq 0 ] || [ -n "$OVERRIDE_HARNESS" ] || { echo "error: --override-harness requires a non-empty value" >&2; exit 2; }
[ "$OVERRIDE_MODEL_SET" -eq 0 ] || [ -n "$OVERRIDE_MODEL" ] || { echo "error: --override-model requires a non-empty value" >&2; exit 2; }
[ "$OVERRIDE_EFFORT_SET" -eq 0 ] || [ -n "$OVERRIDE_EFFORT" ] || { echo "error: --override-effort requires a non-empty value" >&2; exit 2; }
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
VALIDATION_ERROR=
VALIDATOR_ARGS=(--file "$CONFIG_FILE" --normalized)
if [ "$OVERRIDE_HARNESS_SET" -eq 1 ] || [ "$OVERRIDE_MODEL_SET" -eq 1 ] || [ "$OVERRIDE_EFFORT_SET" -eq 1 ]; then
  VALIDATOR_ARGS+=(--allow-disabled-pin)
fi
if ! NORMALIZED_CONFIG=$("$SCRIPT_DIR/fm-dispatch-validate.sh" "${VALIDATOR_ARGS[@]}" 2>&1); then
  VALIDATION_ERROR=$NORMALIZED_CONFIG
  echo "error: invalid config/crew-dispatch.json - $VALIDATION_ERROR" >&2
  exit 1
fi

config_jq() {
  jq "$@" <<< "$NORMALIZED_CONFIG"
}

MATCH_COUNT=$(config_jq -r --arg class "$DISPATCH_CLASS" '
  [(.rules // [])[]? | select(.class == $class)] | length
')
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
  config_jq -r --arg class "$DISPATCH_CLASS" --arg kind "$POOL_KIND" '
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
  '
}

PIN_TSV=$(config_jq -r --arg class "$DISPATCH_CLASS" --arg kind "$POOL_KIND" --arg pin "$PIN_KEY" '
  if $kind == "class" then
    [(.rules // [])[]? | select(.class == $class)][0][$pin]
  else
    .[$pin]
  end
  | if type == "object" then [(.harness // ""), (.model // "default"), (.effort // "default")] | @tsv else "" end
')

if [ -n "$PIN_TSV" ]; then
  SELECT_REASON=$PIN_REASON
  IFS=$'\t' read -r PIN_HARNESS PIN_MODEL PIN_EFFORT <<< "$PIN_TSV"
  PIN_FOUND=0
  PIN_ENABLED=0
  while IFS=$'\t' read -r harness model effort enabled; do
    [ -n "$harness" ] || continue
    if [ "$harness" = "$PIN_HARNESS" ] && [ "$model" = "$PIN_MODEL" ] && [ "$effort" = "$PIN_EFFORT" ]; then
      PIN_FOUND=1
      if [ "$enabled" = false ]; then
        continue
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
  if [ "$PIN_ENABLED" -ne 1 ] && [ "$OVERRIDE_HARNESS_SET" -eq 0 ] \
    && [ "$OVERRIDE_MODEL_SET" -eq 0 ] && [ "$OVERRIDE_EFFORT_SET" -eq 0 ]; then
    echo "error: $PIN_KEY for '$DISPATCH_CLASS' names a switched-off member" >&2
    exit 1
  fi
  BEST_HARNESS=$PIN_HARNESS
  BEST_MODEL=$PIN_MODEL
  BEST_EFFORT=$PIN_EFFORT
  BEST_COUNT=0
else
  SELECT_REASON=$ROUND_REASON
  BEST_HARNESS=
  BEST_MODEL=
  BEST_EFFORT=
  BEST_COUNT=
fi

if [ -z "$PIN_TSV" ]; then
  if [ "$OVERRIDE_HARNESS_SET" -eq 1 ] && [ "$OVERRIDE_MODEL_SET" -eq 1 ] \
    && [ "$OVERRIDE_EFFORT_SET" -eq 1 ]; then
    BEST_HARNESS=$OVERRIDE_HARNESS
    BEST_MODEL=$OVERRIDE_MODEL
    BEST_EFFORT=$OVERRIDE_EFFORT
    BEST_COUNT=0
  else
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
  fi
fi

[ -n "$BEST_HARNESS" ] || {
  echo "error: dispatch pool for '$DISPATCH_CLASS' has no enabled member" >&2
  exit 1
}

[ "$OVERRIDE_HARNESS_SET" -eq 0 ] || BEST_HARNESS=$OVERRIDE_HARNESS
[ "$OVERRIDE_MODEL_SET" -eq 0 ] || BEST_MODEL=$OVERRIDE_MODEL
[ "$OVERRIDE_EFFORT_SET" -eq 0 ] || BEST_EFFORT=$OVERRIDE_EFFORT

if [ "$OVERRIDE_HARNESS_SET" -eq 1 ] || [ "$OVERRIDE_MODEL_SET" -eq 1 ] || [ "$OVERRIDE_EFFORT_SET" -eq 1 ]; then
  "$SCRIPT_DIR/fm-dispatch-validate.sh" --runtime \
    "$BEST_HARNESS" "$BEST_MODEL" "$BEST_EFFORT" \
    --label "captain override for class '$DISPATCH_CLASS'" || exit 1
  MATCH_FOUND=0
  MATCH_ENABLED=0
  while IFS=$'\t' read -r harness model effort enabled; do
    [ "$harness" = "$BEST_HARNESS" ] && [ "$model" = "$BEST_MODEL" ] && [ "$effort" = "$BEST_EFFORT" ] || continue
    MATCH_FOUND=1
    if [ "$enabled" != false ]; then
      MATCH_ENABLED=1
      break
    fi
  done < <(profiles_tsv)
  if [ "$MATCH_FOUND" -eq 1 ] && [ "$MATCH_ENABLED" -eq 0 ]; then
    echo "error: captain override selects disabled member harness=$BEST_HARNESS model=$BEST_MODEL effort=$BEST_EFFORT; re-enable it in config/crew-dispatch.json" >&2
    exit 1
  fi
fi
printf 'harness=%s model=%s effort=%s reason=%s\n' "$BEST_HARNESS" "$BEST_MODEL" "$BEST_EFFORT" "$SELECT_REASON"
