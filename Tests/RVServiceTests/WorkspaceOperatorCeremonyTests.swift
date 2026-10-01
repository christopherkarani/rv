import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Ceremony logic against a closure-backed host registry. No XPC, no UI, no
/// LocalAuthentication: the registry's `prepare` closure stands in for the
/// authenticated host bridge.
@Suite("Workspace operator ceremony")
struct WorkspaceOperatorCeremonyTests {
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

    private struct Fixture {
        let registry: LiveWorkspaceHostRegistry
        let ceremonies: WorkspaceOperatorCeremonyService
        let workspace: WorkspaceSessionID
        let host: WorkspaceHostID
        let generation: WorkspaceHostGeneration
        let peer: AuthenticatedPeer
        let audit: AuditLog
    }

    private func peer(
        role: TrustedRVComponentRole? = .workspaceHost,
        connectionID: UUID = UUID()
    ) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "ceremony-fixture", teamIdentifier: nil,
            cdHash: Data([7]), executablePath: "/ceremony-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: 501, auditToken: Data([7]), codeIdentity: code,
            componentRole: role), connectionID: connectionID)
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
        prepare makePrepare: (@Sendable (
            WorkspaceSessionID, WorkspaceHostID, WorkspaceHostGeneration
        ) -> LiveWorkspaceHostRegistry.PrepareLaunch)? = nil,
        isConnected: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Fixture {
        let registry = LiveWorkspaceHostRegistry()
        let audit = AuditLog()
        let ceremonies = WorkspaceOperatorCeremonyService(
            hosts: registry, audit: { audit.record($0) })
        let workspace = WorkspaceSessionID()
        let host = WorkspaceHostID()
        let generation = WorkspaceHostGeneration()
        let hostPeer = peer()
        let intent = try customIntent(workspace: workspace)
        let defaultPrepare: LiveWorkspaceHostRegistry.PrepareLaunch = { request in
            HostPrepareResponseDTO(description: self.description(
                workspace: workspace, host: host, generation: generation,
                requestID: request.requestID, intentHex: intent.canonicalDigest.sha256Hex))
        }
        try await registry.register(peer: hostPeer, workspace: workspace, host: host,
            generation: generation, isConnected: isConnected,
            validate: { AgentPrincipalValidity(reference: $0, validity: .active) },
            prepare: makePrepare?(workspace, host, generation) ?? defaultPrepare)
        return Fixture(registry: registry, ceremonies: ceremonies, workspace: workspace,
            host: host, generation: generation, peer: hostPeer, audit: audit)
    }

    private func customParams(_ fixture: Fixture) -> ProposeLaunchParams {
        ProposeLaunchParams(
            workspace: "/tmp/proj",
            hostID: fixture.host.rawValue,
            workspaceSessionID: fixture.workspace.rawValue,
            kind: "custom",
            executable: "/bin/echo",
            expectedDigest: Self.digest)
    }

    private func requester() -> WorkspaceAuthorizationRequester {
        WorkspaceAuthorizationRequester(connectionID: UUID(), componentRole: .cli)
    }

    // MARK: - Proposal ingestion

    @Test func invalidShapeRejectedBeforeHostContact() async throws {
        let fixture = try await makeFixture()
        let bad = ProposeLaunchParams(
            workspace: "/tmp/proj",
            hostID: fixture.host.rawValue,
            workspaceSessionID: fixture.workspace.rawValue,
            kind: "bogus",
            executable: "/bin/echo",
            expectedDigest: Self.digest)
        await #expect(throws: WorkspaceOperatorCeremonyError.invalidProposal) {
            try await fixture.ceremonies.propose(bad, requester: requester(), clientRequestID: nil)
        }
        #expect(fixture.audit.all.map(\.kind) == [.proposalReceived])
    }

    @Test func unknownHostWithoutRegistration() async throws {
        let ceremonies = WorkspaceOperatorCeremonyService()
        let params = ProposeLaunchParams(
            workspace: "/tmp/proj", hostID: UUID(), workspaceSessionID: UUID(),
            kind: "custom", executable: "/bin/echo", expectedDigest: Self.digest)
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownHost) {
            try await ceremonies.propose(params, requester: requester(), clientRequestID: nil)
        }
    }

    @Test func mismatchedSessionHintRejected() async throws {
        let fixture = try await makeFixture()
        var params = customParams(fixture)
        params = ProposeLaunchParams(
            workspace: params.workspace, hostID: params.hostID,
            workspaceSessionID: UUID(), kind: params.kind,
            executable: params.executable, expectedDigest: params.expectedDigest)
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownHost) {
            try await fixture.ceremonies.propose(params, requester: requester(), clientRequestID: nil)
        }
    }

    @Test func hostRefusalSurfacesPrepareFailed() async throws {
        let fixture = try await makeFixture(prepare: { _, _, _ in
            { _ in HostPrepareResponseDTO(description: nil, error: "unknownDefinition") }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.prepareFailed("unknownDefinition")) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func missingPrepareEntryPointSurfacesUnavailable() async throws {
        let registry = LiveWorkspaceHostRegistry()
        let ceremonies = WorkspaceOperatorCeremonyService(hosts: registry)
        let workspace = WorkspaceSessionID()
        let host = WorkspaceHostID()
        try await registry.register(peer: peer(), workspace: workspace, host: host,
            generation: WorkspaceHostGeneration(),
            validate: { AgentPrincipalValidity(reference: $0, validity: .active) },
            prepare: nil)
        let params = ProposeLaunchParams(
            workspace: "/tmp/proj", hostID: host.rawValue,
            workspaceSessionID: workspace.rawValue,
            kind: "custom", executable: "/bin/echo", expectedDigest: Self.digest)
        await #expect(throws: WorkspaceOperatorCeremonyError.prepareFailed("unavailable")) {
            try await ceremonies.propose(params, requester: requester(), clientRequestID: nil)
        }
    }

    @Test func customHappyPathCreatesPendingReview() async throws {
        let fixture = try await makeFixture()
        let reply = try await fixture.ceremonies.propose(
            customParams(fixture), requester: requester(), clientRequestID: nil)
        #expect(reply.status == "pendingReview")
        let status = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: reply.operationID))
        #expect(status.status == "pendingReview")
        let items = await fixture.ceremonies.listReviewItems()
        #expect(items.items.count == 1)
        #expect(items.items[0].operationID == reply.operationID)
        #expect(items.items[0].executable == "/bin/echo")
        #expect(fixture.audit.all.map(\.kind) == [
            .proposalReceived, .hostPrepareRequested, .pendingCreated,
        ])
    }

    @Test func namedHappyPathCreatesPendingReview() async throws {
        let fixture = try await makeFixture(prepare: { workspace, host, generation in
            { request in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host,
                    generation: generation, requestID: request.requestID,
                    intentHex: Self.digest, target: "named"))
            }
        })
        let params = ProposeLaunchParams(
            workspace: "/tmp/proj", hostID: fixture.host.rawValue,
            workspaceSessionID: fixture.workspace.rawValue,
            kind: "named", definitionID: "test-agent")
        let reply = try await fixture.ceremonies.propose(
            params, requester: requester(), clientRequestID: nil)
        #expect(reply.status == "pendingReview")
    }

    @Test func generationSwapFailsClosed() async throws {
        let fixture = try await makeFixture(prepare: { workspace, host, _ in
            { request in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host,
                    generation: WorkspaceHostGeneration(), requestID: request.requestID,
                    intentHex: Self.digest))
            }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.descriptionMismatch) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func requestIDEchoMismatchFailsClosed() async throws {
        let fixture = try await makeFixture(prepare: { workspace, host, generation in
            { _ in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host,
                    generation: generation, requestID: UUID(),
                    intentHex: Self.digest))
            }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.descriptionMismatch) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func tamperedIntentDigestFailsClosed() async throws {
        let fixture = try await makeFixture(prepare: { workspace, host, generation in
            { request in
                HostPrepareResponseDTO(description: self.description(
                    workspace: workspace, host: host,
                    generation: generation, requestID: request.requestID,
                    intentHex: String(repeating: "c", count: 64)))
            }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.descriptionMismatch) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func midFlightDisconnectFailsClosed() async throws {
        let connected = Mutex(true)
        let fixture = try await makeFixture(
            prepare: { _, _, _ in
                { _ in
                    connected.withLock { $0 = false }
                    return HostPrepareResponseDTO(description: nil, error: "gone")
                }
            },
            isConnected: { connected.withLock { $0 } })
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownHost) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func unknownOperationStatusIsUnknown() async throws {
        let fixture = try await makeFixture()
        let status = await fixture.ceremonies.proposalStatus(
            ProposalStatusParams(operationID: UUID()))
        #expect(status.status == "unknown")
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: UUID()) == "unknown")
    }

    // MARK: - Review, bind, complete

    private func pendingOperation(_ fixture: Fixture) async throws -> UUID {
        try await fixture.ceremonies.propose(
            customParams(fixture), requester: requester(), clientRequestID: nil
        ).operationID
    }

    @Test func bindIssuesChallengeAndListsAwaiting() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, item) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        #expect(challenge.operationID == id)
        #expect(item.operationID == id)
        #expect(item.status == "awaitingAuthentication")
        let items = await fixture.ceremonies.listReviewItems()
        #expect(items.items.count == 1)
        #expect(items.items[0].status == "awaitingAuthentication")
    }

    @Test func rebindFromOwnerResumesSameChallenge() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (first, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        let (second, item) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        #expect(second.challengeID == first.challengeID)
        #expect(item.operationID == id)
        // The resumed challenge still completes.
        let status = try await fixture.ceremonies.completeCeremony(
            UIOperatorCompletion(
                challengeID: second.challengeID, operationID: id,
                outcome: .authenticated),
            uiConnection: ui)
        #expect(status == "authorized")
    }

    @Test func rebindFromForeignConnectionRefused() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        _ = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: AuthenticatedOperatorUIConnectionID())
        await #expect(throws: WorkspaceOperatorCeremonyError.notReviewable) {
            try await fixture.ceremonies.bindReview(
                operationID: id, uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func bindUnknownOperationRejected() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.bindReview(
                operationID: UUID(), uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func authenticatedCompletionAuthorizes() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        let status = try await fixture.ceremonies.completeCeremony(
            UIOperatorCompletion(
                challengeID: challenge.challengeID, operationID: id, outcome: .authenticated),
            uiConnection: ui)
        #expect(status == "authorized")
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == "authorized")
        #expect(await fixture.ceremonies.listReviewItems().items.isEmpty)
    }

    @Test func cancelledAuthenticationFails() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        let status = try await fixture.ceremonies.completeCeremony(
            UIOperatorCompletion(
                challengeID: challenge.challengeID, operationID: id, outcome: .cancelled),
            uiConnection: ui)
        #expect(status == "failed")
    }

    @Test func completionNamesExactRetainedChallenge() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        _ = try await fixture.ceremonies.bindReview(operationID: id, uiConnection: ui)
        // Forged challenge ID, however well-formed, is not the retained one.
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.completeCeremony(
                UIOperatorCompletion(
                    challengeID: UUID(), operationID: id, outcome: .authenticated),
                uiConnection: ui)
        }
        // Cross-operation challenge confusion is rejected the same way.
        let other = try await pendingOperation(fixture)
        let (otherChallenge, _) = try await fixture.ceremonies.bindReview(
            operationID: other, uiConnection: ui)
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.completeCeremony(
                UIOperatorCompletion(
                    challengeID: otherChallenge.challengeID, operationID: id,
                    outcome: .authenticated),
                uiConnection: ui)
        }
    }

    @Test func completionFromForeignConnectionRefused() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let owner = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: owner)
        await #expect(throws: WorkspaceOperatorCeremonyError.notReviewable) {
            try await fixture.ceremonies.completeCeremony(
                UIOperatorCompletion(
                    challengeID: challenge.challengeID, operationID: id,
                    outcome: .authenticated),
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func completionWithoutBindRejected() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.completeCeremony(
                UIOperatorCompletion(
                    challengeID: UUID(), operationID: id, outcome: .authenticated),
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func replayAfterCompletionRejected() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        let completion = UIOperatorCompletion(
            challengeID: challenge.challengeID, operationID: id, outcome: .authenticated)
        _ = try await fixture.ceremonies.completeCeremony(completion, uiConnection: ui)
        do {
            try await fixture.ceremonies.completeCeremony(completion, uiConnection: ui)
            Issue.record("replay must throw")
        } catch {}
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == "authorized")
    }

    // MARK: - Cancel

    @Test func pendingCancelByAnyConnection() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let status = try await fixture.ceremonies.cancelReview(
            operationID: id, uiConnection: AuthenticatedOperatorUIConnectionID())
        #expect(status == "cancelled")
        #expect(await fixture.ceremonies.listReviewItems().items.isEmpty)
    }

    @Test func boundCancelRequiresOwningConnection() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let owner = AuthenticatedOperatorUIConnectionID()
        _ = try await fixture.ceremonies.bindReview(operationID: id, uiConnection: owner)
        await #expect(throws: WorkspaceOperatorCeremonyError.notReviewable) {
            try await fixture.ceremonies.cancelReview(
                operationID: id, uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        let status = try await fixture.ceremonies.cancelReview(
            operationID: id, uiConnection: owner)
        #expect(status == "cancelled")
    }

    @Test func cancelUnknownRejected() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.cancelReview(
                operationID: UUID(), uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    // MARK: - Disconnect

    @Test func uiDisconnectInvalidatesBoundCeremony() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        await fixture.ceremonies.uiConnectionLost(ui)
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == "invalidated")
        do {
            try await fixture.ceremonies.completeCeremony(
                UIOperatorCompletion(
                    challengeID: challenge.challengeID, operationID: id,
                    outcome: .authenticated),
                uiConnection: ui)
            Issue.record("completion after invalidation must throw")
        } catch {}
        #expect(await fixture.ceremonies.listReviewItems().items.isEmpty)
    }

    @Test func hostDisconnectRemovesReviewability() async throws {
        let fixture = try await makeFixture()
        _ = try await pendingOperation(fixture)
        await fixture.registry.disconnect(connectionID: fixture.peer.connectionID)
        await fixture.ceremonies.hostConnectionLost(connectionID: fixture.peer.connectionID)
        #expect(await fixture.ceremonies.listReviewItems().items.isEmpty)
    }

    @Test func strayDisconnectsAreSafeNoOps() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        await fixture.ceremonies.uiConnectionLost(AuthenticatedOperatorUIConnectionID())
        await fixture.ceremonies.hostConnectionLost(connectionID: UUID())
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == "pendingReview")
        #expect(await fixture.ceremonies.listReviewItems().items.count == 1)
    }

    // MARK: - Review findings

    @Test func disconnectVsCompleteRaceAlwaysSettlesInvalidated() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        let completion = UIOperatorCompletion(
            challengeID: challenge.challengeID, operationID: id, outcome: .authenticated)
        async let completed: String? = try? await fixture.ceremonies.completeCeremony(
            completion, uiConnection: ui)
        await fixture.ceremonies.uiConnectionLost(ui)
        let observed = await completed
        // Either order: the ceremony is dead and unusable. If complete
        // landed first, its permit died with the ceremony per Step 3.
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == "invalidated")
        #expect(await fixture.ceremonies.listReviewItems().items.isEmpty)
        if let observed {
            #expect(observed == "authorized")
        }
        do {
            try await fixture.ceremonies.completeCeremony(completion, uiConnection: ui)
            Issue.record("post-race completion must throw")
        } catch {}
    }

    @Test func completeThenDisconnectInvalidatesIssuedPermit() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        let completion = UIOperatorCompletion(
            challengeID: challenge.challengeID, operationID: id, outcome: .authenticated)
        #expect(
            try await fixture.ceremonies.completeCeremony(completion, uiConnection: ui)
                == "authorized")
        await fixture.ceremonies.uiConnectionLost(ui)
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: id) == "invalidated")
        #expect(await fixture.ceremonies.listReviewItems().items.isEmpty)
    }

    @Test func storeCapRefusesFurtherProposals() async throws {
        let fixture = try await makeFixture()
        for _ in 0..<WorkspaceOperatorAuthorizationLimits.maxOperations {
            _ = try await pendingOperation(fixture)
        }
        await #expect(throws: WorkspaceOperatorCeremonyError.storeFull) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func restartInvalidatesPriorCeremonies() async throws {
        let fixture = try await makeFixture()
        let id = try await pendingOperation(fixture)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: id, uiConnection: ui)
        // A restarted service holds neither retention nor the Step 3 epoch:
        // the old challenge is unresolvable, not merely unbound.
        let restarted = WorkspaceOperatorCeremonyService()
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await restarted.completeCeremony(
                UIOperatorCompletion(
                    challengeID: challenge.challengeID, operationID: id,
                    outcome: .authenticated),
                uiConnection: ui)
        }
        #expect(await restarted.ceremonyStatus(operationID: id) == "unknown")
    }

    @Test func fieldSwapAgainstValidDigestFailsClosed() async throws {
        let fixture = try await makeFixture(prepare: { workspace, host, generation in
            { request in
                var tampered = self.description(
                    workspace: workspace, host: host,
                    generation: generation, requestID: request.requestID,
                    intentHex: (try? self.customIntent(workspace: workspace))?
                        .canonicalDigest.sha256Hex ?? Self.digest)
                tampered = HostPreparedDescriptionDTO(
                    workspaceSessionID: tampered.workspaceSessionID,
                    hostID: tampered.hostID, generation: tampered.generation,
                    preparedID: tampered.preparedID, requestID: tampered.requestID,
                    target: tampered.target, definitionID: tampered.definitionID,
                    revisionDigest: tampered.revisionDigest,
                    executable: "/bin/evil",
                    expectedDigest: tampered.expectedDigest,
                    workingDirectory: tampered.workingDirectory,
                    arguments: tampered.arguments, io: tampered.io,
                    environmentPolicy: tampered.environmentPolicy,
                    intentDigestHex: tampered.intentDigestHex,
                    environmentDigestHex: tampered.environmentDigestHex,
                    preparedAt: tampered.preparedAt, expiresAt: tampered.expiresAt)
                return HostPrepareResponseDTO(description: tampered)
            }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.descriptionMismatch) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func relativeWorkingDirectoryFailsClosed() async throws {
        let fixture = try await makeFixture(prepare: { workspace, host, generation in
            { request in
                let base = self.description(
                    workspace: workspace, host: host,
                    generation: generation, requestID: request.requestID,
                    intentHex: (try? self.customIntent(workspace: workspace))?
                        .canonicalDigest.sha256Hex ?? Self.digest)
                let tampered = HostPreparedDescriptionDTO(
                    workspaceSessionID: base.workspaceSessionID,
                    hostID: base.hostID, generation: base.generation,
                    preparedID: base.preparedID, requestID: base.requestID,
                    target: base.target, definitionID: base.definitionID,
                    revisionDigest: base.revisionDigest,
                    executable: base.executable,
                    expectedDigest: base.expectedDigest,
                    workingDirectory: "relative/path",
                    arguments: base.arguments, io: base.io,
                    environmentPolicy: base.environmentPolicy,
                    intentDigestHex: base.intentDigestHex,
                    environmentDigestHex: base.environmentDigestHex,
                    preparedAt: base.preparedAt, expiresAt: base.expiresAt)
                return HostPrepareResponseDTO(description: tampered)
            }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.descriptionMismatch) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func unknownRefusalReasonCollapses() async throws {
        let fixture = try await makeFixture(prepare: { _, _, _ in
            { _ in HostPrepareResponseDTO(description: nil, error: "EVIL\nreason") }
        })
        await #expect(throws: WorkspaceOperatorCeremonyError.prepareFailed("refused")) {
            try await fixture.ceremonies.propose(
                customParams(fixture), requester: requester(), clientRequestID: nil)
        }
    }

    @Test func rebindAfterTerminalReportsUnknown() async throws {
        let fixture = try await makeFixture()
        let ui = AuthenticatedOperatorUIConnectionID()
        let cancelled = try await pendingOperation(fixture)
        _ = try await fixture.ceremonies.bindReview(operationID: cancelled, uiConnection: ui)
        _ = try await fixture.ceremonies.cancelReview(operationID: cancelled, uiConnection: ui)
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.bindReview(operationID: cancelled, uiConnection: ui)
        }
        let authorized = try await pendingOperation(fixture)
        let (challenge, _) = try await fixture.ceremonies.bindReview(
            operationID: authorized, uiConnection: ui)
        _ = try await fixture.ceremonies.completeCeremony(
            UIOperatorCompletion(
                challengeID: challenge.challengeID, operationID: authorized,
                outcome: .authenticated),
            uiConnection: ui)
        await #expect(throws: WorkspaceOperatorCeremonyError.unknownOperation) {
            try await fixture.ceremonies.bindReview(operationID: authorized, uiConnection: ui)
        }
        // Terminal states stay readable via the authorizer, not retention.
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: cancelled) == "cancelled")
        #expect(await fixture.ceremonies.ceremonyStatus(operationID: authorized) == "authorized")
    }
}
