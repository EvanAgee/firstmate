#!/usr/bin/env bash
# shellcheck shell=bash
# Adapter support tables for the deterministic crew dispatch contract: which
# verified harnesses a dispatch profile may name, and which effort values that
# harness accepts for a profile or a resolved runtime tuple.
# Usage: . bin/fm-dispatch-runtime-lib.sh
#
# Ownership: bin/fm-control-lib.sh's fm_control_harnesses owns the verified
# harness list itself (it mirrors AGENTS.md section 4), and this lib sources
# it rather than keeping a second copy that drifts one adapter at a time.
# The effort matrix mirrors bin/fm-spawn.sh's per-harness launch-flag mapping
# record-and-omit contract: an effort a harness has no case for is refused
# here for a configured profile; a harness with no entry at all (gemini)
# admits any value, which the launch side records in task metadata and omits
# from its launch flags (the record-and-omit contract).

_DISPATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-control-lib.sh
. "$_DISPATCH_LIB_DIR/fm-control-lib.sh"

fm_dispatch_harnesses() {
  fm_control_harnesses
}

fm_dispatch_harness_supported() {
  local h
  while read -r h; do
    [ "$h" = "${1-}" ] && return 0
  done < <(fm_dispatch_harnesses)
  return 1
}

fm_dispatch_model_supported() {
  local harness=$1 model=$2
  fm_dispatch_harness_supported "$harness" || return 1
  [ -n "$model" ] || return 1
  case "$model" in *[[:space:]]*) return 1 ;; esac
  return 0
}

# Accepted efforts for a harness, as a comma list for messages. "default" is
# always accepted (it means the harness's own default axis) and is never
# listed here. Two efforts are model-scoped and so cannot be expressed by a
# per-harness list at all: codex "max" applies only to gpt-5.6-luna, and
# "ultra" applies only to pi/pi-signed codex-native/* models. They are left
# out of this list and printed by fm_dispatch_effort_note as a trailing
# clause; fm_dispatch_effort_ok owns the verdict for both.
fm_dispatch_efforts() {
  local harness=$1
  fm_dispatch_harness_supported "$harness" || return 1
  case "$harness" in
    claude|omp|muse) printf '%s\n' "low, medium, high, xhigh, max" ;;
    pi|pi-signed) printf '%s\n' "low, medium, high, xhigh, max" ;;
    codex) printf '%s\n' "low, medium, high, xhigh" ;;
    grok|agy) printf '%s\n' "low, medium, high" ;;
    rovo) printf '%s\n' "low, medium, high, max" ;;
    opencode|kimi|cursor) printf '%s\n' "" ;;
    # A harness with no effort case in bin/fm-spawn.sh's record-and-omit flag
    # mapping (gemini today) admits any value here; the launch side records it
    # in task metadata and omits it from the launch flags.
    *) printf '%s\n' "" ;;
  esac
}

# The model-scoped efforts fm_dispatch_efforts cannot list, as a trailing
# clause for an error message, or empty when the harness has none.
fm_dispatch_effort_note() {
  case "$1" in
    codex) printf '%s\n' "max applies only to gpt-5.6-luna" ;;
    pi|pi-signed) printf '%s\n' "ultra applies only to codex-native/* models" ;;
    *) printf '%s\n' "" ;;
  esac
}

# fm_dispatch_effort_ok <harness> <model> <effort>
# "default" (or empty) always passes: it selects the harness's own default
# effort axis. A harness with no effort case in bin/fm-spawn.sh's flag mapping
# admits any value here (record-and-omit: the launch side records it in task
# metadata and omits it from the launch flags).
fm_dispatch_effort_ok() {
  local harness=$1 model=$2 effort=$3
  case "$effort" in ''|default) return 0 ;; esac
  fm_dispatch_harness_supported "$harness" || return 1
  case "$effort" in
    ultra)
      case "$harness" in
        pi|pi-signed)
          case "$model" in codex-native/?*) return 0 ;; esac
          ;;
      esac
      return 1
      ;;
  esac
  case "$harness" in
    claude|pi|pi-signed|omp|muse)
      case "$effort" in low|medium|high|xhigh|max) return 0 ;; esac ;;
    codex)
      case "$effort" in
        low|medium|high|xhigh) return 0 ;;
        max) [ "$model" = gpt-5.6-luna ] && return 0 ;;
      esac
      ;;
    grok|agy)
      case "$effort" in low|medium|high) return 0 ;; esac ;;
    rovo)
      case "$effort" in low|medium|high|max) return 0 ;; esac ;;
    opencode|kimi|cursor) : ;;
    # A harness with no effort case in bin/fm-spawn.sh's record-and-omit flag
    # mapping (gemini today) admits any value here; the launch side records it
    # in task metadata and omits it from the launch flags.
    *) return 0 ;;
  esac
  return 1
}

fm_dispatch_runtime_validate() {
  local label=$1 harness=$2 model=$3 effort=$4 supported note harnesses field value
  for field in harness model effort; do
    case "$field" in
      harness) value=$harness ;;
      model) value=$model ;;
      effort) value=$effort ;;
    esac
    case "$value" in
      *[[:space:]]*)
        printf 'runtime values cannot contain whitespace: %s %s="%s"\n' \
          "$label" "$field" "$value" >&2
        return 1
        ;;
    esac
  done
  if ! fm_dispatch_harness_supported "$harness"; then
    # paste -d takes a LIST of delimiters it cycles through, so ", " would
    # alternate comma and space rather than joining with ", ".
    harnesses=$(fm_dispatch_harnesses | tr '\n' ' ')
    printf "unsupported harness '%s' for %s; supported harnesses: %s\n" \
      "$harness" "$label" "$(printf '%s' "${harnesses% }" | sed 's/ /, /g')" >&2
    return 1
  fi
  if ! fm_dispatch_model_supported "$harness" "$model"; then
    printf "unsupported model '%s' for %s harness '%s'; use a non-whitespace model ID or default\n" \
      "$model" "$label" "$harness" >&2
    return 1
  fi
  if ! fm_dispatch_effort_ok "$harness" "$model" "$effort"; then
    supported=$(fm_dispatch_efforts "$harness")
    note=$(fm_dispatch_effort_note "$harness")
    [ -z "$note" ] || note="; $note"
    if [ -n "$supported" ]; then
      printf "unsupported effort '%s' for %s harness '%s'; supported efforts: %s, or omit effort%s\n" \
        "$effort" "$label" "$harness" "$supported" "$note" >&2
    else
      printf "unsupported effort '%s' for %s harness '%s'; omit effort for this harness%s\n" \
        "$effort" "$label" "$harness" "$note" >&2
    fi
    return 1
  fi
}
