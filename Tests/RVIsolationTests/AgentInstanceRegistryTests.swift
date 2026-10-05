#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

private func makeRegistryDefinition(
    id: String = "claude",
    authorityCeiling: AgentAuthority = AgentAuthority(scopes: ["fs.read", "shell"])
) -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: id),
        displayName: "Test",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: .claude,
        agentTag: "claude",
        resourceProfile: RuntimeResourceProfile(id: "test", projects: []),
        credentialBindings: [],
        requiredAssurance: .launchObserved,
        authorityCeiling: authorityCeiling
    )
}

private func makeRegistryInstance(
    definition: AgentDefinition,
    workspace: WorkspaceSessionID,
    runtime: RuntimeSessionID,
    authority: AgentAuthority? = nil
) -> AgentInstance {
    let granted = authority ?? definition.authorityCeiling
    return AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: definition.id,
        definitionRevision: AgentDefinitionRevision.resolve(definition),
        workspaceSessionID: workspace,
        runtimeSessionID: runtime,
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: granted,
        delegableAuthority: granted,
        mintedAt: Date(timeIntervalSince1970: 0)
    )
}

private func makeRegistrySession(
    runtime: RuntimeSessionID,
    workspace: WorkspaceSessionID
) -> RuntimeSession {
    let directory = WorkingDirectory(validating: FileManager.default.temporaryDirectory.path)!
    return RuntimeSession(
        id: runtime,
        workspaceSessionID: workspace,
        host: .opencode,
        workspace: directory,
        backend: .seatbelt,
        startedAt: Date(),
        child: nil
    )
}

private func registryJournal(at root: URL) -> (AgentInstanceRegistry, URL) {
    let url = root.appendingPathComponent("agent-instances-\(UUID().uuidString).jsonl")
    return (AgentInstanceRegistry(journal: .file(url)), url)
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-agent-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Counts authorized executions without linking RVEngine.
private final class EffectCounter: Sendable {
    private let runs = Mutex(0)

    func run(_ action: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        runs.withLock { $0 += 1 }
        return .success(0)
    }

    var count: Int { runs.withLock { $0 } }
}

/// Admits `touch <name>` inside the workspace (allowed under `.empty`,
/// mirroring the RuntimeAdmissionTests shape) and refuses everything else.
private func allowTouchNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard case .shell(let command) = action else { return .failure(.failed) }
    let raw = command.rawValue
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.count == 2, tokens[0] == "touch", tokens[1].hasPrefix("/") == false else {
        return .failure(.failed)
    }
    return .success(
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(
                    rawValue: "registry:\(subject.session.id.rawValue.uuidString):\(raw)"
                ),
                effects: ActionEffects(kinds: [.filesystemCreate]),
                resources: ActionResources(
                    path: tokens[1],
                    filesystemScope: .insideRepository,
                    resourceKind: .unknown
                ),
                scope: ActionScope(workingDirectory: subject.policyWorkspace),
                supportingCommand: command
            )
        )
    )
}

private struct RegistryAdmissionHarness {
    let root: URL
    let definition: AgentDefinition
    let session: RuntimeSession
    let capability: RuntimeCapability
    let registry: AgentInstanceRegistry
    let journalURL: URL
    let admission: RuntimeAdmissionSession
    let effects: EffectCounter

    init(
        normalize: @escaping @Sendable (
            RuntimeAdmissionSubject, RuntimeRequestedAction
        ) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> = allowTouchNormalize
    ) throws {
        let root = try temporaryRoot()
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let journalURL = root.appendingPathComponent("agent-instances.jsonl")
        let effects = EffectCounter()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: normalize,
            executor: .effect(effects.run),
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
        self.root = root
        self.definition = makeRegistryDefinition()
        self.session = session
        self.capability = RuntimeCapability()
        self.registry = AgentInstanceRegistry(journal: .file(journalURL))
        self.journalURL = journalURL
        self.effects = effects
        self.admission = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: session, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
    }

    func frame(_ command: String) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }

    /// Announces an instance for this harness session and binds the channel.
    func announceAndBind() -> AgentInstance? {
        let instance = makeRegistryInstance(
            definition: definition,
            workspace: session.workspaceSessionID,
            runtime: session.id
        )
        guard registry.announce(instance) else { return nil }
        guard admission.bindAgentInstance(instance.id, registry: registry) else { return nil }
        return instance
    }

    func activate(_ instance: AgentInstance) -> AuthenticatedAgentContext? {
        guard
            let established = EstablishedRuntimeSession(
                session: session,
                instance: instance,
                establishedAt: Date()
            )
        else {
            return nil
        }
        return registry.activate(established)
    }

    func cleanup() {
        admission.finish()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("AgentInstanceRegistry")
struct AgentInstanceRegistryTests {
    @Test func runtimeBindsExactlyOneInstance() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, _) = registryJournal(at: root)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let first = makeRegistryInstance(definition: definition, workspace: workspace, runtime: runtime)
        let second = makeRegistryInstance(definition: definition, workspace: workspace, runtime: runtime)
        #expect(registry.announce(first))
        #expect(registry.announce(second) == false)
        #expect(registry.announce(first) == false)
        #expect(registry.instance(forRuntime: runtime)?.id == first.id)
        #expect(registry.validity(of: second.id) == .unknown)
    }

    @Test func instanceBindsExpectedWorkspaceAndRuntime() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, _) = registryJournal(at: root)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let otherWorkspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let instance = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: runtime
        )
        #expect(registry.announce(instance))
        #expect(registry.instance(for: instance.id) == instance)
        #expect(registry.instance(forRuntime: runtime) == instance)
        #expect(registry.instances(inWorkspace: workspace) == [instance])
        #expect(registry.instances(inWorkspace: otherWorkspace).isEmpty)
        #expect(registry.instance(forRuntime: RuntimeSessionID()) == nil)
        let bound = RuntimeChannelBinding(
            session: makeRegistrySession(runtime: runtime, workspace: workspace),
            capability: RuntimeCapability(),
            agentInstanceID: instance.id
        )
        #expect(registry.instance(forBinding: bound)?.id == instance.id)
        let unbound = RuntimeChannelBinding(
            session: makeRegistrySession(runtime: runtime, workspace: workspace),
            capability: RuntimeCapability()
        )
        #expect(registry.instance(forBinding: unbound) == nil)
    }

    @Test func unregisteredIDsHaveUnknownValidity() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, _) = registryJournal(at: root)
        #expect(registry.validity(of: AgentInstanceID()) == .unknown)
        #expect(registry.validity(ofRuntime: RuntimeSessionID()) == .unknown)
        #expect(registry.generation(of: AgentInstanceID()) == nil)
        #expect(registry.context(for: AgentInstanceID()) == nil)
        #expect(registry.finishRuntime(RuntimeSessionID(), reason: .runtimeEnded) == .unknown)
        #expect(registry.revoke(AgentInstanceID(), reason: .explicitRevoke) { true } == .unknown)
    }

    @Test func announcedInstanceIsUnusableUntilEstablished() throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        #expect(harness.registry.validity(of: instance.id) == .inactive)
        // No fake active instance before establishment: the channel is
        // bound, the capability and session are right, and the request
        // still fails because the principal is not active.
        let early = harness.admission.submitLegacy(.success(harness.frame("touch early")))
        #expect(early.response == .rejected(.inactiveSession))
        #expect(harness.effects.count == 0)
        let context = try #require(harness.activate(instance))
        #expect(context.validity == .active)
        #expect(harness.registry.validity(of: instance.id) == .active)
        let admitted = harness.admission.submitLegacy(.success(harness.frame("touch marker")))
        #expect(admitted.response == .executed(exitStatus: 0))
        #expect(harness.effects.count == 1)
        #expect(admitted.event.agentInstance == instance.id.rawValue.uuidString)
        #expect(admitted.event.agentDefinition == "claude")
    }

    @Test func lifecycleMovesActiveRevokingInactive() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, url) = registryJournal(at: root)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let instance = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: runtime
        )
        #expect(registry.announce(instance))
        #expect(registry.generation(of: instance.id) == 0)
        let session = makeRegistrySession(runtime: runtime, workspace: workspace)
        let established = try #require(EstablishedRuntimeSession(
            session: session, instance: instance, establishedAt: Date()
        ))
        #expect(registry.activate(established)?.validity == .active)
        #expect(registry.generation(of: instance.id) == 1)
        #expect(registry.revoke(instance.id, reason: .explicitRevoke) { true } == .revoked)
        #expect(registry.validity(of: instance.id) == .inactive)
        #expect(registry.generation(of: instance.id) == 3)
        #expect(registry.revoke(instance.id, reason: .explicitRevoke) { true } == .alreadyInactive)
        #expect(registry.generation(of: instance.id) == 3)
        let records = AgentInstanceJournal.records(at: url)
        #expect(records.map(\.kind) == [.attempted, .established, .revoking, .finished])
        #expect(records.allSatisfy { $0.instance == instance.id.rawValue })
        #expect(records.last?.detail == "revoked:explicitRevoke")
        // History cannot reactivate: the finished id announces nothing new.
        #expect(registry.announce(instance) == false)
        #expect(registry.activate(established) == nil)
    }

    @Test func requestPayloadCannotReplacePrincipal() throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        // A channel bound to an instance the registry never announced:
        // perfect capability and session, no trusted principal.
        let phantom = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(
                session: harness.session,
                capability: harness.capability,
                agentInstanceID: AgentInstanceID()
            ),
            configuration: RuntimeAdmissionConfiguration(
                normalize: allowTouchNormalize,
                executor: .effect(harness.effects.run),
                approval: { _, _ in nil },
                policy: { _ in .empty },
                evidence: RuntimeAdmissionEvidence()
            ),
            launch: AdmittedLaunchContext(
                plan: compileContainedPlan(workspace: harness.session.workspace),
                profileSource: "(deny file-link)",
                workspacePath: harness.session.workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        defer { phantom.finish() }
        let rejected = phantom.submitLegacy(.success(harness.frame("touch phantom")))
        #expect(rejected.response == .rejected(.principalRequired))
        #expect(harness.effects.count == 0)
        // Request bytes name no principal at all: the wire frame carries
        // version, request id, capability, session claim, and action only,
        // so nothing smuggled in the payload can reach the trusted subject.
        let frame = harness.frame("touch marker")
        #expect(frame.capability == harness.capability)
        #expect(frame.claimedSession.rawValue == harness.session.id.rawValue)
    }

    @Test func normalizeSeesTrustedSubjectThePayloadCannotOverride() throws {
        final class SubjectBox: Sendable {
            private let box = Mutex<RuntimeAdmissionSubject?>(nil)
            func store(_ subject: RuntimeAdmissionSubject) {
                box.withLock { $0 = subject }
            }
            var current: RuntimeAdmissionSubject? { box.withLock { $0 } }
        }
        let seen = SubjectBox()
        let harness = try RegistryAdmissionHarness(normalize: { subject, action in
            seen.store(subject)
            return allowTouchNormalize(subject: subject, action: action)
        })
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        _ = try #require(harness.activate(instance))
        let decision = harness.admission.submitLegacy(.success(harness.frame("touch marker")))
        #expect(decision.response == .executed(exitStatus: 0))
        let subject = try #require(seen.current)
        #expect(subject.agent?.instance.id == instance.id)
        #expect(subject.agent?.validity == .active)
        #expect(subject.session.id == harness.session.id)
    }

    @Test func mismatchedPrincipalBindingFails() throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        _ = try #require(harness.activate(instance))
        // The trusted context names runtime R1 in workspace W1. A channel
        // bound to the same instance but a different session fails: the
        // binding, not the payload, decides.
        var foreignBinding: RuntimeChannelBinding? = RuntimeChannelBinding(
            session: makeRegistrySession(
                runtime: RuntimeSessionID(), workspace: harness.session.workspaceSessionID
            ),
            capability: harness.capability,
            agentInstanceID: instance.id
        )
        let foreignContext = try #require(harness.registry.context(for: instance.id))
        let foreignFrame = RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
            capability: harness.capability,
            claimedSession: RuntimeSessionClaim(
                validating: foreignBinding!.session.id.rawValue.uuidString
            )!,
            action: .shell(ShellCommand(rawValue: "touch foreign"))
        )
        let foreign = RuntimeAdmissionGate.submitLegacy(
            binding: &foreignBinding,
            frame: .success(foreignFrame),
            agentContext: foreignContext
        ) { _ in .failure(.failed) }
        #expect(foreign.response == .rejected(.impersonation))
        // Same for a workspace mismatch.
        var strayBinding: RuntimeChannelBinding? = RuntimeChannelBinding(
            session: makeRegistrySession(
                runtime: harness.session.id, workspace: WorkspaceSessionID()
            ),
            capability: harness.capability,
            agentInstanceID: instance.id
        )
        let strayFrame = RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
            capability: harness.capability,
            claimedSession: RuntimeSessionClaim(
                validating: strayBinding!.session.id.rawValue.uuidString
            )!,
            action: .shell(ShellCommand(rawValue: "touch stray"))
        )
        let stray = RuntimeAdmissionGate.submitLegacy(
            binding: &strayBinding,
            frame: .success(strayFrame),
            agentContext: foreignContext
        ) { _ in .failure(.failed) }
        #expect(stray.response == .rejected(.impersonation))
    }

    @Test func terminatedRuntimeInvalidatesAndLookupStaysDescriptive() throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        _ = try #require(harness.activate(instance))
        let before = harness.admission.submitLegacy(.success(harness.frame("touch before")))
        #expect(before.response == .executed(exitStatus: 0))
        #expect(harness.registry.finishRuntime(harness.session.id, reason: .runtimeEnded) == .revoked)
        #expect(harness.registry.validity(of: instance.id) == .inactive)
        let after = harness.admission.submitLegacy(.success(harness.frame("touch after")))
        #expect(after.response == .rejected(.inactiveSession))
        #expect(after.event.agentInstance == instance.id.rawValue.uuidString)
        #expect(harness.effects.count == 1)
        // Lookup returns state; it does NOT authenticate: the record is
        // still describable after death, but no privileged use passes.
        #expect(harness.registry.instance(for: instance.id) == instance)
        #expect(harness.registry.context(for: instance.id)?.validity == .inactive)
    }

    @Test func cachedContextNeverEqualsLiveValidity() throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        _ = try #require(harness.activate(instance))
        let stale = try #require(harness.registry.context(for: instance.id))
        #expect(stale.isUsable)
        #expect(harness.registry.revoke(instance.id, reason: .cancelled) { true } == .revoked)
        #expect(stale.isUsable)
        #expect(harness.registry.validity(of: instance.id) == .inactive)
        #expect(harness.registry.context(for: instance.id)?.isUsable == false)
        // The session re-resolves on every submit, so the stale snapshot
        // it once saw cannot authorize anything now.
        let denied = harness.admission.submitLegacy(.success(harness.frame("touch stale")))
        #expect(denied.response == .rejected(.inactiveSession))
    }

    @Test func channelBindingNeverMovesToAnotherInstance() throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        _ = try #require(harness.activate(instance))
        let other = makeRegistryInstance(
            definition: harness.definition,
            workspace: harness.session.workspaceSessionID,
            runtime: RuntimeSessionID()
        )
        #expect(harness.registry.announce(other))
        #expect(harness.admission.bindAgentInstance(other.id, registry: harness.registry) == false)
        let decision = harness.admission.submitLegacy(.success(harness.frame("touch marker")))
        #expect(decision.response == .executed(exitStatus: 0))
        #expect(decision.event.agentInstance == instance.id.rawValue.uuidString)
    }

    @Test func restartMintsFreshIDAndKeepsOldDead() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, _) = registryJournal(at: root)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let first = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: RuntimeSessionID()
        )
        #expect(registry.announce(first))
        let firstSession = makeRegistrySession(
            runtime: first.runtimeSessionID, workspace: workspace
        )
        let firstEstablished = try #require(EstablishedRuntimeSession(
            session: firstSession, instance: first, establishedAt: Date()
        ))
        _ = try #require(registry.activate(firstEstablished))
        #expect(registry.finishRuntime(first.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        let second = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: RuntimeSessionID()
        )
        #expect(second.id != first.id)
        #expect(registry.announce(second))
        let secondSession = makeRegistrySession(
            runtime: second.runtimeSessionID, workspace: workspace
        )
        let secondEstablished = try #require(EstablishedRuntimeSession(
            session: secondSession, instance: second, establishedAt: Date()
        ))
        _ = try #require(registry.activate(secondEstablished))
        #expect(registry.validity(of: first.id) == .inactive)
        #expect(registry.validity(of: second.id) == .active)
        #expect(Set(registry.instances(inWorkspace: workspace).map(\.id)) == [first.id, second.id])
    }

    @Test func recoveryResurrectsNothing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("agent-instances.jsonl")
        let live = AgentInstanceRegistry(journal: .file(url))
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let instance = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: runtime
        )
        #expect(live.announce(instance))
        let session = makeRegistrySession(runtime: runtime, workspace: workspace)
        let established = try #require(EstablishedRuntimeSession(
            session: session, instance: instance, establishedAt: Date()
        ))
        _ = try #require(live.activate(established))
        #expect(live.revoke(instance.id, reason: .lostOwnership) { true } == .revoked)
        // Crash: the process is gone. Recovery starts a fresh registry over
        // the same journal file. Disk describes; it never resurrects.
        let recovered = AgentInstanceRegistry(journal: .file(url))
        #expect(recovered.validity(of: instance.id) == .unknown)
        #expect(recovered.validity(ofRuntime: runtime) == .unknown)
        #expect(recovered.context(for: instance.id) == nil)
        #expect(recovered.activate(established) == nil)
        #expect(recovered.finishRuntime(runtime, reason: .runtimeEnded) == .unknown)
        guard case .decoded(let read) = AgentInstanceJournal.load(at: url) else {
            Issue.record("journal must describe the finished instance")
            return
        }
        #expect(read.records.map(\.kind) == [.attempted, .established, .revoking, .finished])
        #expect(read.tornTrailing == false)
        #expect(read.interiorCorruption == false)
    }

    @Test func cleanupFailureKeepsAuthorityDead() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, url) = registryJournal(at: root)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let instance = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: runtime
        )
        #expect(registry.announce(instance))
        let session = makeRegistrySession(runtime: runtime, workspace: workspace)
        let established = try #require(EstablishedRuntimeSession(
            session: session, instance: instance, establishedAt: Date()
        ))
        _ = try #require(registry.activate(established))
        #expect(registry.revoke(instance.id, reason: .runtimeEnded) { false } == .revoked)
        #expect(registry.validity(of: instance.id) == .inactive)
        #expect(registry.activate(established) == nil)
        let records = AgentInstanceJournal.records(at: url)
        #expect(records.map(\.kind) == [.attempted, .established, .revoking, .finished])
        #expect(records.last?.detail == "revoked:runtimeEnded;teardownFailed")
    }

    @Test func delegationNarrowsThroughRegistry() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, url) = registryJournal(at: root)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let parent = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: RuntimeSessionID()
        )
        #expect(registry.announce(parent))
        let parentSession = makeRegistrySession(
            runtime: parent.runtimeSessionID, workspace: workspace
        )
        let parentEstablished = try #require(EstablishedRuntimeSession(
            session: parentSession, instance: parent, establishedAt: Date()
        ))
        _ = try #require(registry.activate(parentEstablished))
        // Narrow is accepted: distinct child id, parent preserved, own
        // runtime binding, announced but not yet active.
        let narrow = AgentAuthority(scopes: ["fs.read"])
        let childRuntime = RuntimeSessionID()
        let child = try #require(registry.delegateChild(
            from: parent.id,
            authority: narrow,
            runtimeSessionID: childRuntime,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 200),
            workloadProcess: nil
        ))
        #expect(child.id != parent.id)
        #expect(child.runtimeSessionID == childRuntime)
        #expect(child.parent?.parentInstanceID == parent.id)
        #expect(child.parent?.delegatedAuthority == narrow)
        #expect(child.effectiveAuthority == narrow)
        #expect(child.owner == parent.owner)
        #expect(child.workspaceSessionID == parent.workspaceSessionID)
        #expect(registry.validity(of: child.id) == .inactive)
        #expect(registry.instance(forRuntime: childRuntime)?.id == child.id)
        // The child's own establishment activates it.
        let childSession = makeRegistrySession(runtime: childRuntime, workspace: workspace)
        let childEstablished = try #require(EstablishedRuntimeSession(
            session: childSession, instance: child, establishedAt: Date()
        ))
        _ = try #require(registry.activate(childEstablished))
        #expect(registry.validity(of: child.id) == .active)
        // Widen is rejected; the parent record is untouched.
        #expect(registry.delegateChild(
            from: parent.id,
            authority: AgentAuthority(scopes: ["fs.read", "shell", "net.admin"]),
            runtimeSessionID: RuntimeSessionID(),
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 201),
            workloadProcess: nil
        ) == nil)
        #expect(registry.delegateChild(
            from: parent.id,
            authority: narrow,
            runtimeSessionID: childRuntime,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 202),
            workloadProcess: nil
        ) == nil)
        let storedParent = try #require(registry.instance(for: parent.id))
        #expect(storedParent.effectiveAuthority == definition.authorityCeiling)
        #expect(storedParent.parent == nil)
        // Dead parents delegate nothing.
        #expect(registry.revoke(parent.id, reason: .explicitRevoke) { true } == .revoked)
        #expect(registry.delegateChild(
            from: parent.id,
            authority: narrow,
            runtimeSessionID: RuntimeSessionID(),
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 203),
            workloadProcess: nil
        ) == nil)
        let childLines = AgentInstanceJournal.records(at: url).filter {
            $0.instance == child.id.rawValue
        }
        #expect(childLines.map(\.kind) == [.attempted, .established])
        #expect(childLines.first?.parent == parent.id.rawValue)
    }

    @Test func journalFailureRefusesEstablishment() throws {
        let failing = AgentInstanceJournalStore(
            append: { _ in .failure(.sessionRecordFailed) },
            file: nil
        )
        let registry = AgentInstanceRegistry(journal: failing)
        let definition = makeRegistryDefinition()
        let instance = makeRegistryInstance(
            definition: definition,
            workspace: WorkspaceSessionID(),
            runtime: RuntimeSessionID()
        )
        #expect(registry.announce(instance) == false)
        #expect(registry.validity(of: instance.id) == .unknown)
        #expect(registry.instance(forRuntime: instance.runtimeSessionID) == nil)
    }

    @Test func revokingIsObservableWhileTeardownRuns() async throws {
        let harness = try RegistryAdmissionHarness()
        defer { harness.cleanup() }
        let instance = try #require(harness.announceAndBind())
        _ = try #require(harness.activate(instance))
        final class Latch: Sendable {
            private let state = Mutex<(entered: Bool, release: Bool)>((false, false))
            func enter() { state.withLock { $0.entered = true } }
            var entered: Bool { state.withLock { $0.entered } }
            func open() { state.withLock { $0.release = true } }
            func waitForRelease() {
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if state.withLock({ $0.release }) { return }
                    usleep(1_000)
                }
            }
        }
        let latch = Latch()
        let registry = harness.registry
        let task = Task.detached {
            registry.revoke(instance.id, reason: .explicitRevoke) {
                latch.enter()
                latch.waitForRelease()
                return true
            }
        }
        // Teardown runs outside the registry lock. Once it starts, the live
        // validity must already read revoking: new privileged use is
        // refused before teardown completes, not after.
        let deadline = Date().addingTimeInterval(10)
        while latch.entered == false, Date() < deadline {
            usleep(1_000)
        }
        #expect(latch.entered)
        #expect(harness.registry.validity(of: instance.id) == .revoking)
        #expect(harness.registry.context(for: instance.id)?.isUsable == false)
        let mid = harness.admission.submitLegacy(.success(harness.frame("touch mid")))
        #expect(mid.response == .rejected(.inactiveSession))
        #expect(harness.effects.count == 0)
        latch.open()
        #expect(await task.value == .revoked)
        #expect(harness.registry.validity(of: instance.id) == .inactive)
    }

    @Test func activateJournalFailureLeavesInstanceInactive() throws {
        let appends = Mutex(0)
        let store = AgentInstanceJournalStore(
            append: { _ in
                let count = appends.withLock { count -> Int in
                    count += 1
                    return count
                }
                let result: Result<Void, IsolationApplyError> =
                    count == 1 ? .success(()) : .failure(.sessionRecordFailed)
                return result
            },
            file: nil
        )
        let registry = AgentInstanceRegistry(journal: store)
        let definition = makeRegistryDefinition()
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let instance = makeRegistryInstance(
            definition: definition, workspace: workspace, runtime: runtime
        )
        #expect(registry.announce(instance))
        #expect(registry.validity(of: instance.id) == .inactive)
        let session = makeRegistrySession(runtime: runtime, workspace: workspace)
        let established = try #require(EstablishedRuntimeSession(
            session: session, instance: instance, establishedAt: Date()
        ))
        #expect(registry.activate(established) == nil)
        #expect(registry.validity(of: instance.id) == .inactive)
        #expect(registry.generation(of: instance.id) == 0)
        // The failed activation granted nothing and left the announced
        // record describable but unusable; ending it still works.
        #expect(registry.instance(for: instance.id) == instance)
        #expect(registry.revoke(instance.id, reason: .establishmentFailed) { true } == .revoked)
        #expect(registry.validity(of: instance.id) == .inactive)
    }

    @Test func suppressedExecuteKeepsPrincipalAttribution() throws {
        final class SessionBox: Sendable {
            private let box = Mutex<RuntimeAdmissionSession?>(nil)
            func store(_ session: RuntimeAdmissionSession) {
                box.withLock { $0 = session }
            }
            func finish() {
                box.withLock { $0 }?.finish()
            }
        }
        let holder = SessionBox()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let journalURL = root.appendingPathComponent("agent-instances.jsonl")
        let registry = AgentInstanceRegistry(journal: .file(journalURL))
        let effects = EffectCounter()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { subject, action in
                // The channel dies mid-normalize: the gate authorized on
                // its active snapshot, but the write-back lands finished
                // and the planned execute must be suppressed, not run.
                holder.finish()
                return allowTouchNormalize(subject: subject, action: action)
            },
            executor: .effect(effects.run),
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
        let admission = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: session, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        holder.store(admission)
        defer { admission.finish() }
        let definition = makeRegistryDefinition()
        let instance = makeRegistryInstance(
            definition: definition,
            workspace: session.workspaceSessionID,
            runtime: session.id
        )
        #expect(registry.announce(instance))
        #expect(admission.bindAgentInstance(instance.id, registry: registry))
        let established = try #require(EstablishedRuntimeSession(
            session: session, instance: instance, establishedAt: Date()
        ))
        _ = try #require(registry.activate(established))
        let frame = RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: "touch marker"))
        )
        let decision = admission.submitLegacy(.success(frame))
        #expect(decision.response == .rejected(.inactiveSession))
        #expect(effects.count == 0)
        #expect(decision.event.agentInstance == instance.id.rawValue.uuidString)
        #expect(decision.event.agentDefinition == "claude")
    }

    #if os(macOS)
    @Test func supervisorLaunchMintsActivatesAndFinishesInstance() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let journalURL = config.appendingPathComponent("agent-instances.jsonl")
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(config.appendingPathComponent("life.jsonl")),
            instanceJournal: .file(journalURL)
        ).get()
        defer { _ = supervisor.close() }
        let definition = makeRegistryDefinition()
        let running = try supervisor.launch(
            host: .opencode,
            command: try #require(IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 30"]
            )),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
            agentDefinition: definition
        ).get()
        #expect(supervisor.agentInstances.validity(ofRuntime: running.id) == .active)
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: running.id))
        #expect(instance.definitionID == definition.id)
        #expect(instance.workspaceSessionID == supervisor.id)
        #expect(instance.assurance == .launchObserved)
        #expect(instance.owner == OwnerPrincipal.current())
        #expect(AgentInstanceJournal.records(at: journalURL).map(\.kind) == [
            .attempted, .established,
        ])
        #expect(supervisor.cancel(running.id).isSuccess)
        #expect(supervisor.agentInstances.validity(ofRuntime: running.id) == .inactive)
        #expect(AgentInstanceJournal.records(at: journalURL).map(\.kind) == [
            .attempted, .established, .revoking, .finished,
        ])
        #expect(AgentInstanceJournal.records(at: journalURL).last?.detail == "revoked:cancelled")
    }

    @Test func supervisorRegisterFaultRetiresAnnouncedInstance() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let journalURL = config.appendingPathComponent("agent-instances.jsonl")
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(config.appendingPathComponent("life.jsonl")),
            instanceJournal: .file(journalURL)
        ).get()
        defer { _ = supervisor.close() }
        let definition = makeRegistryDefinition()
        let faulted = supervisor.launch(
            host: .opencode,
            command: try #require(IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 30"]
            )),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
            spawnFault: .register,
            agentDefinition: definition
        )
        guard case .failure(.apply(.lifetimeBoundaryFailed)) = faulted else {
            Issue.record("registration fault must retire the runtime, got \(faulted)")
            return
        }
        // The attempt was announced and bound, then retired before the
        // resume: one dead record, no live authority, no running runtime,
        // and a complete attempted → finished history.
        let announced = supervisor.agentInstances.instances(inWorkspace: supervisor.id)
        #expect(announced.count == 1)
        for record in announced {
            #expect(supervisor.agentInstances.validity(of: record.id) == .inactive)
        }
        #expect(supervisor.runtimeFacts().isEmpty)
        let journal = AgentInstanceJournal.records(at: journalURL)
        #expect(journal.map(\.kind) == [.attempted, .finished])
        #expect(journal.last?.detail == "revoked:spawnFailed")
    }

    @Test func supervisorLaunchWithoutDefinitionMintsNoInstance() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let journalURL = config.appendingPathComponent("agent-instances.jsonl")
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(config.appendingPathComponent("life.jsonl")),
            instanceJournal: .file(journalURL)
        ).get()
        defer { _ = supervisor.close() }
        let running = try supervisor.launch(
            host: .opencode,
            command: try #require(IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 30"]
            )),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(config.appendingPathComponent("runtime.jsonl"))
        ).get()
        #expect(supervisor.agentInstances.validity(ofRuntime: running.id) == .unknown)
        #expect(supervisor.agentInstances.instance(forRuntime: running.id) == nil)
        #expect(FileManager.default.fileExists(atPath: journalURL.path) == false)
        #expect(supervisor.cancel(running.id).isSuccess)
    }
    #endif
}
