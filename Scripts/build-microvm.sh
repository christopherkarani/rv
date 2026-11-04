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

# rv-macvm's unattended setup (VZMacGuestProvisioningOptions) exists only
# in the macOS 27 SDK; built with an older one, `prepare` would download and
# install 25 GB before failing. A release then ships without the pair
# (install.sh and rv treat it as optional); a debug build keeps it for work
# on `run`.
products=(rv-microvm rv-macvm rv-macvm-agent)
macvm=1
# A failing xcrun must not abort the build under `set -e`: no SDK version
# means the pair is left out like an old SDK.
sdk_version="$(xcrun --show-sdk-version 2>/dev/null || true)"
sdk_major="${sdk_version%%.*}"
if ! [[ "$sdk_major" =~ ^[0-9]+$ ]] || (( sdk_major < 27 )); then
  if [[ "$CONFIG" == "release" ]]; then
    printf 'build-microvm: WARNING: macOS SDK %s is older than 27; leaving out rv-macvm and rv-macvm-agent (--macvm)\n' "${sdk_major:-unknown}" >&2
    products=(rv-microvm)
    macvm=0
  else
    printf 'build-microvm: macOS SDK %s is older than 27: rv-macvm prepare will not work in this build\n' "${sdk_major:-unknown}" >&2
  fi
fi
for product in "${products[@]}"; do
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
entitled=(rv-microvm)
if [[ "$macvm" == 1 ]]; then
  install_signed rv-macvm "$PACKAGE/rv-microvm.entitlements"
  install_signed rv-macvm-agent
  entitled+=(rv-macvm)
else
  # Never leave an older pair next to the new rv.
  rm -f "$OUT/rv-macvm" "$OUT/rv-macvm-agent"
fi

"$ROOT/Scripts/build-guest-relay.sh" "$OUT/.rv-guest-relay.building" aarch64 >/dev/null
mv -f "$OUT/.rv-guest-relay.building" "$OUT/rv-guest-relay"

for name in "${entitled[@]}"; do
  codesign -d --entitlements - "$OUT/$name" 2>/dev/null | grep -q 'com.apple.security.virtualization' \
    || { printf 'build-microvm: %s is missing the virtualization entitlement\n' "$name" >&2; exit 1; }
done
if [[ "$macvm" == 1 ]]; then
  printf 'build-microvm: rv-microvm, rv-guest-relay, rv-macvm and rv-macvm-agent in %s\n' "$OUT"
else
  printf 'build-microvm: rv-microvm and rv-guest-relay in %s\n' "$OUT"
fi
