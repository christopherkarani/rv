#!/usr/bin/env bash
# Scripts/require-tests-ran.sh [--no-skips] [--suites N] MIN COMMAND [ARG...]
#
# Runs COMMAND (a `swift test` invocation, possibly wrapped in unshare,
# setpriv, aa-exec or docker) and fails unless Swift Testing reports that
# at least MIN tests ran and passed. `swift test --filter` exits 0 when the
# filter matches nothing, and counts a test its traits skipped as one of
# the run's tests, so a renamed test or a condition that stopped enabling
# it would otherwise pass by not running.
#
#   --no-skips   fail if any test was skipped (for a run of one named test)
#   --suites N   also require at least N suites to have passed
#
# The command's output goes to a file, not a pipe: test children that
# outlive the runner would hold a pipe open and stall this script.
#   --self-test  check this script against canned transcripts
set -euo pipefail

usage() {
  printf 'usage: require-tests-ran.sh [--no-skips] [--suites N] MIN COMMAND [ARG...]\n' >&2
  exit 2
}

self_test() {
  local me="$0" failures=0
  check() { # expected-status description command...
    local expected="$1" what="$2" status=0
    shift 2
    "$me" "$@" >/dev/null 2>&1 || status=$?
    if [[ "$status" -ne "$expected" ]]; then
      printf 'require-tests-ran self-test: %s: exit %s, expected %s\n' "$what" "$status" "$expected" >&2
      failures=$((failures + 1))
    fi
  }
  local pass='✔ Test a() passed after 0.1 seconds.'
  local suite='✔ Suite "S" passed after 0.1 seconds.'
  check 0 "one passed test" 1 printf '%s\n%s\n' "$pass" '✔ Test run with 1 test in 1 suite passed after 0.1 seconds.'
  check 1 "nothing matched" 1 printf '%s\n' 'No matching test cases were run'
  check 1 "only a skipped test" 1 printf '%s\n%s\n' '➜ Test a() skipped.' '✔ Test run with 1 test in 1 suite passed after 0.1 seconds.'
  check 1 "a skip under --no-skips" --no-skips 1 printf '%s\n%s\n%s\n' "$pass" '➜ Test b() skipped: "x"' '✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.'
  check 1 "a display-named skip under --no-skips" --no-skips 1 printf '%s\n%s\n%s\n' "$pass" '➜ Test "b c" skipped.' '✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.'
  check 1 "a skipped suite under --no-skips" --no-skips 1 printf '%s\n%s\n%s\n' "$pass" '➜ Suite B skipped: "x"' '✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.'
  check 0 "colour and arguments in a passed line" 1 printf '\033[32m✔\033[0m Test a(x:) with 2 argument values passed after 0.1 seconds.\n%s\n' '✔ Test run with 1 test in 1 suite passed after 0.1 seconds.'
  check 0 "a skip without --no-skips" 1 printf '%s\n%s\n%s\n' "$pass" '➜ Test b() skipped.' '✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.'
  check 1 "too few tests" 2 printf '%s\n%s\n' "$pass" '✔ Test run with 1 test in 1 suite passed after 0.1 seconds.'
  check 1 "too few suites" --suites 2 1 printf '%s\n%s\n%s\n' "$pass" "$suite" '✔ Test run with 1 test in 1 suite passed after 0.1 seconds.'
  check 0 "enough suites" --suites 1 1 printf '%s\n%s\n%s\n' "$pass" "$suite" '✔ Test run with 1 test in 1 suite passed after 0.1 seconds.'
  check 1 "a failed run" 1 printf '%s\n%s\n' "$pass" '✘ Test run with 2 tests in 1 suite failed after 0.1 seconds with 1 issue.'
  check 3 "the command's own failure" 1 sh -c "printf '%s\n' '$pass'; exit 3"
  check 1 "passed lines with no summary" 1 printf '%s\n' "$pass"
  check 2 "a threshold that is not a number" 08x true
  [[ "$failures" -eq 0 ]] || exit 1
  printf 'require-tests-ran self-test: ok\n' >&2
}

no_skips=0
suites=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) self_test; exit 0 ;;
    --no-skips) no_skips=1; shift ;;
    --suites) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || usage; suites="$2"; shift 2 ;;
    *) break ;;
  esac
done
[[ $# -ge 2 && "$1" =~ ^[1-9][0-9]*$ ]] || usage
minimum="$1"
shift

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

status=0
"$@" >"$log" 2>&1 || status=$?
cat "$log"
if [[ "$status" -ne 0 ]]; then
  printf 'require-tests-ran: command failed (%s)\n' "$status" >&2
  exit "$status"
fi

plain="$(sed 's/\x1b\[[0-9;]*m//g' "$log")"
count() { printf '%s\n' "$plain" | grep -Ec "$1" || true; }
# A test's name ends in its parameter list; "Test run with ..." has none.
passed="$(count '^✔ Test [^ ]+\(.* passed after ')"
# Any skip, a display-named test's or a whole suite's included.
skipped="$(count '^➜ (Test|Suite) .* skipped')"
suites_passed="$(count '^✔ Suite .* passed after ')"
summary="$(count '^✔ Test run with [0-9]+ tests? in [0-9]+ suites? passed after ')"

fail() { printf 'require-tests-ran: %s\n' "$1" >&2; exit 1; }
[[ "$summary" -ge 1 ]] || fail "no passed test run was reported"
[[ "$passed" -ge "$minimum" ]] || fail "$passed tests ran and passed, at least $minimum were required"
if [[ "$no_skips" -eq 1 && "$skipped" -ne 0 ]]; then fail "$skipped tests were skipped, none may be"; fi
[[ "$suites_passed" -ge "$suites" ]] || fail "$suites_passed suites passed, at least $suites were required"
printf 'require-tests-ran: %s tests ran and passed (%s skipped, %s suites)\n' "$passed" "$skipped" "$suites_passed" >&2
