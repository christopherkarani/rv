import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Ceremony redemption against a closure-backed host registry: consume-once,
/// exact-registration binding, single commit, bounded outcomes, and the
/// CLI/UI authority ratchets. No XPC, no UI, no LocalAuthentication.
@Suite("Operator redemption")
struct OperatorRedemptionTests {
    private static let digest = String(repeating: "a", count: 64)
    private static let envDigest = String(repeating: "b", count: 64)

    private final class AuditLog: Sendable {
        private let events = Mutex<[WorkspaceOperatorCeremonyAuditEvent]>([])
        func record(_ event: WorkspaceOperatorCeremonyAuditEvent) {
            events.withLock { $0.append(event) }
        }
        var all: [WorkspaceOperatorCeremonyAuditEvent] {
            events.withLock { $0 }
        }
    }

    private final class AuthorizerAuditLog: Sendable {
        private let events = Mutex<[WorkspaceOperatorAuthorizationAuditEvent]>([])
        func record(_ event: WorkspaceOperatorAuthorizationAuditEvent) {
            events.withLock { $0.append(event) }
        }
        var all: [WorkspaceOperatorAuthorizationAuditEvent] {
            events.withLock { $0 }
        }
        var consumedCount: Int {
            events.withLock { $0.filter { $0.kind == .permitConsumed }.count }
        }
    }

    private final class RedeemProbe: Sendable {
        private let calls = Mutex<[HostRedeemCommitDTO]>([])
        private let behavior: Mutex<
            (@Sendable (HostRedeemCommitDTO) async throws -> HostRedeemResponseDTO)?
        >
        init(
            behavior: (@Sendable (HostRedeemCommitDTO) async throws -> HostRedeemResponseDTO)?
                = nil
        ) {
            self.behavior = Mutex(behavior)
        }
        var count: Int { calls.withLock { $0.count } }
        var requests: [HostRedeemCommitDTO] { calls.withLock { $0 } }
        func handler() -> LiveWorkspaceHostRegistry.RedeemLaunch {
            { request in
                self.calls.withLock { $0.append(request) }
                guard let behavior = self.behavior.withLock({ $0 }) else {
                    throw LiveWorkspaceHostError.redeemRPCFailed
                }
                return try await behavior(request)
            }
        }
    }

    private struct Fixture {
        let registry: LiveWorkspaceHostRegistry
        let ceremonies: WorkspaceOperatorCeremonyService
        let workspace: WorkspaceSessionID
        let host: WorkspaceHostID
        let generation: WorkspaceHostGeneration
        let peer: AuthenticatedPeer
        let audit: AuditLog
        let authorizerAudit: AuthorizerAuditLog
        let redeemProbe: RedeemProbe
    }

    private func peer(
        role: TrustedRVComponentRole? = .workspaceHost,
        connectionID: UUID = UUID()
    ) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "redeem-fixture", teamIdentifier: nil,
            cdHash: Data([9]), executablePath: "/redeem-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: 501, auditToken: Data([9]), codeIdentity: code,
            componentRole: role), connectionID: connectionID)
    }

    private func requester() -> WorkspaceAuthorizationRequester {
        WorkspaceAuthorizationRequester(connectionID: UUID(), componentRole: .cli)
    }

    private func customIntent(workspace: WorkspaceSessionID) throws -> WorkspaceLaunchIntent {
        try WorkspaceLaunchIntent.makeCustom(
            executable: "/bin/echo",
            expectedContentDigestSHA256: Self.digest,
            workspaceSessionID: workspace,
            workingDirectory: "/tmp",
            arguments: [],
            io: .discard).get()
    }

    private func description(
        workspace: WorkspaceSessionID,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        requestID: UUID,
        intentHex: String,
        target: String = "custom"
    ) -> HostPreparedDescriptionDTO {
        HostPreparedDescriptionDTO(
            workspaceSessionID: workspace.rawValue,
            hostID: host.rawValue,
            generation: generation.rawValue,
            preparedID: UUID(),
            requestID: requestID,
            target: target,
            definitionID: target == "named" ? "test-agent" : nil,
            revisionDigest: target == "named" ? Self.digest : nil,
            executable: "/bin/echo",
            expectedDigest: target == "custom" ? Self.digest : nil,
            workingDirectory: "/tmp",
            arguments: [],
            io: .discard,
            environmentPolicy: "sealed",
            intentDigestHex: intentHex,
            environmentDigestHex: Self.envDigest,
            preparedAt: Date(),
            expiresAt: Date().addingTimeInterval(60))
    }

    private func makeFixture(
        redeemBehavior: (@Sendable (HostRedeemCommitDTO) async throws -> HostRedeemResponseDTO)? = nil,
        offerRedeem: Bool = true,
        isConnected: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Fixture {
        let registry = LiveWorkspaceHostRegistry()
        let audit = AuditLog()
        let authorizerAudit = AuthorizerAuditLog()
        let authorizer = WorkspaceOperatorAuthorizer(audit: { authorizerAudit.record($0) })
        let ceremonies = WorkspaceOperatorCeremonyService(
            hosts: registry, authorizer: authorizer, audit: { audit.record($0) })
        let workspace = WorkspaceSessionID()
        let host = WorkspaceHostID()
        let generation = WorkspaceHostGeneration()
        let hostPeer = peer()
        let intent = try customIntent(workspace: workspace)
        let probe = RedeemProbe(behavior: redeemBehavior)
        try await registry.register(peer: hostPeer, workspace: workspace, host: host,
            generation: generation, isConnected: isConnected,
            validate: { AgentPrincipalValidity(reference: $0, validity: .active) },
            prepare: { request in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host, generation: generation,
                    requestID: request.requestID,
                    intentHex: intent.canonicalDigest.sha256Hex))
            },
            redeem: offerRedeem ? probe.handler() : nil)
        return Fixture(registry: registry, ceremonies: ceremonies, workspace: workspace,
            host: host, generation: generation, peer: hostPeer, audit: audit,
            authorizerAudit: authorizerAudit, redeemProbe: probe)
    }

    private func customParams(_ fixture: Fixture) -> ProposeLaunchParams {
        ProposeLaunchParams(
            workspace: "/tmp/proj",
            hostID: fixture.host.rawValue,
            workspaceSessionID: fixture.workspace.rawValue,
            kind: "custom", executable: "/bin/echo", expectedDigest: Self.digest)
    }

    private func pendingOperation(_ fixture: Fixture) async throws -> UUID {
        try await fixture.ceremonies.propose(
            customParams(fixture), requester: requester(), clientRequestID: nil
        ).operationID
    }

    private func boundChallenge(
        _ fixture: Fixture, operationID: UUID, ui: AuthenticatedOperatorUIConnectionID
    ) async throws -> UIChallengeDTO {
        try await fixture.ceremonies.bindReview(operationID: operationID, uiConnection: ui).0
    }

    private func completeAuthenticated(
        _ fixture: Fixture, operationID: UUID, challengeID: UUID,
        ui: AuthenticatedOperatorUIConnectionID
    ) async throws -> WorkspaceOperationStatus {
        try await fixture.ceremonies.completeCeremony(
            UIOperatorCompletion(
                challengeID: challengeID, operationID: operationID,
                outcome: .authenticated),
            uiConnection: ui)
    }

    @Test func successfulRedemptionCommitsExactBindingsOnce() async throws {
        let runtimeID = UUID()
        let instanceID = UUID()
        let fixture = try await makeFixture(redeemBehavior: { _ in
            HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: runtimeID, agentInstanceID: instanceID)
        })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        let status = try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui)
        #expect(status == .consumed)
        #expect(fixture.authorizerAudit.consumedCount == 1)
        #expect(fixture.redeemProbe.count == 1)
        let commit = try #require(fixture.redeemProbe.requests.first)
        // The commit binds the exact reviewed operation — and carries no
        // permit bytes, credentials, or capabilities (unrepresentable here).
        #expect(commit.authorizationID == id)
        #expect(commit.workspaceSessionID == fixture.workspace.rawValue)
        #expect(commit.hostID == fixture.host.rawValue)
        #expect(commit.generation == fixture.generation.rawValue)
        #expect(commit.kind == "launchCustom")
        #expect(commit.definitionID == nil)
        #expect(commit.revisionDigest == nil)
        let polled = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: id))
        #expect(polled.status == .consumed)
        #expect(polled.launchResult == .launched)
        #expect(polled.runtimeSessionID == runtimeID)
        #expect(polled.agentInstanceID == instanceID)
        let kinds = fixture.audit.all.map(\.kind)
        #expect(kinds.contains(.redemptionRequested))
        #expect(kinds.contains(.redemptionCompleted))
        let completed = try #require(fixture.audit.all.first {
            $0.kind == .redemptionCompleted
        })
        #expect(completed.operationID == id)
        #expect(completed.runtimeSessionID == runtimeID)
        #expect(completed.agentInstanceID == instanceID)
        #expect(completed.intentDigestHex == commit.intentDigestHex)
        #expect(completed.preparedID == commit.preparedID)
    }

    @Test func hostRefusalRecordsTerminalFailure() async throws {
        let fixture = try await makeFixture(redeemBehavior: { _ in
            HostRedeemResponseDTO(accepted: false, error: "unknown")
        })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        #expect(try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui) == .consumed)
        #expect(fixture.authorizerAudit.consumedCount == 1)
        #expect(fixture.redeemProbe.count == 1)
        for _ in 0..<3 {
            let polled = await fixture.ceremonies.proposalStatus(
                ProposalStatusParams(operationID: id))
            #expect(polled.status == .consumed)
            #expect(polled.launchResult == .failed)
            #expect(polled.runtimeSessionID == nil)
        }
        // Polling never re-commits.
        #expect(fixture.redeemProbe.count == 1)
        #expect(fixture.audit.all.map(\.kind).contains(.redemptionFailed))
    }

    @Test func acceptedWithoutLaunchRecordsTerminalFailure() async throws {
        let fixture = try await makeFixture(redeemBehavior: { _ in
            HostRedeemResponseDTO(accepted: true, error: "launchFailed")
        })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        #expect(try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui) == .consumed)
        let polled = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: id))
        #expect(polled.launchResult == .failed)
        #expect(fixture.redeemProbe.count == 1)
    }

    @Test func transportFailureRecordsUnknownWithoutRetry() async throws {
        let fixture = try await makeFixture(redeemBehavior: { _ in
            throw LiveWorkspaceHostError.redeemRPCFailed
        })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        #expect(try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui) == .consumed)
        #expect(fixture.authorizerAudit.consumedCount == 1)
        #expect(fixture.redeemProbe.count == 1)
        let polled = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: id))
        #expect(polled.launchResult == .unknown)
        // A later host loss cannot revive or duplicate the spent permit.
        await fixture.ceremonies.hostConnectionLost(
            connectionID: fixture.peer.connectionID)
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == .consumed)
        #expect(fixture.redeemProbe.count == 1)
    }

    @Test func missingRedeemEntryPointRecordsUnknown() async throws {
        let fixture = try await makeFixture(offerRedeem: false)
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        #expect(try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui) == .consumed)
        let polled = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: id))
        #expect(polled.launchResult == .unknown)
    }

    @Test func staleChannelBurnsPermitWithoutConsume() async throws {
        let connected = Mutex(true)
        let fixture = try await makeFixture(
            redeemBehavior: { _ in
                HostRedeemResponseDTO(
                    accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())
            },
            isConnected: { connected.withLock { $0 } })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        // The channel dies after bind but the disconnect event has not
        // reached the ceremony: the live binding is gone while Step 3 still
        // holds the challenge. Redemption must burn, never consume.
        connected.withLock { $0 = false }
        let status = try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui)
        #expect(status == .invalidated)
        #expect(fixture.authorizerAudit.consumedCount == 0)
        #expect(fixture.redeemProbe.count == 0)
        let polled = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: id))
        #expect(polled.launchResult == .failed)
    }

    @Test func replacedRegistrationCannotRedeemOldAuthority() async throws {
        let fixture = try await makeFixture(redeemBehavior: { _ in
            HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())
        })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        // Same host ID, new generation, new channel — registered before the
        // disconnect event reaches the ceremony (the race window). The old
        // authority must not transfer to the new incarnation.
        let oldConnection = fixture.peer.connectionID
        await fixture.registry.disconnect(connectionID: oldConnection)
        let freshPeer = peer(connectionID: UUID())
        try await fixture.registry.register(peer: freshPeer,
            workspace: fixture.workspace, host: fixture.host,
            generation: WorkspaceHostGeneration(),
            validate: { AgentPrincipalValidity(reference: $0, validity: .active) },
            prepare: { _ in HostPrepareResponseDTO(description: nil, error: "refused") },
            redeem: fixture.redeemProbe.handler())
        let status = try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui)
        #expect(status == .invalidated)
        #expect(fixture.authorizerAudit.consumedCount == 0)
        #expect(fixture.redeemProbe.count == 0)
    }

    @Test func disconnectDuringCommitRecordsUnknown() async throws {
        // The host answers success but the channel dies mid-RPC: the
        // registry's epoch check fails the call after the fact. The permit
        // stays consumed and the outcome is unknown — never retried.
        let registryBox = Mutex<LiveWorkspaceHostRegistry?>(nil)
        let connectionBox = Mutex<UUID?>(nil)
        let fixture = try await makeFixture(redeemBehavior: { _ in
            guard let registry = registryBox.withLock({ $0 }),
                let connection = connectionBox.withLock({ $0 })
            else {
                throw LiveWorkspaceHostError.redeemRPCFailed
            }
            await registry.disconnect(connectionID: connection)
            return HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())
        })
        registryBox.withLock { $0 = fixture.registry }
        connectionBox.withLock { $0 = fixture.peer.connectionID }
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        #expect(try await completeAuthenticated(
            fixture, operationID: id, challengeID: challenge.challengeID, ui: ui) == .consumed)
        #expect(fixture.authorizerAudit.consumedCount == 1)
        #expect(fixture.redeemProbe.count == 1)
        let polled = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: id))
        #expect(polled.launchResult == .unknown)
        #expect(polled.runtimeSessionID == nil)
    }

    @Test func concurrentCompletionRedeemsExactlyOnce() async throws {
        let fixture = try await makeFixture(redeemBehavior: { _ in
            HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())
        })
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
        let completion = UIOperatorCompletion(
            challengeID: challenge.challengeID, operationID: id,
            outcome: .authenticated)
        async let first: WorkspaceOperationStatus? = try? await fixture.ceremonies.completeCeremony(
            completion, uiConnection: ui)
        async let second: WorkspaceOperationStatus? = try? await fixture.ceremonies.completeCeremony(
            completion, uiConnection: ui)
        let outcomes = await [first, second].compactMap { $0 }
        // Exactly one winner; the loser throws before any redemption.
        #expect(outcomes.count == 1)
        #expect(outcomes.first == .consumed)
        #expect(fixture.authorizerAudit.consumedCount == 1)
        #expect(fixture.redeemProbe.count == 1)
    }

    @Test func namedCommitCarriesSupportingDefinitionBinding() async throws {
        let seenBox = Mutex<HostRedeemCommitDTO?>(nil)
        let registry = LiveWorkspaceHostRegistry()
        let ceremonies = WorkspaceOperatorCeremonyService(hosts: registry)
        let workspace = WorkspaceSessionID()
        let host = WorkspaceHostID()
        let generation = WorkspaceHostGeneration()
        let hostPeer = peer()
        let intent = try customIntent(workspace: workspace)
        try await registry.register(peer: hostPeer, workspace: workspace, host: host,
            generation: generation,
            validate: { AgentPrincipalValidity(reference: $0, validity: .active) },
            prepare: { request in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host, generation: generation,
                    requestID: request.requestID,
                    intentHex: intent.canonicalDigest.sha256Hex, target: "named"))
            },
            redeem: { request in
                seenBox.withLock { $0 = request }
                return HostRedeemResponseDTO(
                    accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())
            })
        let reply = try await ceremonies.propose(
            ProposeLaunchParams(
                workspace: "/tmp/proj", hostID: host.rawValue,
                workspaceSessionID: workspace.rawValue,
                kind: "named", definitionID: "test-agent"),
            requester: requester(), clientRequestID: nil)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindReview(
            operationID: reply.operationID, uiConnection: ui)
        _ = try await ceremonies.completeCeremony(
            UIOperatorCompletion(
                challengeID: challenge.challengeID, operationID: reply.operationID,
                outcome: .authenticated),
            uiConnection: ui)
        let commit = try #require(seenBox.withLock { $0 })
        #expect(commit.kind == "launchAgent")
        #expect(commit.definitionID == "test-agent")
        #expect(commit.revisionDigest == Self.digest)
    }

    @Test func expiredChallengeCompletesNowhere() async throws {
        let now = Mutex(ContinuousClock.now)
        let authorizer = WorkspaceOperatorAuthorizer(
            monotonicNow: { now.withLock { $0 } })
        let registry = LiveWorkspaceHostRegistry()
        let ceremonies = WorkspaceOperatorCeremonyService(
            hosts: registry, authorizer: authorizer)
        let workspace = WorkspaceSessionID()
        let host = WorkspaceHostID()
        let generation = WorkspaceHostGeneration()
        let intent = try customIntent(workspace: workspace)
        try await registry.register(peer: peer(), workspace: workspace, host: host,
            generation: generation,
            validate: { AgentPrincipalValidity(reference: $0, validity: .active) },
            prepare: { request in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host, generation: generation,
                    requestID: request.requestID,
                    intentHex: intent.canonicalDigest.sha256Hex))
            },
            redeem: { _ in
                Issue.record("expired ceremony must never redeem")
                return HostRedeemResponseDTO(accepted: false, error: "unknown")
            })
        let reply = try await ceremonies.propose(
            ProposeLaunchParams(
                workspace: "/tmp/proj", hostID: host.rawValue,
                workspaceSessionID: workspace.rawValue,
                kind: "custom", executable: "/bin/echo",
                expectedDigest: Self.digest),
            requester: requester(), clientRequestID: nil)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindReview(
            operationID: reply.operationID, uiConnection: ui)
        // Past every deadline: completion fails, no permit, no redemption.
        now.withLock {
            $0 = $0.advanced(
                by: .seconds(WorkspaceOperatorAuthorizationLimits.operationLifetime + 1))
        }
        await #expect(throws: WorkspaceOperatorCeremonyError.self) {
            try await ceremonies.completeCeremony(
                UIOperatorCompletion(
                    challengeID: challenge.challengeID,
                    operationID: reply.operationID, outcome: .authenticated),
                uiConnection: ui)
        }
        #expect(await ceremonies.ceremonyStatus(operationID: reply.operationID) == .expired)
    }

    @Test func fullStoreRetainsEveryOutcome() async throws {
        let fixture = try await makeFixture(redeemBehavior: { _ in
            HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())
        })
        var ids: [UUID] = []
        for _ in 0..<WorkspaceOperatorAuthorizationLimits.maxOperations {
            let id = try await pendingOperation(fixture)
            let ui = AuthenticatedOperatorUIConnectionID()
            let challenge = try await boundChallenge(fixture, operationID: id, ui: ui)
            #expect(try await completeAuthenticated(
                fixture, operationID: id, challengeID: challenge.challengeID,
                ui: ui) == .consumed)
            ids.append(id)
        }
        #expect(fixture.redeemProbe.count == WorkspaceOperatorAuthorizationLimits.maxOperations)
        for id in ids {
            let polled = await fixture.ceremonies.proposalStatus(
                ProposalStatusParams(operationID: id))
            #expect(polled.status == .consumed)
            #expect(polled.launchResult == .launched)
        }
    }

    // MARK: - Authority ratchets (compile-time exhaustive)

    /// Compile-time classification ratchet: no IPC method consumes a
    /// permit or redeems. Exhaustive with no default, so adding a method
    /// breaks this switch until the new case is explicitly classified by a
    /// reviewer. This function is the ratchet, not the proof: runtime
    /// enforcement is the CLI-permits matrix below plus the reviewed
    /// `ServiceRuntime` routing (propose/status reach only the ceremony's
    /// non-consuming entries).
    private func touchesPermitConsumption(_ method: IPCMethod) -> Bool {
        switch method {
        case .evaluate, .hookEvaluate, .explain, .classify, .listPacks,
            .setPackEnabled, .doctorSnapshot, .pendingList, .pendingWatch,
            .pendingResolve, .rulePreview, .ruleSave,
            .proposeWorkspaceLaunch, .launchProposalStatus,
            // Step 8B.1: plants a memory grant (genuine-CLI attestation),
            // never consumes a permit.
            .attestTTYRedemption:
            return false
        }
    }

    @Test func cliReachesOnlyProposeAndStatus() async {
        let code = PeerCodeIdentity(identifier: "ratchet-fixture", teamIdentifier: nil,
            cdHash: Data([11]), executablePath: "/ratchet-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        func context(role: TrustedRVComponentRole?) -> AuthenticatedRequestContext {
            guard let role else { return .unauthenticated }
            let connection = UUID()
            return .captured(
                peer: AuthenticatedPeer(
                    evidence: PlatformPeerEvidence(processID: 1, effectiveUserID: 501,
                        auditToken: Data([11]), codeIdentity: code, componentRole: role),
                    connectionID: connection),
                connectionID: connection)
        }
        let propose = IPCMethod.proposeWorkspaceLaunch(ProposeLaunchParams(
            workspace: "/tmp/proj", kind: "custom", executable: "/bin/echo",
            expectedDigest: Self.digest))
        let status = IPCMethod.launchProposalStatus(
            ProposalStatusParams(operationID: UUID()))
        // No method consumes or redeems; the switch above enforces this for
        // every present and future case.
        #expect(touchesPermitConsumption(propose) == false)
        #expect(touchesPermitConsumption(status) == false)
        // CLI may propose and poll; no other role may, and CLI reaches
        // nothing else through the launch-proposal requirement.
        for role in [nil] + TrustedRVComponentRole.allCases.map({ $0 as TrustedRVComponentRole? }) {
            let expected = role == .cli
            #expect(
                ServiceMethodAuthorization.permits(propose, context: context(role: role))
                    == expected,
                "propose for \(String(describing: role))")
            #expect(
                ServiceMethodAuthorization.permits(status, context: context(role: role))
                    == expected,
                "status for \(String(describing: role))")
        }
        #expect(ServiceMethodAuthorization.requirement(for: propose) == .launchProposal)
        #expect(ServiceMethodAuthorization.requirement(for: status) == .launchProposal)
    }

    /// No UI request redeems or dispatches. The UI reports an authentication
    /// outcome; the service validates and redeems. Exhaustive with no
    /// default: adding a request breaks this switch until classified.
    private func grantsRedemptionAuthority(_ request: UIBridgeRequest) -> Bool {
        switch request {
        case .register, .list, .bind, .complete, .cancel, .status:
            return false
        }
    }

    @Test func redeemPendingResumesExactlyOnce() async throws {
        // Reply racing timeout: the first finish wins, the second is
        // dropped. A double resume would trap and fail the test.
        let won: HostRedeemResponseDTO = try await withCheckedThrowingContinuation { continuation in
            let pending = HostRedeemPending(continuation)
            pending.finish(.success(HostRedeemResponseDTO(
                accepted: true, runtimeSessionID: UUID(), agentInstanceID: UUID())))
            pending.finish(.failure(LiveWorkspaceHostError.redeemRPCFailed))
        }
        #expect(won.accepted == true)
        await #expect(throws: LiveWorkspaceHostError.redeemRPCFailed) {
            let _: HostRedeemResponseDTO = try await withCheckedThrowingContinuation { continuation in
                let pending = HostRedeemPending(continuation)
                pending.finish(.failure(LiveWorkspaceHostError.redeemRPCFailed))
                pending.finish(.success(HostRedeemResponseDTO(
                    accepted: false, error: "unknown")))
            }
        }
    }

    @Test func redeemBoundHasOneSourceOfTruth() {
        // The rvd-side enforcement aliases the RVIPC wire contract: raising
        // one without the other is a compile-time-visible edit, and this
        // pins the runtime equality.
        #expect(HostBridgeWire.maxRedeemBytes == HostRedeemWire.maxBodyBytes)
        #expect(HostBridgeWire.redeemKey == HostRedeemWire.redeemKey)
    }

    @Test func uiHoldsNoRedemptionAuthority() {
        let completion = UIOperatorCompletion(
            challengeID: UUID(), operationID: UUID(), outcome: .authenticated)
        let requests: [UIBridgeRequest] = [
            .register, .list, .bind(operationID: UUID()), .complete(completion),
            .cancel(operationID: UUID()), .status(operationID: UUID()),
        ]
        for request in requests {
            #expect(grantsRedemptionAuthority(request) == false)
        }
    }
}
