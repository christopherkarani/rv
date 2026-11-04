#!/usr/bin/env bash
# Scripts/macvm-proof.sh — prove macOS guest contained launches end to end on
# this machine (Apple silicon, macOS 27):
#   1. build rv-macvm + rv-macvm-agent into .build/debug (beside the host)
#   2. require a prepared image (default "dev"). Building one downloads a
#      ~25 GB restore image and installs macOS, so it never happens here:
#      run `rv-macvm prepare --image dev` once first (about 55 GB free).
#   3. the rv-microvm package tests (protocol, agent sessions on the host)
#   4. RV_MACVM_E2E=1 MacVMWorkspaceEndToEndTests: real supervisor, protected
#      volume, PTY, credentialed egress relayed into a guest with no network
#      interface, Seatbelt control rules in the guest, exit status, publish
#      on close, cancel teardown
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFT_WRAP="$ROOT/Scripts/swift-6.4"
IMAGE="${RV_MACVM_E2E_IMAGE:-dev}"

step() { printf '\n== %s\n' "$*"; }

step "build the VM backends"
"$SWIFT_WRAP" build
"$ROOT/Scripts/build-microvm.sh" "$("$SWIFT_WRAP" build --show-bin-path)" debug
BIN="$("$SWIFT_WRAP" build --show-bin-path)"

step "image $IMAGE"
# The proof must exercise this build's guest agent, not one baked into an
# older image.
if ! "$BIN/rv-macvm" status --image "$IMAGE" --require-current-agent; then
  printf 'macvm-proof: prepare the image with this build: %s/rv-macvm prepare --image %s --replace\n' "$BIN" "$IMAGE" >&2
  exit 1
fi

step "rv-microvm package tests"
"$SWIFT_WRAP" test --package-path "$ROOT/Packages/rv-microvm"

step "end-to-end launches"
RV_MACVM_E2E=1 RV_MACVM_E2E_IMAGE="$IMAGE" "$SWIFT_WRAP" test --filter 'MacVMWorkspaceEndToEndTests|MacOSGuestLaunchTests'

printf '\nmacvm-proof: all checks passed\n'
