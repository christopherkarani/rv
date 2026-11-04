# Micro-VM backend: implementation checklist

Scope: Linux micro-VM contained launches through apple/containerization. macOS guests (tart) are out of scope.

## Shape

The Seatbelt launch spawns `rv-pty-claim <slave> sandbox-exec -p <profile> /bin/sh -c <handshake> rv-seatbelt <nonce> <cmd>`.
The micro-VM launch spawns `rv-pty-claim <slave> rv-microvm run <flags> --handshake-fd 3 --nonce <nonce> -- <guest cmd>` instead.
Everything around the spawn stays the same: session record, private workspace volume, PTY, process group, admission pipes, per-runtime egress proxy, secret lease, copy-back on close.

- `rv-microvm` is its own SwiftPM package (`Packages/rv-microvm`). It is the only binary that links Containerization and the only one that carries `com.apple.security.virtualization`. The main package stays free of swift-crypto on Darwin (OPE-260).
- The guest has no network interface. rv's loopback services (egress proxy, secret gateway) reach the guest as relays: host TCP ↔ host unix socket (`rv-microvm`) ↔ vsock (Containerization) ↔ guest unix socket ↔ guest `127.0.0.1:<same port>` (`rv-guest-relay`, a static Linux binary built with zig).
- The workspace volume is shared into the guest over virtiofs at the same absolute path.
- SIGKILL of `rv-microvm` stops the VM (verified: the VZ XPC process exits with its client), so the process-group kill model is unchanged.
- Asset pins: Kata 3.32.0 kernel (`sha256:8736c054…`, same pin as apple/container 1.6.1), `ghcr.io/apple/containerization/vminit@sha256:ab76bf71…` (0.54.0, pinned by digest).

## Checklist

- [x] `Sources/rv-guest-relay/rv_guest_relay.c` + `Scripts/build-guest-relay.sh` + host-side test
- [x] `Packages/rv-microvm`: `prepare`, `run`, `status`; pure core library + tests
- [x] RVDomain: `RuntimeIsolationBackend.microvm`
- [x] RVIsolation: `IsolationBackendFamily.microvm`, `MicroVMProfile`, `prepareMicroVM`, request/established cases
- [x] Supervisor: microvm argv + guest environment in the shared spawn body; establishment reports `.microvm`
- [x] Workspace control protocol + host: carry `MicroVMLaunchOptions` on launchRuntime
- [x] CLI: `rv workspace run --microvm <image>`, runs `rv-microvm prepare` before launch
- [ ] `rv doctor`: micro-VM availability line (deferred; `rv-microvm status --image I` answers it today)
- [x] Release: build/sign `rv-microvm`, build `rv-guest-relay`, assets + installer
- [x] Unit tests (RVIsolationTests, rv-microvm tests)
- [x] Manual proof script `Scripts/microvm-proof.sh` and a recorded run
- [x] Docs: `docs/security/runtime-boundary.md` "Micro-VM contained launches" section (user docs: `rv workspace run --help`)

## Non-goals for this change

- Admission broker inside the guest (fds 4/5 are not forwarded; admitted actions are refused).
- Resource profiles with host path grants (refused). Env, keychain and secrets entries are supported.
- Binary-scoped egress policy (the guest binary is not a host file; such policies deny, fail closed).

## Verification

`Scripts/microvm-proof.sh` (build, prepare `alpine:3.20`, relay + package tests, `RV_MICROVM_E2E=1` end-to-end suite). See the runtime-boundary section for what it asserts and what it does not reach (the debug CLI → host hop, blocked by peer trust).
