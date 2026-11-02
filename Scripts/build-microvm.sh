#!/usr/bin/env bash
# Scripts/build-microvm.sh — build the micro-VM launch backend into OUT_DIR:
#   rv-microvm      Packages/rv-microvm (Virtualization.framework, macOS 26+),
#                   ad-hoc signed with its virtualization entitlement
#   rv-guest-relay  static Linux helper shared into every guest (needs zig)
#   rv-macvm        macOS guests (Virtualization.framework), same entitlement
#   rv-macvm-agent  the daemon `rv-macvm prepare` installs in macOS guests
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

for product in rv-microvm rv-macvm rv-macvm-agent; do
  "$ROOT/Scripts/swift-6.4" build --package-path "$PACKAGE" -c "$CONFIG" --product "$product"
done
BIN="$("$ROOT/Scripts/swift-6.4" build --package-path "$PACKAGE" -c "$CONFIG" --show-bin-path)"

# Copy to a temporary name and rename: a running host may exec the old one.
# install_signed NAME [ENTITLEMENTS]
install_signed() {
  local staged="$OUT/.$1.building"
  rm -f "$staged"
  cp "$BIN/$1" "$staged"
  chmod 755 "$staged"
  if [[ "$CONFIG" == "release" ]]; then
    strip -x "$staged"
  fi
  if [[ -n "${2:-}" ]]; then
    codesign --force --sign - --entitlements "$2" "$staged"
  else
    codesign --force --sign - "$staged"
  fi
  mv -f "$staged" "$OUT/$1"
}
install_signed rv-microvm "$PACKAGE/rv-microvm.entitlements"
install_signed rv-macvm "$PACKAGE/rv-microvm.entitlements"
install_signed rv-macvm-agent

"$ROOT/Scripts/build-guest-relay.sh" "$OUT/.rv-guest-relay.building" aarch64 >/dev/null
mv -f "$OUT/.rv-guest-relay.building" "$OUT/rv-guest-relay"

for entitled in rv-microvm rv-macvm; do
  codesign -d --entitlements - "$OUT/$entitled" 2>/dev/null | grep -q 'com.apple.security.virtualization' \
    || { printf 'build-microvm: %s is missing the virtualization entitlement\n' "$entitled" >&2; exit 1; }
done
printf 'build-microvm: rv-microvm, rv-guest-relay, rv-macvm and rv-macvm-agent in %s\n' "$OUT"
