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
  └─ WorkspaceClient ── control frames ──▶ rv-workspace-host
       WorkspaceControlProtocol/Payloads      WorkspaceHostServer
                                                └─ WorkspaceSessionSupervisor
                                                     open:   WorkspaceRecovery.admit → WorkspaceInodeBoundary (disk image)
                                                     launch: prepareSeatbelt | prepareMicroVM → spawn
                                                             SecretLaunchBroker, EgressProxy, RuntimeAdmissionSession
                                                     close:  publish → detach → restore, lifecycle log
```

The CLI never owns a workspace (`Tests/RVCLITests/WorkspaceOwnershipTests`
enforces it). `IsolationBackends.apply` / `LocalExecutor` are a separate,
one-shot door used by tests and the executor.

## Areas

| Area | Files | What it owns |
|---|---|---|
| Plans and backends | `IsolationApply`, `SeatbeltProfile`, `LandlockApply`, `LandlockRuleset`, `landlock_apply.c`, `MicroVMLaunch`, `MicroVMPlaceholders` | Turning an `IsolationPlan` (RVDomain) into OS rules and starting the process. Landlock compiles but Linux launches refuse before exec. |
| Spawning | `SessionSupervisor` (free functions, not a type), `SpawnPrimitives`, `ProcessGroupRecovery`, `RuntimeTerminal`, `LocalTerminalMode`, `TerminalStream` | `posix_spawn` under Seatbelt, process-group cleanup, ptys, the contained environment. |
| Workspace session | `WorkspaceSessionSupervisor`, `WorkspaceCloseState`, `WorkspaceSessionLifecycle`, `WorkspaceLifecycleLog`, `WorkspaceOwnerLock`, `PreparedWorkspaceLaunch`, `WorkspaceTerminalSession` | One open workspace: runtimes in it, close, abandon. |
| Private copy (macOS) | `WorkspaceInodeBoundary`, `WorkspaceBoundaryEstablish`, `WorkspaceTreeCopy`, `WorkspacePublishPlan`, `DiskImage*`, `WorkspaceDisk*`, `WorkspaceMountFacts`, `WorkspaceFilesystemMetadata` | The disk-image volume the agent writes to, and publishing it back. |
| Recovery | `WorkspaceRecovery`, `WorkspaceRecoveryPlan`, `WorkspaceAbandon`, `WorkspaceLeftovers` | Finishing a close that a crash interrupted; listing leftover images. |
| Host process and wire | `WorkspaceHostServer`, `WorkspaceHostClient`, `WorkspaceHost*Handler`, `WorkspaceHostProcess`, `WorkspaceHostEndpoint`, `WorkspaceControl*` | The `rv-workspace-host` daemon and its RPC. |
| Admission | `RuntimeAdmission`, `RuntimeAdmissionSpawn`, `ExecutableAction`, `ActionApprovalAsk`, `LocalExecutor` | A caged process asking rv to run one command or one HTTPS GET. Pure gate: `RuntimeAdmissionGate` in RVDomain. |
| Egress | `EgressProxy`, `EgressAdmission`, `EgressBinaryPinCache`, `NetworkReviewQueue`, `TransparentHTTPS`, `HTTPDirectConnector` | The per-runtime loopback proxy every outbound request goes through. Pure policy: `EgressAdmission.decide`, `EgressPolicy` in RVDomain. |
| Secrets | `Secret*`, `SecretGateway*`, `SecretsConfiguration`, `VarlockSchema`, `EnvSpec`, `KeychainReader`, `KnownSecretDefaults` | Releasing secrets and swapping placeholders for real values on the way out. Every read goes through `SecretRelease.release(_:to:)`. |
| Peer identity | `WorkspacePeerAuthenticator`, `MacOSPeerAuthenticator`, `AuthenticatedPeer`, `WorkspacePrincipalAuthority`, `DaemonTrustVerdict` | Who is on the other end of a socket. |
| Agent identity | `AgentInstanceRegistry`, `AgentInstanceJournal`, `AgentTurn` | Per-agent instances and their journal. |
| Shared plumbing | `OwnerOnlyFile`, `FileDigest`, `ManagedSerialStore`, `RuntimeSessionLog`, `RuntimeResource*`, `ContainedEnvironmentPolicy` | Owner-only config files, digests, resource grants, the contained environment. |

Most files are wrapped in `#if os(macOS)`. Pure files should not be: a
pure file that compiles on Linux has its tests run by the Linux CI gate.

## Common changes

**Change what a cage may read or write.** Per project, no code: add the path
to the runtime resource policy (`readTrees`, `readFiles`, `writeTrees`;
validated in `RVPolicy/RuntimeResourcePolicyStore`). For everyone: the
Seatbelt base profile in `SeatbeltProfile.swift` (the `(deny default)`
source literal).
Micro-VM launches refuse host-path grants (`MicroVMLaunch.prepareMicroVM`).
Update the grants paragraph in `runtime-boundary.md`.

**Protect another workspace path a host tool runs later** (a new agent's
hook file). Add it to `WorkspaceRunLaterPaths` in `SeatbeltProfile.swift`,
then make the micro-VM guest cover it too (see "Kept in sync" below).

**Add a network rule or denial reason.** Policy is pure: `EgressPolicy`
(RVDomain) and `EgressAdmission.decide`. `EgressProxy` only gathers inputs
and carries out the verdict.

**Add a secret source or delivery.** `SecretsConfiguration` (decoding),
`SecretProviders` (reads), `SecretRelease` (the one release path),
`SecretGateway*` (substitution on the wire).

**Add a control RPC.** `WorkspaceControlProtocol` (op and codec),
`WorkspaceControlPayloads`, a case in `WorkspaceHostServer.operation`,
the client call in `WorkspaceHostClient`, and authorization in
`WorkspaceOperationAuthorization`.

## Kept in sync by hand

These pairs have no shared code. Change both sides in one PR.

| This | Must match | Why |
|---|---|---|
| `workspaceControlDenies` and `WorkspaceRunLaterPaths` (`SeatbeltProfile`) | `MicroVMControlPlaceholders`, `WorkspaceControlMounts` in `Packages/rv-microvm` | A path the Seatbelt cage protects but the guest does not is a path a VM guest can plant. |
| `MicroVMLaunchOptions` bounds, `MicroVMHelper.guestProfileVariable`, the forwarded-environment prefix (`MicroVMLaunch`) | `RunOptions`, `MacVMRunner.profileVariable`, `GuestEnvironment.forwardedPrefix` in `Packages/rv-microvm` | The helper is a separate binary; argv and environment are the only contract. |
| `LandlockAccessFS` bits (`LandlockRuleset`) | `landlock_apply.c` | Swift compiles the ruleset; C applies it. |

## Testing

- Pure decision code has tests that run anywhere: `WorkspaceSessionLifecycleTests`,
  `WorkspaceCloseStateTests`, `EgressAdmissionTests`, `RuntimeAdmissionTests`.
- Disk-image, Seatbelt and host-server tests need macOS; CI shards them
  (`.github/workflows/pr.yml`). Many `WorkspaceHostTests` are gated on
  `peerTrustCI`.
- `Scripts/gate.sh` picks test filters from your diff.
- Tests must not touch the real `~/.config/rv`.
