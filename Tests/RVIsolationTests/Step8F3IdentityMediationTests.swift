#if os(macOS)
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Step 8 F3, session level: identity-required mediation resolves the
/// trusted principal fresh from the Step 7 registry on every request.
/// Principal-less channels are rejected before sensitive policy work;
/// revocation takes effect on the next request; legacy capability-only
/// behavior is preserved on the legacy door only.
@Suite("Step 8 F3 identity mediation")
struct Step8F3IdentityMediationTests {
    @Test func legacyBindingIsRejectedBeforePolicy() throws {
        let harness = try IdentityMediationHarness(bound: false)
        defer { harness.cleanup() }
        let decision = harness.session.submitIdentityRequired(
            .success(harness.frame("touch marker"))
        )
        guard case .rejected(.principalRequired) = decision.response else {
            Issue.record("legacy channel must be principalRequired, got \(decision.response)")
            return
        }
        #expect(decision.execute == nil)
        #expect(decision.event.authorization == .rejected)
        #expect(harness.effect.runs == 0)
        #expect(harness.normalized.all.isEmpty)
    }

    @Test func boundActivePrincipalReachesPolicyWithTrustedSubject() throws {
        let harness = try IdentityMediationHarness(bound: true)
        defer { harness.cleanup() }
        let decision = harness.session.submitIdentityRequired(
            .success(harness.frame("touch marker"))
        )
        #expect(decision.event.authorization == .allowed)
        #expect(harness.effect.runs == 1)
        let subjects = harness.normalized.all
        #expect(subjects.count == 1)
        let presented = try #require(subjects.first?.agent)
        #expect(presented.instance.id == harness.instance.id)
        #expect(presented.validity == .active)
        #expect(presented.instance.runtimeSessionID == harness.runtime.id)
        #expect(presented.instance.workspaceSessionID == harness.runtime.workspaceSessionID)
    }

    @Test func revokedPrincipalIsRejectedOnNextRequest() throws {
        let harness = try IdentityMediationHarness(bound: true)
        defer { harness.cleanup() }
        let first = harness.session.submitIdentityRequired(
            .success(harness.frame("touch marker", id: UUID()))
        )
        #expect(first.event.authorization == .allowed)
        #expect(harness.effect.runs == 1)
        #expect(harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true } == .revoked)
        let second = harness.session.submitIdentityRequired(
            .success(harness.frame("touch marker", id: UUID()))
        )
        guard case .rejected(.inactiveSession) = second.response else {
            Issue.record("revoked principal must be rejected, got \(second.response)")
            return
        }
        #expect(second.execute == nil)
        #expect(harness.effect.runs == 1)
    }

    @Test func legacyDoorStillAdmitsHarmlessCapabilityOnlyUse() throws {
        // Pin preserved legacy behavior: the legacy door still
        // authenticates a principal-less channel on channel facts.
        // Sensitive mediation must use the identity-required door.
        let harness = try IdentityMediationHarness(bound: false)
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(.success(harness.frame("touch marker")))
        #expect(decision.event.authorization == .allowed)
        #expect(harness.effect.runs == 1)
    }
}

private final class MediationEffect: Sendable {
    private let runsBox = Mutex(0)

    var runs: Int { runsBox.withLock { $0 } }

    func run(_: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        runsBox.withLock { $0 += 1 }
        return .success(0)
    }
}

private final class NormalizedSubjects: Sendable {
    private let box = Mutex<[RuntimeAdmissionSubject]>([])

    var all: [RuntimeAdmissionSubject] { box.withLock { $0 } }

    func record(_ subject: RuntimeAdmissionSubject) {
        box.withLock { $0.append(subject) }
    }
}

private struct IdentityMediationHarness {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let registry: AgentInstanceRegistry
    let instance: AgentInstance
    let effect: MediationEffect
    let normalized: NormalizedSubjects
    let session: RuntimeAdmissionSession

    init(bound: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-step8f3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let effect = MediationEffect()
        let normalized = NormalizedSubjects()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { subject, action in
                normalized.record(subject)
                guard case .shell(let command) = action,
                    command.rawValue == "touch marker"
                else {
                    return .failure(.failed)
                }
                let path = "\(subject.policyWorkspace.rawValue)/marker"
                let target = FilesystemTarget(
                    apparent: path, canonical: path, scope: .insideRepository, kind: .unknown
                )
                return .success(
                    .shell(
                        ShellAction.analyzed(
                            AnalyzedShell(
                                fingerprint: ActionFingerprint(
                                    rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):touch marker"
                                ),
                                scope: ActionScope(workingDirectory: subject.policyWorkspace),
                                supportingCommand: command,
                                analysis: .filesystem(.create(targets: [target]))
                            )
                        )
                    )
                )
            },
            executor: .effect(effect.run),
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
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
        let registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("agent-instances.jsonl")))
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(definition),
            workspaceSessionID: runtime.workspaceSessionID,
            runtimeSessionID: runtime.id,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: definition.authorityCeiling,
            delegableAuthority: definition.authorityCeiling,
            mintedAt: Date()
        )
        let session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        if bound {
            guard registry.announce(instance) else { throw MediationHarnessError.announceFailed }
            guard let established = EstablishedRuntimeSession(
                session: runtime, instance: instance, establishedAt: Date()),
                registry.activate(established) != nil
            else {
                throw MediationHarnessError.activateFailed
            }
            guard session.bindAgentInstance(instance.id, registry: registry) else {
                throw MediationHarnessError.bindFailed
            }
        }
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.registry = registry
        self.instance = instance
        self.effect = effect
        self.normalized = normalized
        self.session = session
    }

    func frame(_ command: String, id: UUID = UUID()) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum MediationHarnessError: Error {
    case announceFailed
    case activateFailed
    case bindFailed
}
#endif
