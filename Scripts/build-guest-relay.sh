#!/usr/bin/env bash
# Scripts/build-guest-relay.sh — build the static Linux rv-guest-relay that
# rv-microvm shares into every micro-VM guest. Needs zig (cross C compiler
# with a bundled musl). Compatible with macOS /bin/bash 3.2.
#
#   Scripts/build-guest-relay.sh <out-path> [aarch64|x86_64]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: Scripts/build-guest-relay.sh <out-path> [aarch64|x86_64]\n' >&2
  exit 2
fi
OUT="$1"
ARCH="${2:-aarch64}"
case "$ARCH" in
  aarch64|x86_64) ;;
  *) printf 'build-guest-relay: arch must be aarch64 or x86_64, not %s\n' "$ARCH" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-zig}"
if ! command -v "$ZIG" >/dev/null 2>&1; then
  printf 'build-guest-relay: zig not found (install zig, or set ZIG=/path/to/zig)\n' >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
"$ZIG" cc -target "$ARCH-linux-musl" -static -s -O2 -std=c11 -Wall -Wextra -Werror \
  -o "$OUT" "$ROOT/Sources/rv-guest-relay/rv_guest_relay.c"
chmod 755 "$OUT"
if command -v file >/dev/null 2>&1; then
  file "$OUT"
fi
