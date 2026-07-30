#!/usr/bin/env bash
# Exact OMP process identity shared by primary ancestry and backend liveness probes.
# Bun may publish comm=omp as its process title, but argv must still begin with the exact `bun .../omp` boundary.
# This file has no side effects when sourced.

fm_omp_process_matches() {  # <comm-or-path> <args>
  local comm=$1 args=$2 first second rest
  comm=$(basename -- "$comm")
  case "$comm" in bun|omp) ;; *) return 1 ;; esac
  read -r first second rest <<EOF
$args
EOF
  [ "$(basename -- "${first:-}")" = bun ] \
    && [ "$(basename -- "${second:-}")" = omp ]
}
