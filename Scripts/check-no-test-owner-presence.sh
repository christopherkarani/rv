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
# that does not exist fails: a check of nothing proves nothing.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

# Not the bare type name TestOwnerPresence: a debug binary names the source
# file TestOwnerPresence.swift in its debug info even when it compiled to nothing.
MARKERS="rv-test-owner-presence RV_TEST_OWNER_PASSWORD TestOwnerPasswordChecker"

if [[ $# -eq 0 ]]; then
  printf 'usage: %s FILE|DIRECTORY...\n' "$0" >&2
  exit 2
fi

files=()
for target in "$@"; do
  if [[ -d "$target" ]]; then
    while IFS= read -r file; do
      files+=("$file")
    done < <(find "$target" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' -o -name '*.dylib' \) | sort)
  elif [[ -f "$target" ]]; then
    files+=("$target")
  else
    printf 'check-no-test-owner-presence: %s does not exist\n' "$target" >&2
    exit 1
  fi
done
if [[ ${#files[@]} -eq 0 ]]; then
  printf 'check-no-test-owner-presence: no binaries under %s\n' "$*" >&2
  exit 1
fi

status=0
for file in "${files[@]}"; do
  for marker in $MARKERS; do
    if LC_ALL=C grep -a -q -F -- "$marker" "$file"; then
      printf 'check-no-test-owner-presence: %s contains %s: it was built with RV_TEST_OWNER_PRESENCE=1 and must not ship\n' \
        "$file" "$marker" >&2
      status=1
    fi
  done
done
if [[ "$status" -eq 0 ]]; then
  printf 'check-no-test-owner-presence: %s files checked, none carries the test owner presence\n' "${#files[@]}" >&2
fi
exit "$status"
