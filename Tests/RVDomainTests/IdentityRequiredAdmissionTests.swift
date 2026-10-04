import Foundation
import Testing
@testable import RVDomain

/// Step 8 F3: sensitive mediated operations require a live authenticated
/// `AgentInstance`. The identity-required door rejects principal-less
/// channels with `.principalRequired` instead of silently downgrading to
/// capability-only, while the legacy door keeps its historical behavior
/// for explicitly non-sensitive use.
@Suite("IdentityRequiredAdmission")
struct IdentityRequiredAdmissionTests {
    @Test func legacyBindingWithoutPrincipalIsRejectedBeforePolicy() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        var proposed = false
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker"))
        ) { _ in
            proposed = true
            return .success(fixture.inside)
        }
        #expect(proposed == false)
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.principalRequired))
        #expect(decision.event.authorization == .rejected)
        #expect(decision.event.executionAttempted == false)
    }

    @Test func legacyBindingWithSmuggledContextStillRejected() {
        // Even if a context object is somehow presented for a binding
        // that names no instance, the door refuses: the RV-held binding
        // is what names the principal, not the presented value.
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        var proposed = false
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker")),
            agentContext: fixture.activeContext
        ) { _ in
            proposed = true
            return .success(fixture.inside)
        }
        #expect(proposed == false)
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.principalRequired))
        // Step 8 (F3 re-review): the smuggled context is not stamped into
        // audit fields — the event attributes the channel only.
        #expect(decision.event.agentInstance == nil)
        #expect(decision.event.agentDefinition == nil)
    }

    @Test func boundBindingWithoutPresentedContextIsRejected() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        var proposed = false
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker"))
        ) { _ in
            proposed = true
            return .success(fixture.inside)
        }
        #expect(proposed == false)
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.principalRequired))
    }

    @Test func boundActivePrincipalReachesPolicy() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker")),
            agentContext: fixture.activeContext
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute != nil)
        #expect(decision.event.authorization == .allowed)
    }

    @Test func revokedPrincipalIsRejected() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker")),
            agentContext: fixture.revokedContext
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.inactiveSession))
    }

    @Test func mismatchedPrincipalIsRejectedAsImpersonation() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker")),
            agentContext: fixture.foreignContext
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.impersonation))
    }

    @Test func wrongCapabilityIsRejectedBeforePrincipalChecks() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker", capability: RuntimeCapability())),
            agentContext: fixture.activeContext
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.invalidCapability))
    }

    @Test func unknownChannelKeepsUnknownSession() {
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding?
        let decision = RuntimeAdmissionGate.submitIdentityRequired(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker")),
            agentContext: fixture.activeContext
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.unknownSession))
    }

    @Test func legacyDoorStillAdmitsCapabilityOnlyChannels() {
        // Pin the preserved legacy behavior: `submit` (not the
        // identity-required door) still authenticates a principal-less
        // binding on channel facts. Sensitive mediation must not use it.
        let fixture = IdentityFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submitLegacy(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker"))
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute != nil)
    }
}

private struct IdentityFixture {
    let workspace: WorkingDirectory
    let session: RuntimeSession
    let capability: RuntimeCapability
    let binding: RuntimeChannelBinding
    let boundBinding: RuntimeChannelBinding
    let instance: AgentInstance
    let activeContext: AuthenticatedAgentContext
    let revokedContext: AuthenticatedAgentContext
    let foreignContext: AuthenticatedAgentContext
    let inside: ProposedAction

    init() {
        let workspace = WorkingDirectory(validating: "/tmp/rv-identity-admission")!
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 0),
            child: nil
        )
        let capability = RuntimeCapability()
        let definition = AgentDefinition(
            id: AgentDefinitionID(rawValue: "step8"),
            displayName: "Step8",
            blurb: "",
            executableRequirement: ExecutableRequirement(allowsUnsigned: true),
            hookHost: .opencode,
            agentTag: "opencode",
            resourceProfile: RuntimeResourceProfile(id: "test", projects: []),
            credentialBindings: [],
            requiredAssurance: .launchObserved,
            authorityCeiling: AgentAuthority(scopes: ["shell"])
        )
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(definition),
            workspaceSessionID: session.workspaceSessionID,
            runtimeSessionID: session.id,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: definition.authorityCeiling,
            delegableAuthority: definition.authorityCeiling,
            mintedAt: Date(timeIntervalSince1970: 0)
        )
        let foreign = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(definition),
            workspaceSessionID: WorkspaceSessionID(),
            runtimeSessionID: RuntimeSessionID(),
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 200),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: definition.authorityCeiling,
            delegableAuthority: definition.authorityCeiling,
            mintedAt: Date(timeIntervalSince1970: 0)
        )
        self.workspace = workspace
        self.session = session
        self.capability = capability
        binding = RuntimeChannelBinding(session: session, capability: capability)
        boundBinding = RuntimeChannelBinding(
            session: session, capability: capability, agentInstanceID: instance.id
        )
        self.instance = instance
        activeContext = AuthenticatedAgentContext(instance: instance, validity: .active)
        revokedContext = AuthenticatedAgentContext(instance: instance, validity: .inactive)
        foreignContext = AuthenticatedAgentContext(instance: foreign, validity: .active)
        let path = "\(workspace.rawValue)/marker"
        let target = FilesystemTarget(
            apparent: path, canonical: path, scope: .insideRepository, kind: .unknown
        )
        inside = .shell(
            ShellAction(
                fingerprint: ActionFingerprint(
                    rawValue: "runtime:\(session.id.rawValue.uuidString):\(workspace.rawValue):touch marker"
                ),
                scope: ActionScope(workingDirectory: workspace),
                supportingCommand: ShellCommand(rawValue: "touch marker"),
                filesystemAction: .create(targets: [target])
            )
        )
    }

    func frame(command: String, capability: RuntimeCapability? = nil) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(),
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }
}
