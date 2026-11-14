# RVIsolation

The cage around a coding agent: the walls that stop it reaching outside the
project, the private copy of the project it works on, the guarded doors for
network, secrets and "may I run this?" requests, and the cleanup that
publishes its work back. Vocabulary is in [`CONTEXT.md`](../../CONTEXT.md);
the security contract and its limits are in
[`docs/security/runtime-boundary.md`](../../docs/security/runtime-boundary.md).

This file is a map. It says where things live and which places must change
together. Keep it short and update it in the same PR as a move.

## How a launch flows

```text
rv workspace / rv opencode (RVCLI)
  └─ WorkspaceClient ── control frames ──▶ rv-workspace-host (WorkspaceHostProcess.run)
       WorkspaceControlProtocol/Payloads      ├─ WorkspaceSessionSupervisor.open
                                              │    WorkspaceRecovery.admit → WorkspaceInodeBoundary (disk image)
                                              └─ WorkspaceHostServer.start(supervisor:)
                                                   WorkspaceOperationAuthorization.permits, per op
                                                   launch: prepareSeatbelt | prepareMicroVM → spawn
                                                           SecretLaunchBroker, EgressProxy, RuntimeAdmissionSession
                                                   close:  publish → detach → restore, lifecycle log
```

`WorkspaceOperationAuthorization.permits` gates every control op. Today it
refuses the launch, cancel, close, detach and terminal ops from every peer:
its comment says they wait for scoped operator permits over an
authenticated host/service channel, because an owner token alone cannot
authorize them. `hello`, `capabilities` and `ping` pass for any peer with
a component role. `describeWorkspace` and `listRuntimes` pass only for the
service or a workspace host.

The CLI never owns a workspace (`Tests/RVCLITests/WorkspaceOwnershipTests`
enforces it). `IsolationBackends.apply` / `LocalExecutor` are a separate,
one-shot door used by tests and the executor.

## Areas

| Area | Files | What it owns |
|---|---|---|
| Plans and backends | `IsolationApply` (`IsolationBackendFamily`), `SeatbeltProfile`, `LandlockApply`, `LandlockRuleset`, `landlock_apply.c`, `MicroVMLaunch` (`MicroVMGuest`), `MicroVMPlaceholders` (`MicroVMControlLayout`) | Turning an `IsolationPlan` (RVDomain) into OS rules and starting the process. Landlock compiles but Linux launches refuse before exec. |
| Spawning | `SessionSupervisor` (free functions, not a type), `SpawnPrimitives`, `ProcessGroupRecovery`, `RuntimeTerminal`, `LocalTerminalMode`, `TerminalStream`, `ProcessTable` (`LibprocProcessTable`, `ProcFSProcessTable`, pure `ProcFSParse`) | `posix_spawn` under Seatbelt, process-group cleanup, ptys, the contained environment. Kernel process reads for group recovery and the gateway's peer check: libproc on macOS, `/proc` on Linux. |
| Workspace session | `WorkspaceSessionSupervisor`, `WorkspaceCloseState`, `WorkspaceSessionLifecycle`, `WorkspaceLifecycleLog`, `WorkspaceOwnerLock`, `PreparedWorkspaceLaunch`, `WorkspaceTerminalSession` | One open workspace: runtimes in it, close, abandon. |
| Private copy (macOS) | `WorkspaceInodeBoundary`, `WorkspaceBoundaryEstablish`, `WorkspaceTreeCopy`, `WorkspacePublishPlan`, `DiskImage*`, `WorkspaceDisk*`, `WorkspaceMountFacts`, `WorkspaceFilesystemMetadata` | The disk-image volume the agent writes to, and publishing it back. |
| Recovery | `WorkspaceRecovery`, `WorkspaceRecoveryPlan`, `WorkspaceAbandon`, `WorkspaceLeftovers` | Finishing a close that a crash interrupted; listing leftover images. |
| Host process and wire | `WorkspaceHostServer`, `WorkspaceHostClient`, `WorkspaceHost*Handler`, `WorkspaceHostProcess`, `WorkspaceHostEndpoint`, `WorkspaceControl*` | The `rv-workspace-host` daemon and its RPC. |
| Admission | `RuntimeAdmission`, `RuntimeAdmissionSpawn`, `ExecutableAction`, `ActionApprovalAsk`, `LocalExecutor` | A caged process asking rv to run one command or one HTTPS GET. Pure gate: `RuntimeAdmissionGate` in RVDomain. |
| Egress | `EgressProxy`, `EgressWire`, `EgressAdmission`, `EgressBinaryPinCache`, `NetworkReviewQueue`, `TransparentHTTPS`, `HTTPDirectConnector` | The per-runtime loopback proxy every outbound request goes through. `EgressProxy` does the I/O. Pure parsing (CONNECT targets, ClientHello SNI, host names, public addresses): `EgressWire`. Pure policy: `EgressAdmission.decide`, and `EgressHostPolicy` in RVDomain (`EgressPolicy.swift`). |
| Secrets | `Secret*`, `SecretGateway*`, `SecretsConfiguration`, `VarlockSchema`, `EnvSpec`, `KeychainReader`, `KnownSecretDefaults` | Releasing secrets and swapping placeholders for real values on the way out. Every read goes through `SecretRelease.release(_:to:)`. |
| Peer identity | `WorkspacePeerAuthenticator`, `MacOSPeerAuthenticator`, `AuthenticatedPeer`, `WorkspacePrincipalAuthority`, `DaemonTrustVerdict` | Who is on the other end of a socket. |
| Agent identity | `AgentInstanceRegistry`, `AgentInstanceJournal`, `AgentTurn` | Per-agent instances and their journal. |
| Developer home | `WorkspaceDeveloperHome` | The per-workspace `$HOME`, cache and `$TMPDIR` under `~/.config/rv/workspaces/<identity>`, outside the project. Created owner-only before spawn. Seeds only a commit-identity `.gitconfig`; no host dotfiles. |
| Shared plumbing | `OwnerOnlyFile`, `FileDigest`, `ManagedSerialStore`, `RuntimeSessionLog`, `RuntimeResource*`, `ContainedEnvironmentPolicy`, `DirectHTTP` | Owner-only config files, digests, resource grants, the contained environment. `DirectHTTP` sends one synchronous request with no cookies, cache or redirects, and returns the first status (audit forwarding, OAuth). |

About a quarter of the files are wrapped whole in `#if os(macOS)`: the
disk image, the Seatbelt spawn, the host server and client, and peer
identity. More files guard only some parts. Pure files should not be
wrapped: a pure file that compiles on Linux has its tests run by the Linux
CI gate.

## Common changes

**Change what a cage may read or write.** Per project, no code: add a
profile to `~/.config/rv/runtime-resources.json` (`RuntimeResourcePolicy`,
loaded and validated by `RuntimeResourcePolicyStore` in RVPolicy). A
profile applies only to the absolute paths in its `projects`. Its grants
are `executableLinks`, `readFiles`, `readTrees`, `writeTrees`,
`credentials`, `environment`, `keychain` and `secrets`. For everyone: the
Seatbelt base profile in `SeatbeltProfile.swift` (the `(deny default)`
source literal).
Micro-VM launches refuse host-path grants (`MicroVMLaunch.prepareMicroVM`).
Update the grants paragraph in `runtime-boundary.md`.

**Protect another workspace path a host tool runs later** (a new agent's
hook file). Add it to `WorkspaceRunLaterPaths` in `SeatbeltProfile.swift`.
Add the same entry to `WorkspaceControlLayout.runLaterFiles` or
`runLaterTrees` (and `runLaterPinnedDirectories` for a new parent folder)
in `Packages/rv-microvm/Sources/RVMicroVMCore/WorkspaceControlMounts.swift`.
`WorkspaceControlParityTests` fails until both match. The macOS guest and
the micro-VM placeholders (`MicroVMControlLayout`) read
`WorkspaceRunLaterPaths` directly, so they need nothing more.

**Add a network rule or denial reason.** Policy is pure: `EgressHostPolicy`
(RVDomain) and `EgressAdmission.decide`. Parsing is pure too: `EgressWire`.
`EgressProxy` only gathers inputs and carries out the verdict.

**Add a secret source or delivery.** `SecretsConfiguration` (decoding),
`SecretProviders` (reads), `SecretRelease` (the one release path),
`SecretGateway*` (substitution on the wire).

**Add a control RPC.** `WorkspaceControlProtocol` (op and codec),
`WorkspaceControlPayloads`, a case in `WorkspaceHostServer.operation`,
the client call in `WorkspaceHostClient`, and a case in
`WorkspaceOperationAuthorization.permits`. A new mutating op is refused
there, like launch and close, until `permits` changes. If clients need to
know the host supports it, add a name to `WorkspaceControlFeature`
(`WorkspaceControlProtocol.swift`) and advertise it.

## Kept in sync

These pairs have no shared code. Change both sides in one PR.

| This | Must match | Why |
|---|---|---|
| `WorkspaceRunLaterPaths` (`SeatbeltProfile`) and the control lists in `MicroVMControlLayout` (`MicroVMPlaceholders`) | `WorkspaceControlLayout` in `Packages/rv-microvm` (`WorkspaceControlMounts.swift`) | A path the Seatbelt cage protects but the Linux guest does not is a path a VM guest can plant. `WorkspaceControlParityTests` reads the guest lists from source and fails on drift. The macOS guest reuses `workspaceControlDenies` (`macOSGuestSandboxProfile` in `MicroVMLaunch`), so it needs no copy. |
| `MicroVMLaunchOptions` bounds, `MicroVMHelper.guestProfileVariable`, the forwarded-environment prefix (`MicroVMLaunch`) | `RunOptions`, `MacVMRunner.profileVariable`, `GuestEnvironment.forwardedPrefix` in `Packages/rv-microvm` | The helper is a separate binary; argv and environment are the only contract. |
| `LandlockAccessFS` bits (`LandlockRuleset`) | `landlock_apply.c` | Swift compiles the ruleset; C applies it. |

## Testing

- Pure decision code has tests that run anywhere: `WorkspaceSessionLifecycleTests`,
  `WorkspaceCloseStateTests`, `EgressAdmissionTests`, `WorkspaceRecoveryPlanTests`,
  `WorkspaceControlParityTests`. `RuntimeAdmissionTests` runs on Linux too,
  but some of its tests are macOS-only.
- Disk-image, Seatbelt and host-server tests need macOS; CI shards them
  (`.github/workflows/pr.yml`). Many `WorkspaceHostTests` are gated on
  `peerTrustCI`.
- `Scripts/gate.sh` picks test filters from your diff.
- Tests must not touch the real `~/.config/rv`.
