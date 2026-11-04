#!/usr/bin/env bash
# Scripts/microvm-proof.sh — prove micro-VM contained launches end to end on
# this machine (Apple silicon, macOS 26, zig):
#   1. build rv-microvm + rv-guest-relay into .build/debug (beside the host)
#   2. rv-microvm prepare --image alpine:3.20 into the default state root
#      (~/.config/rv/microvm; downloads the pinned kernel once)
#   3. guest relay unit tests and the rv-microvm package tests
#   4. RV_MICROVM_E2E=1 MicroVMWorkspaceEndToEndTests: real supervisor,
#      protected volume, PTY, credentialed egress relayed into a VM with no
#      network interface, exit status, publish on close, cancel teardown
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFT_WRAP="$ROOT/Scripts/swift-6.4"
IMAGE="${RV_MICROVM_PROOF_IMAGE:-alpine:3.20}"

step() { printf '\n== %s\n' "$*"; }

step "build the micro-VM backend"
"$SWIFT_WRAP" build
"$ROOT/Scripts/build-microvm.sh" "$("$SWIFT_WRAP" build --show-bin-path)" debug

step "prepare $IMAGE"
BIN="$("$SWIFT_WRAP" build --show-bin-path)"
"$BIN/rv-microvm" prepare --image "$IMAGE"
"$BIN/rv-microvm" status --image "$IMAGE"

step "guest relay tests"
"$ROOT/Sources/rv-guest-relay/tests/run.sh"

step "rv-microvm package tests"
"$SWIFT_WRAP" test --package-path "$ROOT/Packages/rv-microvm"

step "end-to-end launches"
RV_MICROVM_E2E=1 "$SWIFT_WRAP" test --filter 'MicroVMWorkspaceEndToEndTests|MicroVMLaunchTests|MicroVMLaunchWireTests'

printf '\nmicrovm-proof: all checks passed\n'
