#!/usr/bin/env bash
# Scripts/check-no-test-owner-presence.sh — fails when a binary carries the
# test owner presence (docs/security/test-owner-presence.md), the debug-only
# owner check that accepts a password from rvd's environment. A release
# must never contain it: Scripts/release.sh runs this over its stage.
#
#   Scripts/check-no-test-owner-presence.sh FILE|DIRECTORY...
#
# A directory is searched for regular files that are executable or shared
# libraries. Every file is read as bytes; the markers are strings and type
# names the feature's code always leaves behind, stripped or not. A path
# that does not exist, a directory with no binaries in it, a directory find
# cannot fully search, and a file grep cannot read all fail: a check of
# nothing proves nothing.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

# Not the bare type name TestOwnerPresence: a debug binary names the source
# file TestOwnerPresence.swift in its debug info even when it compiled to nothing.
MARKERS="rv-test-owner-presence RV_TEST_OWNER_PASSWORD TestOwnerPasswordChecker"

if [[ $# -eq 0 ]]; then
  printf 'usage: %s FILE|DIRECTORY...\n' "$0" >&2
  exit 2
fi

fail() {
  printf 'check-no-test-owner-presence: %s\n' "$*" >&2
  exit 1
}

files=()
for target in "$@"; do
  if [[ -d "$target" ]]; then
    # Not `< <(find …)`: find's status would be lost, and a directory it
    # could only partly read would pass as checked.
    listing="$(find "$target" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' -o -name '*.dylib' \))" \
      || fail "could not search all of $target"
    found=0
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      files+=("$file")
      found=$((found + 1))
    done <<EOF
$(printf '%s\n' "$listing" | LC_ALL=C sort)
EOF
    [[ "$found" -gt 0 ]] || fail "no binaries under $target"
  elif [[ -f "$target" ]]; then
    files+=("$target")
  else
    fail "$target does not exist"
  fi
done
if [[ ${#files[@]} -eq 0 ]]; then
  fail "no binaries under $*"
fi

status=0
checked=0
for file in "${files[@]}"; do
  for marker in $MARKERS; do
    # grep: 0 found, 1 not found, anything else could not read the file,
    # which must not count as clean.
    grep_status=0
    LC_ALL=C grep -a -q -F -- "$marker" "$file" || grep_status=$?
    case "$grep_status" in
      0)
        printf 'check-no-test-owner-presence: %s contains %s: it was built with RV_TEST_OWNER_PRESENCE=1 and must not ship\n' \
          "$file" "$marker" >&2
        status=1
        ;;
      1) ;;
      *) fail "could not read $file (grep exited $grep_status)" ;;
    esac
  done
  checked=$((checked + 1))
done
[[ "$checked" -gt 0 ]] || fail "no files checked"
if [[ "$status" -eq 0 ]]; then
  printf 'check-no-test-owner-presence: %s files checked, none carries the test owner presence\n' "$checked" >&2
fi
exit "$status"
