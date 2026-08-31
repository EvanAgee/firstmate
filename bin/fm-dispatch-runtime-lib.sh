#!/usr/bin/env bash

FM_DISPATCH_HARNESSES="claude codex opencode omp pi pi-signed grok kimi cursor muse"

fm_dispatch_harness_supported() {
  case " $FM_DISPATCH_HARNESSES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_dispatch_efforts() {
  case "$1" in
    claude|omp|pi|pi-signed|muse) printf '%s\n' "low medium high xhigh max" ;;
    codex) printf '%s\n' "low medium high xhigh" ;;
    grok) printf '%s\n' "low medium high" ;;
    opencode|kimi|cursor) printf '%s\n' "" ;;
    *) return 1 ;;
  esac
}

fm_dispatch_model_supported() {
  local harness=$1 model=$2
  fm_dispatch_harness_supported "$harness" || return 1
  [ -n "$model" ] || return 1
  case "$model" in *[[:space:]]*) return 1 ;; esac
  return 0
}

fm_dispatch_effort_supported() {
  local harness=$1 effort=$2 supported
  [ "$effort" = default ] && return 0
  supported=$(fm_dispatch_efforts "$harness") || return 1
  case " $supported " in
    *" $effort "*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_dispatch_runtime_validate() {
  local label=$1 harness=$2 model=$3 effort=$4 supported field value
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
    printf "unsupported harness '%s' for %s; supported harnesses: %s\n" \
      "$harness" "$label" "${FM_DISPATCH_HARNESSES// /, }" >&2
    return 1
  fi
  if ! fm_dispatch_model_supported "$harness" "$model"; then
    printf "unsupported model '%s' for %s harness '%s'; use a non-whitespace model ID or default\n" \
      "$model" "$label" "$harness" >&2
    return 1
  fi
  if ! fm_dispatch_effort_supported "$harness" "$effort"; then
    supported=$(fm_dispatch_efforts "$harness")
    if [ -n "$supported" ]; then
      printf "unsupported effort '%s' for %s harness '%s'; supported efforts: %s, or omit effort\n" \
        "$effort" "$label" "$harness" "${supported// /, }" >&2
    else
      printf "unsupported effort '%s' for %s harness '%s'; omit effort for this harness\n" \
        "$effort" "$label" "$harness" >&2
    fi
    return 1
  fi
}
