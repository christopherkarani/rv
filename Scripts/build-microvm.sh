#!/usr/bin/env bash
# Scripts/build-microvm.sh — build the micro-VM launch backend into OUT_DIR:
#   rv-microvm      Packages/rv-microvm (Virtualization.framework, macOS 26+),
#                   ad-hoc signed with its virtualization entitlement
#   rv-guest-relay  static Linux helper shared into every guest (needs zig)
# The workspace host looks for rv-microvm beside its own binary, and
# rv-microvm looks for rv-guest-relay beside itself, so OUT_DIR is the
# directory holding rv-workspace-host (.build/debug for development,
# the release stage for releases; Scripts/sign-macos.sh re-signs it there
# with the Developer ID and hardened runtime).
# Compatible with macOS /bin/bash 3.2.
#
#   Scripts/build-microvm.sh OUT_DIR [debug|release]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: Scripts/build-microvm.sh OUT_DIR [debug|release]\n' >&2
  exit 2
fi
OUT="$1"
CONFIG="${2:-debug}"
case "$CONFIG" in
  debug|release) ;;
  *) printf 'build-microvm: configuration must be debug or release, not %s\n' "$CONFIG" >&2; exit 2 ;;
esac
[[ "$(uname -s)" == "Darwin" ]] || { printf 'build-microvm: macOS is required\n' >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { printf 'build-microvm: Apple silicon is required\n' >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/rv-microvm"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

"$ROOT/Scripts/swift-6.4" build --package-path "$PACKAGE" -c "$CONFIG" --product rv-microvm
BIN="$("$ROOT/Scripts/swift-6.4" build --package-path "$PACKAGE" -c "$CONFIG" --show-bin-path)"

# Copy to a temporary name and rename: a running host may exec the old one.
staged="$OUT/.rv-microvm.building"
rm -f "$staged"
cp "$BIN/rv-microvm" "$staged"
chmod 755 "$staged"
if [[ "$CONFIG" == "release" ]]; then
  strip -x "$staged"
fi
codesign --force --sign - --entitlements "$PACKAGE/rv-microvm.entitlements" "$staged"
mv -f "$staged" "$OUT/rv-microvm"

"$ROOT/Scripts/build-guest-relay.sh" "$OUT/.rv-guest-relay.building" aarch64 >/dev/null
mv -f "$OUT/.rv-guest-relay.building" "$OUT/rv-guest-relay"

codesign -d --entitlements - "$OUT/rv-microvm" 2>/dev/null | grep -q 'com.apple.security.virtualization' \
  || { printf 'build-microvm: rv-microvm is missing the virtualization entitlement\n' >&2; exit 1; }
printf 'build-microvm: %s/rv-microvm and %s/rv-guest-relay\n' "$OUT" "$OUT"
