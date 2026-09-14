#!/usr/bin/env bash
trap "" TERM
printf "%s\n" "$$" > "$FM_TEST_CUSTOM_CHILD_PID"
while :; do sleep 1; done
