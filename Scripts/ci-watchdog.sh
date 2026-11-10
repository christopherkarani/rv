#!/usr/bin/env bash
# Scripts/ci-watchdog.sh SECONDS COMMAND [ARG...]
#
# Runs COMMAND with a wall-clock limit. On a stall it prints the process
# tree and, on macOS, a `sample` of every test-runner process (the stacks
# name the test that is stuck), then kills the tree and exits 124.
#
# Exists because `swift test` block-buffers each test product's output:
# a hung product prints nothing at all, and the job timeout then kills it
# with no hint of which test was running.
set -uo pipefail

if [[ $# -lt 2 ]] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
  printf 'usage: %s SECONDS COMMAND [ARG...]\n' "$(basename "$0")" >&2
  exit 2
fi
limit="$1"
shift
poll="${RV_WATCHDOG_POLL_SECONDS:-5}"

descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "$child"
    descendants "$child"
  done
}

dump() {
  local root="$1" pids pid command
  pids="$(descendants "$root")"
  printf '\n::group::ci-watchdog: process tree after %ss\n' "$limit"
  # shellcheck disable=SC2086
  ps -o pid,ppid,etime,stat,command -p "$root" $pids 2>/dev/null
  printf '::endgroup::\n'
  for pid in $pids; do
    command="$(ps -o command= -p "$pid" 2>/dev/null)"
    case "$command" in
      *swiftpm-testing-helper* | *xctest* | *PackageTests*)
        if command -v sample >/dev/null 2>&1; then
          printf '::group::ci-watchdog: sample of pid %s (%s)\n' "$pid" "$command"
          sample "$pid" 3 -mayDie 2>&1
          printf '::endgroup::\n'
        fi
        ;;
    esac
  done
}

kill_tree() {
  local root="$1" pids
  pids="$(descendants "$root")"
  # shellcheck disable=SC2086
  kill -TERM "$root" $pids 2>/dev/null
  sleep 2
  # shellcheck disable=SC2086
  kill -KILL "$root" $pids 2>/dev/null
}

"$@" &
child=$!
started=$SECONDS
while kill -0 "$child" 2>/dev/null; do
  if (( SECONDS - started >= limit )); then
    printf '::error::ci-watchdog: %s still running after %ss: %s\n' "$child" "$limit" "$*"
    dump "$child"
    kill_tree "$child"
    wait "$child" 2>/dev/null
    exit 124
  fi
  sleep "$poll"
done
wait "$child"
