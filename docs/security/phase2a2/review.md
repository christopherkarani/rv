# Fresh Phase 2A.2 review

New independent code-reviewer inspected the locked spec/current final source candidate, authorization model, CLI call chain, live provisioning readiness and six real peer-boundary tests. No implementation rationale or synthetic successful oracle was supplied. The reviewer made no edits or test calls.

## Independently verified blockers

1. `WorkspaceOperationAuthorization.permits`, Sources/RVIsolation/WorkspaceOperationAuthorization.swift:12–15 refuses both identity launch operations. HostServer.operation:455 enforces before launchIdentity. The authoritative runtime registry and host-to-service bridge validate launched agent contexts; neither issues launch-control permission.
2. The actual CLI can stop earlier: WorkspaceCommandRun.runInteractiveSelection calls WorkspaceHosts.ensure; WorkspaceHostProcess.swift:215 requires client.describe; WorkspaceOperationAuthorization.swift:10 permits that only to service/workspaceHost, excluding cli. Enabling only the launch opcode cannot complete the CLI path.
3. Fixed protected manifest `/Library/Application Support/RV/peer-trust.json` is absent. Main independently ran `sudo -n true`, which returned password-required/exit1 without writes. WorkspaceClient.connect requires installed protected trust before Hello; no authenticated installed success proof exists.
4. Unix peer capture identifies connector, not every forwarded-FD writer (WorkspacePeerAuthenticator.swift:204). Captured connection evidence is retained for subsequent frames. Blanket mutation refusal prevents current control acquisition but does not prove a future permit resists forwarding.
5. ControlAuthorizationBroker requires a PendingApproval/ApprovalSubject and default LocalOwnerAuthenticator invokes LAContext. It is not an implemented launch issuer and was not reused.

A separate architect independently verified that no existing source issuer distinguishes legitimate launch-control delegation from component code identity and decoded intent. The locked v1 spec does not mandate fresh LocalAuthentication for launch; no claim of inherent design impossibility is made. The missing issuer and unavailable trust setup trigger the user's stop conditions in this environment.

## Verdict

BLOCKED by acceptance conditions. No new source defect or privilege escalation was introduced because authorization source remained unchanged. No source/test modifications were made in review or implementation; the pass records blockers instead of manufacturing a role-based permit.
