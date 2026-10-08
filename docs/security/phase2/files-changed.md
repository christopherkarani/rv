# Exact draft files by intended unit

These are working-tree groups, not opened or landed PRs. Vendor is excluded.

## PR4 peer authentication

```text
Package.swift
Sources/RVIsolation/WorkspacePeerAuthenticator.swift
Sources/RVService/AuthenticatedPeer.swift
Sources/RVService/MacOSPeerAuthenticator.swift
Sources/RVService/XPCEvaluateClient.swift
Sources/RVService/XPCListener.swift
Tests/RVIsolationTests/WorkspacePeerAuthenticatorTests.swift
Tests/RVServiceTests/MacOSPeerAuthenticatorTests.swift
Tests/RVServiceTests/XPCEndpointLifetimeTests.swift
Tests/RVServiceTests/XPCPlatformEvidenceTests.swift
docs/security/phase-2-peer-platform-proof.md
docs/security/phase2/injection-library.c
docs/security/phase2/injection-peer.c
docs/security/phase2/injection-probe-result.txt
```

## PR5 authenticated dispatch and workspace

```text
Sources/RVIPC/IPCEnvelope.swift
Sources/RVIsolation/WorkspaceHostClient.swift
Sources/RVIsolation/WorkspaceHostServer.swift
Sources/RVIsolation/WorkspaceOperationAuthorization.swift
Sources/RVService/AuthenticatedRequestContext.swift
Sources/RVService/ServiceRuntime.swift
Tests/RVServiceTests/AuthenticatedDispatchTests.swift
```

## PR6 approval subject and owner authorization

```text
Sources/RVDomain/ApprovalSubject.swift
Sources/RVDomain/PendingApproval.swift
Sources/RVDomain/PendingApprovalLedger.swift
Sources/RVService/ApprovalRuntime.swift
Sources/RVService/ControlAuthorization.swift
Sources/RVService/OwnerAuthenticator.swift
Tests/RVServiceTests/ControlAuthorizationTests.swift
docs/security/phase-2-owner-authentication-status.md
docs/security/phase2/OwnerAuthenticationProbe.swift
docs/security/phase2/owner-authentication-probe-result.txt
```

## PR7 fallback and administrative closure

```text
Sources/RVCLI/AllowOnceCommand.swift
Sources/RVCLI/AllowlistCommand.swift
Sources/RVCLI/Commands/PacksCommand.swift
Sources/RVCLI/Commands/PolicyCommand.swift
Sources/RVCLI/Commands/PolicyDraftCommand.swift
Sources/RVCLI/Commands/SafetyCommand.swift
Sources/RVCLI/Commands/SetupCommand.swift
Sources/RVCLI/Commands/UninstallCommand.swift
Sources/RVCLI/Commands/WorkspaceCommand.swift
Sources/RVCLI/LocalControlBoundary.swift
Sources/RVCLI/Service/ServiceClient.swift
Sources/RVCLI/Setup/HostLifecycle.swift
Sources/RVCLI/Setup/SetupError.swift
Sources/RVCLI/Setup/SetupHostWrites.swift
Sources/RVCLI/Setup/SetupRun.swift
Sources/RVCLI/Setup/SetupServiceInstall.swift
Sources/RVCLI/Setup/SetupUninstall.swift
Sources/rv-c/README.md
Sources/rv-c/rv.c
Sources/rv-c/tests/run.sh
Tests/RVCLITests/LocalControlBoundaryTests.swift
```

## Shared reporting and retained verification

```text
docs/security/phase2/entry-points.md
docs/security/phase2/files-changed.md
docs/security/phase2/progress.md
docs/security/phase2/result.md
docs/security/phase2/verification/RVCLITests.log
docs/security/phase2/verification/RVDomainTests.log
docs/security/phase2/verification/RVHooksTests.log
docs/security/phase2/verification/RVIPCTests.log
docs/security/phase2/verification/RVIsolationTests.log
docs/security/phase2/verification/RVPolicyTests.log
docs/security/phase2/verification/RVServiceTests.log
docs/security/phase2/verification/c.log
docs/security/phase2/verification/contained-client-hook.txt
docs/security/phase2/verification/contained-client-redeem.txt
docs/security/phase2/verification/preflight.log
docs/security/phase2/verification/standard-gate.log
docs/security/phase2/verification/summary.json
```
