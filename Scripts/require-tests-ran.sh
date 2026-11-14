#!/usr/bin/env bash
# Scripts/require-tests-ran.sh MIN COMMAND [ARG...]
#
# Runs COMMAND (a `swift test` invocation, possibly wrapped in unshare,
# setpriv, aa-exec or docker) and fails unless it reports a passed Swift
# Testing run of at least MIN tests. `swift test --filter` exits 0 when the
# filter matches nothing, so a renamed test or a condition that stopped
# enabling it would otherwise pass by not running.
set -euo pipefail

if [[ $# -lt 2 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  printf 'usage: require-tests-ran.sh MIN COMMAND [ARG...]\n' >&2
  exit 2
fi
minimum="$1"
shift

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

status=0
"$@" 2>&1 | tee "$log" || status=$?
if [[ "$status" -ne 0 ]]; then
  printf 'require-tests-ran: command failed (%s)\n' "$status" >&2
  exit "$status"
fi

# "✔ Test run with 12 tests in 2 suites passed after 0.5 seconds."
ran="$(sed 's/\x1b\[[0-9;]*m//g' "$log" \
  | sed -n 's/^.*Test run with \([0-9][0-9]*\) tests\{0,1\} in [0-9][0-9]* suites\{0,1\} passed.*$/\1/p' \
  | tail -n 1)"
if [[ -z "$ran" ]]; then
  printf 'require-tests-ran: no passed test run was reported\n' >&2
  exit 1
fi
if [[ "$ran" -lt "$minimum" ]]; then
  printf 'require-tests-ran: %s tests ran, at least %s were required\n' "$ran" "$minimum" >&2
  exit 1
fi
printf 'require-tests-ran: %s tests ran (at least %s required)\n' "$ran" "$minimum" >&2
