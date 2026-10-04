import Foundation
import RVDomain
import RVIPC
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Synthetic evidence exercises registry logic only. These tests do not prove
/// platform role assignment, transport authenticity or a product journey.
@Suite("Live workspace host registry logic")
struct LiveWorkspaceHostRegistryTests {
    private func peer(
        role: TrustedRVComponentRole? = .workspaceHost,
        connectionID: UUID = UUID(),
        hash: Data = Data([1])
    ) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "logic-fixture", teamIdentifier: nil,
            cdHash: hash, executablePath: "/logic-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: 501, auditToken: Data([1]), codeIdentity: code,
            componentRole: role), connectionID: connectionID)
    }

    private func reference() -> AgentPrincipalReference {
        AgentPrincipalReference(agentInstanceID: AgentInstanceID(),
            runtimeSessionID: RuntimeSessionID(), workspaceSessionID: WorkspaceSessionID(),
            workspaceHostID: WorkspaceHostID(), workspaceHostGeneration: WorkspaceHostGeneration())
    }

    private func register(
        _ registry: LiveWorkspaceHostRegistry,
        _ ref: AgentPrincipalReference,
        _ peer: AuthenticatedPeer,
        validate: @escaping LiveWorkspaceHostRegistry.Validate = {
            AgentPrincipalValidity(reference: $0, validity: .active)
        }
    ) async throws {
        try await registry.register(peer: peer, workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: ref.workspaceHostGeneration, validate: validate)
    }

    @Test(arguments: ["cli", "service", "untrusted"])
    func wrongRoleCannotRegister(rawRole: String) async {
        let role = TrustedRVComponentRole(rawValue: rawRole)
        await #expect(throws: LiveWorkspaceHostError.wrongComponentRole) {
            try await register(LiveWorkspaceHostRegistry(), reference(), peer(role: role))
        }
    }

    @Test func validatesFreshEveryTimeAndRefusesRevocation() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let state = ValidityState()
        try await register(registry, ref, host) { ref in
            AgentPrincipalValidity(reference: ref, validity: await state.read())
        }
        let first = try await registry.resolve(ref, hostPeer: host)
        #expect(first.reference == ref)
        #expect(first.hostConnectionID == host.connectionID)
        _ = try await registry.resolve(ref, hostPeer: host)
        #expect(await state.calls == 2)
        await state.revoke()
        await #expect(throws: LiveWorkspaceHostError.inactivePrincipal) {
            try await registry.resolve(ref, hostPeer: host)
        }
        #expect(await state.calls == 3)
    }

    @Test func duplicateWorkspaceAndHostRefused() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        try await register(registry, ref, peer())
        await #expect(throws: LiveWorkspaceHostError.duplicateRegistration) {
            try await registry.register(peer: peer(), workspace: ref.workspaceSessionID,
                host: WorkspaceHostID(), generation: WorkspaceHostGeneration(), validate: { _ in nil })
        }
        await #expect(throws: LiveWorkspaceHostError.duplicateRegistration) {
            try await registry.register(peer: peer(), workspace: WorkspaceSessionID(),
                host: ref.workspaceHostID, generation: WorkspaceHostGeneration(), validate: { _ in nil })
        }
    }

    @Test func hostRestartRejectsOldGenerationAndReplays() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let oldPeer = peer()
        try await register(registry, ref, oldPeer)
        await registry.disconnect(connectionID: oldPeer.connectionID)
        await #expect(throws: LiveWorkspaceHostError.unknownHost) {
            try await registry.resolve(ref, hostPeer: oldPeer)
        }
        await #expect(throws: LiveWorkspaceHostError.retiredIncarnation) {
            try await register(registry, ref, peer())
        }
        let newRef = AgentPrincipalReference(agentInstanceID: ref.agentInstanceID,
            runtimeSessionID: ref.runtimeSessionID, workspaceSessionID: ref.workspaceSessionID,
            workspaceHostID: ref.workspaceHostID, workspaceHostGeneration: WorkspaceHostGeneration())
        await #expect(throws: LiveWorkspaceHostError.retiredIncarnation) {
            try await register(registry, newRef, oldPeer)
        }
        let newPeer = peer()
        try await register(registry, newRef, newPeer)
        await #expect(throws: LiveWorkspaceHostError.referenceMismatch) {
            try await registry.resolve(ref, hostPeer: newPeer)
        }
        _ = try await registry.resolve(newRef, hostPeer: newPeer)
    }

    @Test func disconnectBeforeRegistrationRefusesLateRegistration() async {
        let registry = LiveWorkspaceHostRegistry()
        let host = peer()
        await registry.disconnect(connectionID: host.connectionID)
        await #expect(throws: LiveWorkspaceHostError.retiredIncarnation) {
            try await register(registry, reference(), host)
        }
    }

    @Test func checksExactCodeIdentityAndConnection() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        try await register(registry, ref, host)
        for attacker in [peer(), peer(connectionID: host.connectionID, hash: Data([2])),
                         peer(role: .cli, connectionID: host.connectionID)] {
            await #expect(throws: LiveWorkspaceHostError.peerMismatch) {
                try await registry.resolve(ref, hostPeer: attacker)
            }
        }
    }

    @Test(arguments: [AgentInstanceValidity.revoking, .inactive, .unknown])
    func nonActiveValidityFailsClosed(validity: AgentInstanceValidity) async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        try await register(registry, ref, host) {
            AgentPrincipalValidity(reference: $0, validity: validity)
        }
        await #expect(throws: LiveWorkspaceHostError.inactivePrincipal) {
            try await registry.resolve(ref, hostPeer: host)
        }
    }

    @Test func missingAndFailedRPCFailClosed() async throws {
        for shouldThrow in [false, true] {
            let registry = LiveWorkspaceHostRegistry()
            let ref = reference()
            let host = peer()
            try await register(registry, ref, host) { _ in
                if shouldThrow { throw ProbeError.failed }
                return nil
            }
            await #expect(throws: shouldThrow ? LiveWorkspaceHostError.validityRPCFailed : .inactivePrincipal) {
                try await registry.resolve(ref, hostPeer: host)
            }
        }
    }

    @Test(arguments: 0..<5)
    func eachResponseIdentityFieldMustMatch(field: Int) async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let wrong = AgentPrincipalReference(
            agentInstanceID: field == 0 ? AgentInstanceID() : ref.agentInstanceID,
            runtimeSessionID: field == 1 ? RuntimeSessionID() : ref.runtimeSessionID,
            workspaceSessionID: field == 2 ? WorkspaceSessionID() : ref.workspaceSessionID,
            workspaceHostID: field == 3 ? WorkspaceHostID() : ref.workspaceHostID,
            workspaceHostGeneration: field == 4 ? WorkspaceHostGeneration() : ref.workspaceHostGeneration)
        try await register(registry, ref, host) { _ in
            AgentPrincipalValidity(reference: wrong, validity: .active)
        }
        await #expect(throws: LiveWorkspaceHostError.referenceMismatch) {
            try await registry.resolve(ref, hostPeer: host)
        }
    }

    @Test func disconnectWinsAgainstPendingValidityAndReplacement() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let gate = ValidationGate()
        try await register(registry, ref, host) { ref in
            await gate.suspend()
            return AgentPrincipalValidity(reference: ref, validity: .active)
        }
        let pending = Task { try await registry.resolve(ref, hostPeer: host) }
        await gate.waitUntilSuspended()
        await registry.disconnect(connectionID: host.connectionID)
        let newRef = AgentPrincipalReference(agentInstanceID: ref.agentInstanceID,
            runtimeSessionID: ref.runtimeSessionID, workspaceSessionID: ref.workspaceSessionID,
            workspaceHostID: ref.workspaceHostID, workspaceHostGeneration: WorkspaceHostGeneration())
        try await register(registry, newRef, peer())
        await gate.resume()
        await #expect(throws: LiveWorkspaceHostError.disconnected) { try await pending.value }
    }

    @Test func synchronousTransportDeathWinsBeforeActorDisconnect() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let live = Mutex(true)
        let gate = ValidationGate()
        try await registry.register(peer: host, workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: ref.workspaceHostGeneration,
            isConnected: { live.withLock { $0 } }) { ref in
                await gate.suspend()
                return AgentPrincipalValidity(reference: ref, validity: .active)
            }
        let pending = Task { try await registry.resolve(ref, hostPeer: host) }
        await gate.waitUntilSuspended()
        live.withLock { $0 = false }
        await gate.resume()
        await #expect(throws: LiveWorkspaceHostError.disconnected) { try await pending.value }
        await #expect(throws: LiveWorkspaceHostError.disconnected) {
            try await registry.resolve(ref, hostPeer: host)
        }
    }

    @Test func agentEvaluationCannotConsumeOrReuseOwnerGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-principal-grant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try #require(HomeDirectory(validating: root.path))
        let cwd = try #require(WorkingDirectory(validating: root.path))
        let store = AllowOnceStore(baseDirectory: root.appendingPathComponent("store"))
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: cwd, codeHash: "owner-grant", now: now
            ) == .planted
        )
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        try await register(registry, ref, host)
        let context = try await registry.resolve(ref, hostPeer: host)
        let runtime = ServiceRuntime(home: home, allowOnce: store, grants: grants, clock: { now })
        let reply = await runtime.evaluateAgent(EvaluateParams(request:
            .makeDayOne(command: ShellCommand(rawValue: "git reset --hard")), cwd: cwd),
            requestID: UUID(), context: context)
        if case .deny = reply.result.decision {} else { Issue.record("Agent must not use an owner grant") }
        #expect(await grants.hasGrant(matchingView: "git reset --hard", cwd: cwd, now: now))
    }

    @Test func serviceEvaluationReceivesVerifiedPrincipal() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        try await register(registry, ref, host)
        let context = try await registry.resolve(ref, hostPeer: host)
        let log = PrincipalProbeLog()
        let runtime = ServiceRuntime(log: log)
        let requestID = UUID()
        let command = ShellCommand(rawValue: "echo bridge")
        _ = await runtime.evaluateAgent(EvaluateParams(request: .makeDayOne(command: command)),
            requestID: requestID, context: context)
        let event = try #require(log.events.withLock { $0.last })
        #expect(event.method == "agentEvaluate")
        #expect(event.requestID == requestID)
        #expect(event.principal == ref)
    }

    @Test func incomingWorkspaceMismatchNeverCallsRPC() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let state = ValidityState()
        try await register(registry, ref, host) { ref in
            AgentPrincipalValidity(reference: ref, validity: await state.read())
        }
        let wrong = AgentPrincipalReference(agentInstanceID: ref.agentInstanceID,
            runtimeSessionID: ref.runtimeSessionID, workspaceSessionID: WorkspaceSessionID(),
            workspaceHostID: ref.workspaceHostID, workspaceHostGeneration: ref.workspaceHostGeneration)
        await #expect(throws: LiveWorkspaceHostError.referenceMismatch) {
            try await registry.resolve(wrong, hostPeer: host)
        }
        #expect(await state.calls == 0)
    }

    @Test func retiredConnectionsAreBoundedFIFO() async throws {
        let registry = LiveWorkspaceHostRegistry()
        var ids: [UUID] = []
        for _ in 0..<5_000 {
            let id = UUID()
            ids.append(id)
            await registry.disconnect(connectionID: id)
        }
        #expect(await registry.retiredConnectionCount == 4_096)
        // The oldest entries evicted: registering on an evicted channel is
        // treated as fresh (its session is long dead).
        try await registry.register(peer: peer(connectionID: ids[0]),
            workspace: WorkspaceSessionID(), host: WorkspaceHostID(),
            generation: WorkspaceHostGeneration(), validate: { _ in nil })
        // A retained recent entry still wins its race.
        await #expect(throws: LiveWorkspaceHostError.retiredIncarnation) {
            try await registry.register(peer: peer(connectionID: ids[4_999]),
                workspace: WorkspaceSessionID(), host: WorkspaceHostID(),
                generation: WorkspaceHostGeneration(), validate: { _ in nil })
        }
    }

    @Test func redeemRequiresValidatedChannel() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ref = reference()
        let first = peer()
        let firstCalls = Mutex(0)
        try await registry.register(peer: first, workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: ref.workspaceHostGeneration,
            validate: { _ in nil },
            redeem: { _ in
                firstCalls.withLock { $0 += 1 }
                return HostRedeemResponseDTO(accepted: false, error: "unknown")
            })
        let stale = try #require(await registry.liveBinding(host: ref.workspaceHostID))
        func commit() -> HostRedeemCommitDTO {
            HostRedeemCommitDTO(
                authorizationID: UUID(),
                workspaceSessionID: ref.workspaceSessionID.rawValue,
                hostID: ref.workspaceHostID.rawValue,
                generation: ref.workspaceHostGeneration.rawValue,
                preparedID: UUID(),
                intentDigestHex: String(repeating: "a", count: 64),
                kind: "launchCustom", definitionID: nil, revisionDigest: nil)
        }
        // The validated channel commits normally.
        _ = try await registry.redeemLaunch(
            host: ref.workspaceHostID, expectedConnection: stale.connectionID,
            request: commit())
        #expect(firstCalls.withLock { $0 } == 1)
        // A replacement incarnation lands. The old validated channel no
        // longer matches: the commit is not delivered to either host.
        await registry.disconnect(connectionID: first.connectionID)
        let secondCalls = Mutex(0)
        try await registry.register(peer: peer(), workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: WorkspaceHostGeneration(),
            validate: { _ in nil },
            redeem: { _ in
                secondCalls.withLock { $0 += 1 }
                return HostRedeemResponseDTO(accepted: false, error: "unknown")
            })
        await #expect(throws: LiveWorkspaceHostError.staleRegistration) {
            try await registry.redeemLaunch(
                host: ref.workspaceHostID, expectedConnection: stale.connectionID,
                request: commit())
        }
        #expect(firstCalls.withLock { $0 } == 1)
        #expect(secondCalls.withLock { $0 } == 0)
    }
}

private enum ProbeError: Error { case failed }

private actor ValidityState {
    var calls = 0
    var validity = AgentInstanceValidity.active
    func read() -> AgentInstanceValidity { calls += 1; return validity }
    func revoke() { validity = .inactive }
}

private actor ValidationGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { suspended?.resume(); suspended = nil }
}

private final class PrincipalProbeLog: ServiceLog, Sendable {
    let events = Mutex<[ServiceLogEvent]>([])
    func record(_ event: ServiceLogEvent) { events.withLock { $0.append(event) } }
}
