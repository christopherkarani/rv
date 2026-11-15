#!/usr/bin/env bash
# Scripts/ci-test-failures.sh NAME LOG
#
# Prints what failed in a saved `swift test` log: each recorded issue with
# the lines of its message, each failed test and suite, and anything a
# crash, a compile error or the watchdog printed. Called last in a CI step,
# so the reason a step failed is in the job log's final lines, which is
# all the log API and a truncated viewer show of a long run.
set -uo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s NAME LOG\n' "$(basename "$0")" >&2
  exit 2
fi
name="$1"
log="$2"
limit="${RV_CI_FAILURE_LINES:-300}"

printf '== %s failed. What its log says failed:\n' "$name"
if [[ ! -r "$log" ]]; then
  printf '(no log at %s)\n' "$log"
  exit 0
fi
found="$(grep -E -A 12 \
  'recorded an issue|failed after [0-9.]+ seconds|ci-watchdog|^error:|\.swift:[0-9]+:[0-9]+: error:|Fatal error|unexpected signal' \
  "$log" | tail -n "$limit")"
if [[ -n "$found" ]]; then
  printf '%s\n' "$found"
else
  # Nothing recognised: the end of the log is the best there is.
  printf '(no failure line recognised; the last lines follow)\n'
  tail -n 60 "$log"
fi
