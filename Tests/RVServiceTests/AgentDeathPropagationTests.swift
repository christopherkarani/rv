import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Step 7: death propagates through the authoritative validity path with no
/// fakes in the loop — a real AgentInstanceRegistry, a real
/// WorkspacePrincipalAuthority as the host-validity source, the real
/// LiveWorkspaceHostRegistry, and the real Step 6 ceremony. Death is driven
/// by `finishRuntime`, the death handler's exact terminal effect (real
/// SIGKILL ⇒ handler invocation is proven in AgentInstanceDeathTests).
@Suite("Agent death propagation logic")
struct AgentDeathPropagationTests {
    private struct World: Sendable {
        let registry: AgentInstanceRegistry
        let authority: WorkspacePrincipalAuthority
        let hosts: LiveWorkspaceHostRegistry
        let ceremonies: ActionApprovalCeremonyService
        let instance: AgentInstance
        let session: RuntimeSession
        let reference: AgentPrincipalReference
        let host: AuthenticatedPeer
        let root: URL
    }

    private func peer(
        role: TrustedRVComponentRole? = .workspaceHost,
        connectionID: UUID = UUID(),
        uid: UInt32 = 501
    ) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "death-propagation-fixture", teamIdentifier: nil,
            cdHash: Data([9]), executablePath: "/death-propagation-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: uid, auditToken: Data([9]), codeIdentity: code,
            componentRole: role), connectionID: connectionID)
    }

    private func definition() -> AgentDefinition {
        AgentDefinition(
            id: AgentDefinitionID(rawValue: "death-agent"),
            displayName: "Death agent",
            blurb: "",
            executableRequirement: ExecutableRequirement(allowsUnsigned: true),
            hookHost: .claude,
            agentTag: "death-agent",
            resourceProfile: RuntimeResourceProfile(id: "death-agent", projects: []),
            credentialBindings: [],
            requiredAssurance: .launchObserved,
            authorityCeiling: AgentAuthority(scopes: ["fs.read"])
        )
    }

    private func makeInstance(
        definition: AgentDefinition, workspace: WorkspaceSessionID, runtime: RuntimeSessionID
    ) -> AgentInstance {
        AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(definition),
            workspaceSessionID: workspace,
            runtimeSessionID: runtime,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 4242),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: definition.authorityCeiling,
            delegableAuthority: definition.authorityCeiling,
            mintedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeSession(runtime: RuntimeSessionID, workspace: WorkspaceSessionID) -> RuntimeSession {
        let directory = WorkingDirectory(validating: FileManager.default.temporaryDirectory.path)!
        return RuntimeSession(
            id: runtime, workspaceSessionID: workspace, host: .opencode,
            workspace: directory, backend: .seatbelt, startedAt: Date(), child: nil)
    }

    private func activate(
        _ registry: AgentInstanceRegistry, instance: AgentInstance, session: RuntimeSession
    ) throws {
        let established = try #require(EstablishedRuntimeSession(
            session: session, instance: instance, establishedAt: Date()))
        _ = try #require(registry.activate(established))
    }

    /// Real registry + real authority + real host registry + real ceremony.
    /// The host-validity RPC answers from the live authority: no fake.
    private func world() async throws -> World {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-death-propagation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("instances.jsonl")))
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let agent = definition()
        let instance = makeInstance(definition: agent, workspace: workspace, runtime: runtime)
        guard registry.announce(instance) else {
            Issue.record("announce failed")
            throw AgentDeathPropagationError.setupFailed
        }
        let session = makeSession(runtime: runtime, workspace: workspace)
        try activate(registry, instance: instance, session: session)
        let authority = WorkspacePrincipalAuthority(
            registry: registry, workspace: workspace, host: WorkspaceHostID())
        let reference = try #require(authority.reference(forRuntime: runtime))
        let hosts = LiveWorkspaceHostRegistry()
        let host = peer()
        try await hosts.register(
            peer: host, workspace: workspace,
            host: reference.workspaceHostID, generation: reference.workspaceHostGeneration,
            validate: { authority.resolve($0) })
        let ceremonies = ActionApprovalCeremonyService(hosts: hosts)
        return World(
            registry: registry, authority: authority, hosts: hosts,
            ceremonies: ceremonies, instance: instance, session: session,
            reference: reference, host: host, root: root)
    }

    private func action(_ command: String = "echo death-probe") -> ProposedAction {
        .shell(ShellAction(
            fingerprint: ActionFingerprint(rawValue: "death:\(command)"),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: "/work")),
            supportingCommand: ShellCommand(rawValue: command)))
    }

    private func createDTO(
        reference: AgentPrincipalReference,
        action: ProposedAction? = nil
    ) -> HostActionApprovalCreateDTO {
        HostActionApprovalCreateDTO(
            reference: reference,
            action: action ?? self.action(),
            reason: "reviewAsk",
            policyContext: "runtime:/work",
            definitionID: AgentDefinitionID(rawValue: "death-agent"),
            definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "d", count: 64)))
    }

    private func cleanup(_ world: World) {
        try? FileManager.default.removeItem(at: world.root)
    }

    @Test func realDeathFailsServiceResolve() async throws {
        let world = try await world()
        defer { cleanup(world) }
        _ = try await world.hosts.resolve(world.reference, hostPeer: world.host)
        #expect(world.registry.finishRuntime(world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        await #expect(throws: LiveWorkspaceHostError.inactivePrincipal) {
            try await world.hosts.resolve(world.reference, hostPeer: world.host)
        }
    }

    @Test func pendingApprovalInvalidatesWhenPrincipalDies() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let created = try await world.ceremonies.requestApproval(
            createDTO(reference: world.reference), hostPeer: world.host)
        #expect(created.status == .pending)
        #expect(world.registry.finishRuntime(world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        // The host's next status poll for the dead principal invalidates.
        let status = await world.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(approvalID: created.approvalID, reference: world.reference),
            hostPeer: world.host)
        #expect(status.status == .unknown)
        #expect(await world.ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
        #expect(await world.ceremonies.listActionReviews().items.isEmpty)
    }

    @Test func issuedGrantUnconsumableAfterDeath() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let act = action()
        let created = try await world.ceremonies.requestApproval(
            createDTO(reference: world.reference, action: act), hostPeer: world.host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await world.ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        _ = try await world.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challenge.challengeID, approvalID: created.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        #expect(world.registry.finishRuntime(world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        let decision = await world.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: world.reference,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: world.host)
        #expect(decision.mayExecute == false)
        #expect(await world.ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
    }

    @Test func reviewBindingRefusedAfterDeath() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let created = try await world.ceremonies.requestApproval(
            createDTO(reference: world.reference), hostPeer: world.host)
        #expect(world.registry.finishRuntime(world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await world.ceremonies.bindActionReview(
                approvalID: created.approvalID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        #expect(await world.ceremonies.listActionReviews().items.isEmpty)
    }

    @Test func deathAtConsumeTrailingCheckBurnsGrant() async throws {
        // Deterministic consume × death race: a REAL registry revocation
        // commits exactly at the post-consume liveness check (call 6:
        // create, bind, complete-pre, complete-trailing, consume-pre,
        // consume-trailing). The grant is spent but nothing may execute.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-death-consume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("instances.jsonl")))
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let agent = definition()
        let instance = makeInstance(definition: agent, workspace: workspace, runtime: runtime)
        #expect(registry.announce(instance))
        try activate(registry, instance: instance, session: makeSession(runtime: runtime, workspace: workspace))
        let authority = WorkspacePrincipalAuthority(
            registry: registry, workspace: workspace, host: WorkspaceHostID())
        let reference = try #require(authority.reference(forRuntime: runtime))
        let hosts = LiveWorkspaceHostRegistry()
        let host = peer()
        let calls = Mutex(0)
        try await hosts.register(
            peer: host, workspace: workspace,
            host: reference.workspaceHostID, generation: reference.workspaceHostGeneration,
            validate: { ref in
                let n = calls.withLock { $0 += 1; return $0 }
                if n == 6 {
                    _ = registry.finishRuntime(runtime, reason: .runtimeEnded)
                }
                return authority.resolve(ref)
            })
        let ceremonies = ActionApprovalCeremonyService(hosts: hosts)
        let act = action()
        let created = try await ceremonies.requestApproval(
            createDTO(reference: reference, action: act), hostPeer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challenge.challengeID, approvalID: created.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        let decision = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: reference,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(decision.mayExecute == false)
        #expect(calls.withLock { $0 } == 6)
        // Step 6 linearization: the atomic gate spent the grant before the
        // trailing check failed, so the status honestly reports consumed —
        // but mayExecute false refused the resume, and a retry finds the
        // retention already dropped.
        #expect(await ceremonies.actionStatus(approvalID: created.approvalID) == .consumed)
        let retry = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: reference,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(retry.mayExecute == false)
    }

    @Test func deathAtCompleteTrailingCheckKillsGrant() async throws {
        // Deterministic complete × death race: a REAL registry revocation
        // commits exactly at the post-grant trailing check (call 4: create,
        // bind, complete-pre, complete-trailing). No grant survives.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-death-complete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("instances.jsonl")))
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        let agent = definition()
        let instance = makeInstance(definition: agent, workspace: workspace, runtime: runtime)
        #expect(registry.announce(instance))
        try activate(registry, instance: instance, session: makeSession(runtime: runtime, workspace: workspace))
        let authority = WorkspacePrincipalAuthority(
            registry: registry, workspace: workspace, host: WorkspaceHostID())
        let reference = try #require(authority.reference(forRuntime: runtime))
        let hosts = LiveWorkspaceHostRegistry()
        let host = peer()
        let calls = Mutex(0)
        try await hosts.register(
            peer: host, workspace: workspace,
            host: reference.workspaceHostID, generation: reference.workspaceHostGeneration,
            validate: { ref in
                let n = calls.withLock { $0 += 1; return $0 }
                if n == 4 {
                    _ = registry.finishRuntime(runtime, reason: .runtimeEnded)
                }
                return authority.resolve(ref)
            })
        let ceremonies = ActionApprovalCeremonyService(hosts: hosts)
        let act = action()
        let created = try await ceremonies.requestApproval(
            createDTO(reference: reference, action: act), hostPeer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: challenge.challengeID, approvalID: created.approvalID,
                    outcome: .authenticated),
                uiConnection: ui)
        }
        #expect(calls.withLock { $0 } == 4)
        #expect(await ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
    }

    @Test func replacementInstanceCannotUseOldApproval() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let act = action()
        let created = try await world.ceremonies.requestApproval(
            createDTO(reference: world.reference, action: act), hostPeer: world.host)
        #expect(world.registry.finishRuntime(world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        // A replacement execution gets a fresh live instance.
        let replacementRuntime = RuntimeSessionID()
        let replacement = makeInstance(
            definition: definition(), workspace: world.session.workspaceSessionID,
            runtime: replacementRuntime)
        #expect(world.registry.announce(replacement))
        try activate(
            world.registry, instance: replacement,
            session: makeSession(
                runtime: replacementRuntime, workspace: world.session.workspaceSessionID))
        let replacementReference = try #require(
            world.authority.reference(forRuntime: replacementRuntime))
        // The live replacement cannot see or consume the old approval.
        let foreign = await world.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: created.approvalID, reference: replacementReference),
            hostPeer: world.host)
        #expect(foreign.status == .unknown)
        let steal = await world.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: replacementReference,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: world.host)
        #expect(steal.mayExecute == false)
        // The dead principal's own next poll invalidates its approval.
        let status = await world.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(approvalID: created.approvalID, reference: world.reference),
            hostPeer: world.host)
        #expect(status.status == .unknown)
        #expect(await world.ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
        #expect(await world.ceremonies.listActionReviews().items.isEmpty)
    }

    @Test func unknownInstanceFailsClosed() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let unknown = AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(), runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: world.session.workspaceSessionID,
            workspaceHostID: world.reference.workspaceHostID,
            workspaceHostGeneration: world.reference.workspaceHostGeneration)
        #expect(world.registry.validity(of: unknown.agentInstanceID) == .unknown)
        #expect(world.authority.resolve(unknown) == nil)
        await #expect(throws: LiveWorkspaceHostError.inactivePrincipal) {
            try await world.hosts.resolve(unknown, hostPeer: world.host)
        }
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await world.ceremonies.requestApproval(
                createDTO(reference: unknown), hostPeer: world.host)
        }
    }
}

private enum AgentDeathPropagationError: Error {
    case setupFailed
}

#if os(macOS)
@preconcurrency import XPC

extension AgentDeathPropagationTests {
    /// Fix B: a received validity reply without the key means the live
    /// host affirmatively reports the reference unresolvable — nil, which
    /// the registry maps to inactivePrincipal. Timeouts (no reply at all)
    /// still surface as validityRPCFailed, never as death.
    @Test func keylessValidityReplyMeansUnresolvable() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let keyless = xpc_dictionary_create_empty()
        #expect(try XPCWorkspaceHostBridge.validityResult(from: keyless) == nil)
        let keyed = xpc_dictionary_create_empty()
        let expected = AgentPrincipalValidity(
            reference: world.reference, validity: .active)
        HostBridgeWire.set(
            try JSONEncoder().encode(expected),
            key: HostBridgeWire.validityKey, on: keyed)
        let decoded = try XPCWorkspaceHostBridge.validityResult(from: keyed)
        #expect(decoded?.reference == world.reference)
        #expect(decoded?.validity == .active)
        // Present-but-unusable is a wire anomaly, not affirmed death.
        let wrongType = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(wrongType, HostBridgeWire.validityKey, "not-data")
        #expect(throws: LiveWorkspaceHostError.validityRPCFailed) {
            try XPCWorkspaceHostBridge.validityResult(from: wrongType)
        }
        let oversize = xpc_dictionary_create_empty()
        HostBridgeWire.set(
            Data(repeating: 0, count: 1_048_577),
            key: HostBridgeWire.validityKey, on: oversize)
        #expect(throws: LiveWorkspaceHostError.validityRPCFailed) {
            try XPCWorkspaceHostBridge.validityResult(from: oversize)
        }
        let corrupt = xpc_dictionary_create_empty()
        HostBridgeWire.set(
            Data("not-a-validity".utf8), key: HostBridgeWire.validityKey, on: corrupt)
        #expect(throws: LiveWorkspaceHostError.validityRPCFailed) {
            try XPCWorkspaceHostBridge.validityResult(from: corrupt)
        }
    }

    /// Fix A: cancel builds a descriptive reference from authority-owned
    /// bytes whether the runtime is live or dead; missing records and
    /// foreign instances still throw.
    @Test func descriptiveCancelReferenceSurvivesDeath() async throws {
        let world = try await world()
        defer { cleanup(world) }
        func subject() -> RuntimeAdmissionSubject {
            RuntimeAdmissionSubject(
                session: world.session,
                policyWorkspace: WorkingDirectory(
                    validating: FileManager.default.temporaryDirectory.path)!,
                agent: AuthenticatedAgentContext(
                    instance: world.instance, validity: .active))
        }
        let live = try WorkspaceHostBridgeClient.descriptiveReference(
            authority: world.authority, subject: subject())
        #expect(live == world.reference)
        #expect(world.registry.finishRuntime(
            world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        let dead = try WorkspaceHostBridgeClient.descriptiveReference(
            authority: world.authority, subject: subject())
        #expect(dead == world.reference)
        // Missing record: nothing to name.
        let unknownRuntime = RuntimeSessionID()
        let unknown = RuntimeAdmissionSubject(
            session: makeSession(runtime: unknownRuntime, workspace: world.session.workspaceSessionID),
            policyWorkspace: WorkingDirectory(
                validating: FileManager.default.temporaryDirectory.path)!,
            agent: AuthenticatedAgentContext(
                instance: world.instance, validity: .active))
        #expect(throws: XPCEvaluateClientError.authenticationFailed) {
            try WorkspaceHostBridgeClient.descriptiveReference(
                authority: world.authority, subject: unknown)
        }
        // Foreign instance: the waiter cannot name another principal.
        let foreign = makeInstance(
            definition: definition(), workspace: world.session.workspaceSessionID,
            runtime: RuntimeSessionID())
        let mismatched = RuntimeAdmissionSubject(
            session: world.session,
            policyWorkspace: WorkingDirectory(
                validating: FileManager.default.temporaryDirectory.path)!,
            agent: AuthenticatedAgentContext(instance: foreign, validity: .active))
        #expect(throws: XPCEvaluateClientError.authenticationFailed) {
            try WorkspaceHostBridgeClient.descriptiveReference(
                authority: world.authority, subject: mismatched)
        }
        // Close() invalidation is enforced at resolve time; the descriptive
        // lookup still names the record so a shutdown-race cancel reports
        // it and the service proves death via its own pull.
        world.authority.close()
        let afterClose = try WorkspaceHostBridgeClient.descriptiveReference(
            authority: world.authority, subject: subject())
        #expect(afterClose == world.reference)
        #expect(world.authority.resolve(afterClose) == nil)
    }

    /// Fixes A+B composed: the teardown cancel transmitted after death
    /// carries a descriptive reference; the service proves death via its
    /// own validity pull and invalidates eagerly instead of lingering.
    @Test func cancelAfterDeathInvalidatesEagerly() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let created = try await world.ceremonies.requestApproval(
            createDTO(reference: world.reference), hostPeer: world.host)
        #expect(world.registry.finishRuntime(
            world.instance.runtimeSessionID, reason: .runtimeEnded) == .revoked)
        let subject = RuntimeAdmissionSubject(
            session: world.session,
            policyWorkspace: WorkingDirectory(
                validating: FileManager.default.temporaryDirectory.path)!,
            agent: AuthenticatedAgentContext(
                instance: world.instance, validity: .active))
        let reference = try WorkspaceHostBridgeClient.descriptiveReference(
            authority: world.authority, subject: subject)
        let status = await world.ceremonies.cancelApproval(
            HostActionApprovalCancelDTO(
                approvalID: created.approvalID, reference: reference),
            hostPeer: world.host)
        // The resolve fails (dead principal) so the reply is unknown — but
        // the failed resolve invalidated the record as its side effect.
        #expect(status.status == .unknown)
        #expect(await world.ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
        #expect(await world.ceremonies.listActionReviews().items.isEmpty)
    }

    /// Close-then-cancel composes the same way: close() invalidation is
    /// enforced at resolve time, the descriptive reference still names the
    /// record, and the service proves death via its own pull.
    @Test func cancelAfterCloseInvalidatesEagerly() async throws {
        let world = try await world()
        defer { cleanup(world) }
        let created = try await world.ceremonies.requestApproval(
            createDTO(reference: world.reference), hostPeer: world.host)
        world.authority.close()
        let subject = RuntimeAdmissionSubject(
            session: world.session,
            policyWorkspace: WorkingDirectory(
                validating: FileManager.default.temporaryDirectory.path)!,
            agent: AuthenticatedAgentContext(
                instance: world.instance, validity: .active))
        let reference = try WorkspaceHostBridgeClient.descriptiveReference(
            authority: world.authority, subject: subject)
        let status = await world.ceremonies.cancelApproval(
            HostActionApprovalCancelDTO(
                approvalID: created.approvalID, reference: reference),
            hostPeer: world.host)
        #expect(status.status == .unknown)
        #expect(await world.ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
        #expect(await world.ceremonies.listActionReviews().items.isEmpty)
    }
}
#endif
