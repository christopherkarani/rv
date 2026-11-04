# VM-backed isolation for rv: apple/container and tart

Status: proposal (no code). Date: 2026-11-01.
Inputs: codebase map of `RVIsolation` / `RVDomain`, research on `apple/container` 1.6.1 + `apple/containerization` 0.54.0, and `openai/tart` 2.41.1 (fork `christopherkarani/tart`).

## 1. Why this matters now

rv is a fail-closed policy gate for coding agents. On macOS the "contained" launch is a Seatbelt cage (`sandbox-exec`, deny-default SBPL, private `hdiutil` volume, loopback-only network to rv's secret gateway and egress proxy). That cage has four P0s that native mechanisms have not closed (`docs/security/runtime-mechanism-decision.md`):

| P0 | Problem | What a VM boundary does |
|----|---------|-------------------------|
| ISO-01 sysctl | Guest can read host kernel state | Guest kernel is not the host kernel |
| ISO-02 guardian process | No reliable supervisor for the whole cage | VM lifecycle is the guardian: stop the VM, everything dies |
| ISO-03 Linux Landlock | No contained launch on Linux hosts (`containedGuaranteesUnsupported`) | Unchanged for Linux hosts, but rv's Linux Landlock build now has a place to run on Macs: inside the guest |
| ISO-04 descendant exec mediation | Endpoint Security vs brokered exec, unresolved | Every descendant is inside the VM; exec is mediated by `vminitd` and optionally by rv's own Linux hooks in the guest |

`docs/security/runtime-remediation-plan.md:63` already anticipates this: "an entitled service or VM backend requires a bounded reviewed extension if native mechanisms cannot pass." The same doc says "Container-provided isolation is not RV evidence" (line 62). The plan below respects that: the VM backend is a new, separately evidenced backend family with its own acceptance criteria, not a shortcut around the existing ones.

Competitive pressure (memory `competitor-secrets-landscape`): Infisical and Varlock now ship Seatbelt + placeholder + proxy. OpenShell drives Docker/Podman/K8s/VM. "VM-grade isolation on a Mac with no Docker Desktop and sub-second start" is a position none of them hold.

## 2. What the two projects give us

### apple/container + apple/containerization (Linux guests)

- One lightweight Linux VM per container on Virtualization.framework. OCI images. Apache-2.0. Sub-second boot (WWDC25 346). CLI 1.6.1 (2026-10-23); library 0.54.0 (2026-10-28), still 0.x with breaking changes between minors.
- The library runs **without** the `container` daemon. Apple's own `examples/sandboxy` boots a micro-VM per AI-agent session (Claude Code, Pi), virtio-fs workspace, host-only network, allowlist CONNECT proxy. That is rv's shape almost exactly, minus policy, secrets, and audit.
- Embed API: `ContainerManager(kernel:initfsReference:...)` → `LinuxContainer` with `mounts` (virtiofs share, ext4 block, tmpfs), `cpus`, `memoryInBytes`, `dns`, `maskedPaths`, `readonlyPaths`, `sockets` (unix-socket relays), `dialVsock(port:)`, `exec`, `copyIn/copyOut`, `statistics()`. `writableLayerSizeInBytes` gives a read-only rootfs plus overlay.
- Needs: a kernel file (Kata `vmlinux.container`, downloaded), the `ghcr.io/apple/containerization/vminit:<ver>` init image pinned to the library version, and the `com.apple.security.virtualization` entitlement on the process that drives the VM.
- Gates: vmnet networking is `@available(macOS 26)`; `Package.swift` says macOS 15 but Apple supports only 26. Rosetta for amd64 images. Nested virt M3+ only. Memory ballooning is partial (guest RAM is not returned to the host). Osaurus ships exactly the dual mode rv would need: Containerization on 26, `sandbox-exec` fallback below.

### tart (macOS and Linux guests)

- Swift CLI over Virtualization.framework; VM images as OCI artifacts; `clone` is an APFS copy-on-write clone; `run --no-graphics --dir=ws:path[:ro] --net-host|--net-softnet --root-disk-opts=ro`; `tart exec` via a vsock guest agent (non-vanilla Cirrus images); `tart ip` + ssh otherwise. macOS 13+; Softnet and ASIF need 26.
- **Ownership and license changed.** Cirrus Labs joined OpenAI (2026-04-07); repo is `openai/tart`. License is now FSL-1.1 with Apache-2.0 conversion two years after each release. Internal use and non-competing commercial use are permitted; "Competing Use" (a product that substitutes for tart or offers substantially similar functionality) is not. Licensor is OpenAI, which ships Codex.
- **The fork `christopherkarani/tart` is an unmodified snapshot**: 0 ahead, 44 behind, HEAD at upstream 2026-08-18. It is not a customized dependency.
- CLI only: no library product. Shell out, or vendor sources.
- Hard limits: Apple caps **two concurrent macOS guests per host**. Images are 25–73 GB. Boot to usable is ~30 s macOS, ~8 s Linux. Headless use on macOS 15+ needs an unlocked login keychain.

### Which tool for which job

| Need | Use | Why |
|------|-----|-----|
| Contained launch for any agent whose toolchain runs on Linux (most of them) | apple/containerization, embedded | Sub-second, Apache-2.0, OCI images, linkable Swift API, vsock + socket relays |
| Contained launch for Xcode / Darwin-only toolchains | tart macOS guest, shell-out | Only option for macOS guests |
| Linux fixtures for rv's own adversarial tests and Linux release builds on a Mac | `container` CLI | Replaces the Docker fixture in `Scripts/isolation-linux-adversarial.py` |

## 3. Architecture: a fourth backend family

Today (`Sources/RVIsolation/IsolationApply.swift`):

```
IsolationBackendFamily { none, seatbelt, landlock }
IsolatedLaunchRequest.Launch { seatbelt(SeatbeltProfile), landlock(LandlockRuleset), unsandboxed }
EstablishedIsolation { observed, mediated, seatbelt(RuntimeSession) }
```

Proposed:

```
IsolationBackendFamily { none, seatbelt, landlock, microvm, macvm }
Launch { ..., microvm(MicroVMPlan), macvm(MacVMPlan) }
EstablishedIsolation { ..., microvm(RuntimeSession), macvm(RuntimeSession) }
RuntimeIsolationBackend { seatbelt, landlock, microvm, macvm }
```

`IsolationGuarantees` stays the contract. A VM backend must establish every field (`filesystem .workspaceScoped`, `network .denied`, `process .hostSignalsDenied`, `descent .inherited`) or refuse the launch, exactly as the domain already says.

### Process layout (micro-VM)

```
rv-cli ── XPC ── rvd
             └── rv-workspace-host (per project)
                    └── rv-vm-host (NEW, entitled: com.apple.security.virtualization)
                           ├── ContainerManager / LinuxContainer (apple/containerization, pinned exact)
                           ├── vsock relays: secret gateway, egress proxy, admission broker (fd3/4/5 today)
                           └── guest: vminitd → rv-linux (hooks + Landlock) → agent
```

Mapping of today's mechanisms:

| Today (Seatbelt) | Micro-VM |
|------------------|----------|
| Private `hdiutil` volume, copy-back on close (`WorkspaceInodeBoundary.swift`) | Sparse ext4 block mount (`Mount.block`) built from the workspace; `copyOut` on close. Keep virtiofs `Mount.share` as the fast-iteration option for read-mostly trees |
| Deny-default SBPL profile | Read-only rootfs + overlay (`writableLayerSizeInBytes`), `maskedPaths`, `readonlyPaths`, reduced caps, no network interface at all unless the plan says `mediated` |
| Loopback-only TCP to gateway/egress on host | No host loopback is reachable from a guest. Expose the gateway and egress as **unix-socket relays** (`sockets`) or vsock ports; a tiny guest-side forwarder binds them to `127.0.0.1` inside the guest so `HTTPS_PROXY` and `rvph_` base URLs keep working unchanged |
| Process group + SIGKILL | `LinuxContainer.stop()`; the VM is the guardian (ISO-02) |
| Admission broker on fd3/4/5 | Same protocol over a vsock port |
| `ContainedEnvironmentPolicy` denylist | Unchanged; applied to the guest process env |

Side effect worth stating in docs: the memory note "any loopback process can spend a placeholder" stops being true for VM launches. Only processes inside the guest can reach the relay.

### Process layout (macOS VM, tart)

```
rv-vm-host ── spawn ── tart clone <golden> rv-<session>
                       tart run --no-graphics --dir=ws:<path> --net-host --root-disk-opts=ro [--net-softnet on 26]
                       tart exec rv-<session> -- rv-guest-launch ...   (guest agent images) | ssh fallback
                       tart stop / delete on close
```

Inside the macOS guest, rv itself runs with the existing Seatbelt cage (nested defense: VM boundary outside, Seatbelt inside). Admission control counts live macOS guests and refuses the third.

## 4. Phases

### Phase 0: spike and gates (1 week, throwaway)

- Daemon-less PoC modelled on `examples/sandboxy`: boot a micro-VM with an rv workspace, run Claude Code inside, egress through rv's existing proxy over a vsock relay. Measure cold boot, warm boot, virtiofs vs block I/O on a `node_modules`-heavy repo, idle RSS.
- Prove `com.apple.security.virtualization` works on a Developer ID signed, notarized, non-bundle Mach-O helper with rv's release pipeline (`.github/workflows/release.yml`). If it must be a `.app`, know now.
- Legal read of FSL-1.1 for the tart shell-out. Decide go/no-go on macOS guests independently of the Linux work.
- Decision: is the VM backend macOS 26+ only (Seatbelt stays the floor on 15)? Recommendation: yes, mirror Osaurus.

Exit: numbers in a short memo, a go/no-go per backend.

### Phase 1: seam first, then the micro-VM backend (3–4 weeks)

1. **Close the seam bypass.** `WorkspaceSessionSupervisor.swift` (~664, ~1215) calls `prepareSeatbelt` directly and `runSeatbeltLaunch` is Seatbelt-specific. Route the interactive path through `IsolationBackend.prepare/run` so a second family can plug in. This is a prerequisite refactor with no behavior change, covered by the existing L2 tests.
2. Add `microvm` to the family, launch, and established enums. Add `MicroVMPlan` (kernel, init image digest, cpus, memory, mounts, relays).
3. New target `rv-vm-host`, entitled, linking `Containerization` at an `exact:` version. Nothing else in rv links it (keeps the entitlement surface to one binary).
4. Provisioning in `rv setup` / `rv doctor`: kernel download with digest pin, `vminit` image pull pinned to the library version, macOS version gate, Apple Silicon gate.
5. Workspace as an ext4 block image with `copyOut` on close; `rv workspace close/abandon/leftovers` semantics preserved.
6. Add `Launch.microvm` to release assets and the installer.

Exit: `rv workspace start --isolation contained --backend microvm` runs an agent end to end with network `.denied`.

### Phase 2: secrets, egress, and evidence (2–3 weeks)

1. Vsock/unix relays for the secret gateway, egress proxy, and admission broker. Guest-side forwarder shipped in the rootfs image (`ghcr.io/<org>/rv-guest:<ver>`, built with `container build`).
2. Run rv's Linux build inside the guest: hooks for the agent, `rvd`, and Landlock around the agent process. This is where ISO-03's Linux work finally has a shipping surface and where ISO-04 gets a second layer.
3. Write the `ISO-05 microvm` section in `docs/security/runtime-acceptance.md` and `runtime-boundary.md`: the acceptance criteria the VM backend must pass to count as rv evidence, including the sandboxy caveat (guest must not reach host services bound on `0.0.0.0`; rv binds relays only).
4. L2 tests on the `macos-26` CI shard; adversarial script variant that runs inside the guest.

Exit: the four P0s have a documented status under the micro-VM backend; remediation plan updated.

### Phase 3: macOS guests via tart (3 weeks, only if Phase 0 says go)

1. `macvm` family and `MacVMPlan`. Shell out to a pinned `tart` release detected by `tart --version`; no source vendoring. Keep the fork only as a snapshot for reproducibility and re-sync it to a tagged release.
2. `rv vm image pull/list/prune` for golden images (OCI, Packer-built from `macos-image-templates`), clone per session, delete on close.
3. Networking: `--net-host` plus rv egress on the host side; `--net-softnet` when on 26 and the softnet helper is installed.
4. Launch via `tart exec` on guest-agent images; ssh fallback with a per-session key.
5. Admission: enforce the two-guest cap; clear error when exceeded.
6. rv runs inside the guest with Seatbelt (install step baked into the golden image).

Exit: `rv workspace start --backend macvm` runs `xcodebuild` in a contained macOS guest.

### Phase 4: developer velocity (1 week, can run alongside Phase 1)

- `Scripts/isolation-linux-adversarial.py`: add a `container` driver next to Docker so Mac developers can run the Linux Landlock suite without Docker Desktop.
- `container build` recipe for the Linux release artifacts (`rv-linux-aarch64`, Swift libs tarball) for local reproduction of `release.yml`.

## 5. Risks and mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Containerization is 0.x; breaking changes between minors; init image must match | High | `exact:` pin, one entitled binary links it, update as a deliberate PR with the L2 suite |
| macOS 26 floor for vmnet; rv promises 15 | Medium | VM backend is 26+; Seatbelt stays the floor; `rv doctor` says which backends are available |
| Virtiofs throughput on large trees | Medium | Block ext4 workspace by default (matches today's hdiutil model); virtiofs opt-in |
| Guest RAM not returned to host (partial ballooning) | Medium | Conservative defaults (2 CPU / 2 GiB), per-workspace override, stop idle VMs |
| Entitlement on a non-bundle helper fails notarization | Medium | Phase 0 proves it; fallback is a small `.app` bundle for `rv-vm-host` |
| tart license (FSL-1.1, licensor OpenAI) | Medium | Shell-out only, no redistribution, legal sign-off in Phase 0, kill switch: Phase 3 is optional |
| Two macOS guests per host | Low | Admission control; document it |
| 2026 advisories in container/containerization (digest verification, symlink escapes, env leaks) | Medium | Track releases; `rv doctor` warns on stale library version |
| "Container-provided isolation is not RV evidence" | Policy | ISO-05 criteria written and tested before the backend is advertised as contained |

## 6. Decisions needed

1. macOS 26+ floor for VM backends (Seatbelt stays on 15)? Recommended: yes.
2. Pursue macOS guests via tart at all, given FSL-1.1 and OpenAI as licensor? Recommended: spike only, decide after legal.
3. Fork strategy for `christopherkarani/tart`: snapshot-only (recommended) or vendor sources.
4. Order: micro-VM first (recommended), or tart first because Xcode workflows matter more to current users.

## 7. Non-goals

- Replacing Seatbelt. It remains the macOS 15 path and the inner layer inside macOS guests.
- Linux-host contained launch (ISO-03 on Linux hosts) is unchanged by this plan.
- Running rv's judge (CoreML) inside guests.
- Kubernetes or `container cluster`.

## 8. Sources

- rv: `Sources/RVIsolation/IsolationApply.swift`, `Sources/RVDomain/Isolation.swift`, `Sources/RVIsolation/WorkspaceSessionSupervisor.swift`, `docs/security/runtime-remediation-plan.md`, `docs/security/runtime-mechanism-decision.md`, `docs/plans/agent-governance/PLAN.md`
- https://github.com/apple/container (technical-overview, networking, volumes, runtime-configuration, releases)
- https://github.com/apple/containerization (`Sources/Containerization/LinuxContainer.swift`, `ContainerManager.swift`, `examples/sandboxy`, `signing/vz.entitlements`, tags)
- https://github.com/osaurus-ai/osaurus (dual-mode precedent)
- https://github.com/openai/tart (README, `Sources/tart/Commands/Run.swift`, LICENSE, PR #1238, discussions/1054), https://tart.run/faq/, https://github.com/openai/softnet
- https://github.com/christopherkarani/tart (fork status via GitHub API: 0 ahead / 44 behind)
