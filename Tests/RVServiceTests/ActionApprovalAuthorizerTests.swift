import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Step 6 authorizer logic: closed lifecycle, exact bindings, atomic
/// consume-once, monotonic expiry, and fail-closed invalidation. These tests
/// exercise state transitions only; principal liveness proofs belong to the
/// ceremony tests, and transport authenticity to the bridges.
@Suite("Action approval authorizer logic")
struct ActionApprovalAuthorizerTests {
    private func principal() -> ActionApprovalPrincipal {
        ActionApprovalPrincipal(
            instanceID: AgentInstanceID(),
            definitionID: AgentDefinitionID(rawValue: "test-agent"),
            definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "a", count: 64)),
            runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            hostID: WorkspaceHostID(),
            hostGeneration: WorkspaceHostGeneration(),
            owner: OwnerPrincipal(uid: 501))
    }

    private func action(_ command: String = "echo hello") -> ProposedAction {
        .shell(ShellAction(
            fingerprint: ActionFingerprint(rawValue: "test:\(command)"),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: "/work")),
            supportingCommand: ShellCommand(rawValue: command)))
    }

    /// Controllable monotonic clock. `advance` moves time forward only.
    private final class ManualClock: Sendable {
        private let now: Mutex<ContinuousClock.Instant>
        init(_ initial: ContinuousClock.Instant = .now) { now = Mutex(initial) }
        func read() -> ContinuousClock.Instant { now.withLock { $0 } }
        func advance(by seconds: TimeInterval) {
            now.withLock { $0 = $0.advanced(by: .seconds(seconds)) }
        }
    }

    private func authorizer(clock: ManualClock? = nil) -> (ActionApprovalAuthorizer, ManualClock) {
        let manual = clock ?? ManualClock()
        let authorizer = ActionApprovalAuthorizer(
            clock: { Date() },
            monotonicNow: { manual.read() })
        return (authorizer, manual)
    }

    private func created(
        _ authorizer: ActionApprovalAuthorizer,
        principal: ActionApprovalPrincipal? = nil,
        action: ProposedAction? = nil,
        hostConnection: UUID = UUID()
    ) async throws -> (
        reference: ActionApprovalReference,
        continuation: ActionApprovalContinuationID,
        principal: ActionApprovalPrincipal,
        digest: String
    ) {
        let bound = principal ?? self.principal()
        let act = action ?? self.action()
        let created = try await authorizer.createApproval(
            principal: bound, hostConnectionID: hostConnection, action: act)
        return (
            created.reference, created.continuationID, bound,
            CanonicalActionDigest.sha256Hex(of: act))
    }

    private func challenged(
        _ authorizer: ActionApprovalAuthorizer,
        approvalID: ActionApprovalID,
        uiConnection: AuthenticatedOperatorUIConnectionID = AuthenticatedOperatorUIConnectionID()
    ) async throws -> (ActionApprovalChallenge, AuthenticatedOperatorUIConnectionID) {
        let challenge = try await authorizer.issueChallenge(
            approvalID: approvalID, uiConnection: uiConnection)
        return (challenge, uiConnection)
    }

    private func authorized(
        _ authorizer: ActionApprovalAuthorizer,
        challenge: ActionApprovalChallenge,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> ActionApprovalReference {
        try await authorizer.completeChallenge(
            challenge, uiConnection: uiConnection, result: .authenticated)
    }

    // MARK: - Happy path

    @Test func createIssueCompleteConsume() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .pending)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        #expect(challenge.principal == setup.principal)
        #expect(challenge.actionDigestHex == setup.digest)
        #expect(challenge.continuationID == setup.continuation)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .awaitingAuthentication)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        #expect(reference == setup.reference)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .authorized)
        let consumption = try await authorizer.consumeGrant(
            reference,
            expectation: ActionApprovalConsumeExpectation(
                principal: setup.principal,
                actionDigestHex: setup.digest,
                continuationID: setup.continuation))
        #expect(consumption.principal == setup.principal)
        #expect(consumption.actionDigestHex == setup.digest)
        #expect(consumption.continuationID == setup.continuation)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .consumed)
    }

    @Test func replayOfConsumedGrantRejects() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let expectation = ActionApprovalConsumeExpectation(
            principal: setup.principal,
            actionDigestHex: setup.digest,
            continuationID: setup.continuation)
        _ = try await authorizer.consumeGrant(reference, expectation: expectation)
        await #expect(throws: ActionApprovalError.consumed) {
            try await authorizer.consumeGrant(reference, expectation: expectation)
        }
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .consumed)
    }

    // MARK: - Exact bindings

    @Test func wrongInstanceRejects() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        var other = setup.principal
        other = ActionApprovalPrincipal(
            instanceID: AgentInstanceID(), definitionID: other.definitionID,
            definitionRevision: other.definitionRevision, runtimeSessionID: other.runtimeSessionID,
            workspaceSessionID: other.workspaceSessionID, hostID: other.hostID,
            hostGeneration: other.hostGeneration, owner: other.owner)
        await #expect(throws: ActionApprovalError.bindingMismatch) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: other, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
    }

    @Test func definitionAloneIsInsufficient() async throws {
        // Same definition, revision, workspace, host, and owner — but a
        // different instance and runtime: must not consume.
        let (authorizer, _) = authorizer()
        let first = principal()
        let setup = try await created(authorizer, principal: first)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let second = ActionApprovalPrincipal(
            instanceID: AgentInstanceID(), definitionID: first.definitionID,
            definitionRevision: first.definitionRevision,
            runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: first.workspaceSessionID, hostID: first.hostID,
            hostGeneration: first.hostGeneration, owner: first.owner)
        await #expect(throws: ActionApprovalError.bindingMismatch) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: second, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
    }

    @Test func eachPrincipalFieldIsBinding() async throws {
        let (authorizer, _) = authorizer()
        let base = principal()
        let setup = try await created(authorizer, principal: base)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let variants: [ActionApprovalPrincipal] = [
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: AgentDefinitionID(rawValue: "other"),
                definitionRevision: base.definitionRevision, runtimeSessionID: base.runtimeSessionID,
                workspaceSessionID: base.workspaceSessionID, hostID: base.hostID,
                hostGeneration: base.hostGeneration, owner: base.owner),
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: base.definitionID,
                definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "b", count: 64)),
                runtimeSessionID: base.runtimeSessionID,
                workspaceSessionID: base.workspaceSessionID, hostID: base.hostID,
                hostGeneration: base.hostGeneration, owner: base.owner),
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: base.definitionID,
                definitionRevision: base.definitionRevision,
                runtimeSessionID: RuntimeSessionID(),
                workspaceSessionID: base.workspaceSessionID, hostID: base.hostID,
                hostGeneration: base.hostGeneration, owner: base.owner),
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: base.definitionID,
                definitionRevision: base.definitionRevision, runtimeSessionID: base.runtimeSessionID,
                workspaceSessionID: WorkspaceSessionID(), hostID: base.hostID,
                hostGeneration: base.hostGeneration, owner: base.owner),
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: base.definitionID,
                definitionRevision: base.definitionRevision, runtimeSessionID: base.runtimeSessionID,
                workspaceSessionID: base.workspaceSessionID, hostID: WorkspaceHostID(),
                hostGeneration: base.hostGeneration, owner: base.owner),
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: base.definitionID,
                definitionRevision: base.definitionRevision, runtimeSessionID: base.runtimeSessionID,
                workspaceSessionID: base.workspaceSessionID, hostID: base.hostID,
                hostGeneration: WorkspaceHostGeneration(), owner: base.owner),
            ActionApprovalPrincipal(
                instanceID: base.instanceID, definitionID: base.definitionID,
                definitionRevision: base.definitionRevision, runtimeSessionID: base.runtimeSessionID,
                workspaceSessionID: base.workspaceSessionID, hostID: base.hostID,
                hostGeneration: base.hostGeneration, owner: OwnerPrincipal(uid: 502)),
        ]
        for variant in variants {
            await #expect(throws: ActionApprovalError.bindingMismatch) {
                try await authorizer.consumeGrant(
                    reference,
                    expectation: ActionApprovalConsumeExpectation(
                        principal: variant, actionDigestHex: setup.digest,
                        continuationID: setup.continuation))
            }
        }
        // All rejections left the grant intact: exact bindings still win.
        _ = try await authorizer.consumeGrant(
            reference,
            expectation: ActionApprovalConsumeExpectation(
                principal: setup.principal, actionDigestHex: setup.digest,
                continuationID: setup.continuation))
    }

    @Test func wrongActionDigestRejects() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let otherDigest = CanonicalActionDigest.sha256Hex(of: action("echo otherwise"))
        await #expect(throws: ActionApprovalError.bindingMismatch) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: otherDigest,
                    continuationID: setup.continuation))
        }
    }

    @Test func wrongContinuationRejects() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        await #expect(throws: ActionApprovalError.bindingMismatch) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: ActionApprovalContinuationID()))
        }
    }

    @Test func wrongEpochRejects() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        _ = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let stale = ActionApprovalReference(
            approvalID: setup.reference.approvalID,
            epoch: ActionApprovalIssuerEpoch())
        await #expect(throws: ActionApprovalError.wrongEpoch) {
            try await authorizer.consumeGrant(
                stale,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
    }

    @Test func serviceRestartInvalidatesEverything() async throws {
        // A fresh authorizer (new epoch) rejects the old incarnation's
        // references AND does not know its approvals at all.
        let (first, _) = authorizer()
        let setup = try await created(first)
        let second = ActionApprovalAuthorizer()
        await #expect(throws: ActionApprovalError.wrongEpoch) {
            try await second.consumeGrant(
                setup.reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
        await #expect(throws: ActionApprovalError.unknownApproval) {
            try await second.status(of: setup.reference.approvalID)
        }
    }

    // MARK: - Deny

    @Test func denyIsTerminalAndGrantsNothing() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        try await authorizer.deny(challenge, uiConnection: ui)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .denied)
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.consumeGrant(
                setup.reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
        // No resurrection: completion after deny fails too.
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.completeChallenge(
                challenge, uiConnection: ui, result: .authenticated)
        }
    }

    @Test func denyBindsChallengeAndConnection() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, _) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        // Wrong UI connection cannot deny another connection's review.
        await #expect(throws: ActionApprovalError.bindingMismatch) {
            try await authorizer.deny(challenge, uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        // A substituted challenge cannot deny either.
        let other = try await created(authorizer)
        let (otherChallenge, otherUI) = try await challenged(
            authorizer, approvalID: other.reference.approvalID)
        _ = otherChallenge
        _ = otherUI
        await #expect(throws: ActionApprovalError.bindingMismatch) {
            try await authorizer.completeChallenge(
                challenge, uiConnection: otherUI, result: .authenticated)
        }
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .awaitingAuthentication)
    }

    @Test func nonSuccessCompletionFailsTerminally() async throws {
        for result in [
            OperatorAuthenticationResult.cancelled,
            .unavailable,
            .failed,
        ] {
            let (authorizer, _) = authorizer()
            let setup = try await created(authorizer)
            let (challenge, ui) = try await challenged(
                authorizer, approvalID: setup.reference.approvalID)
            await #expect(throws: ActionApprovalError.authenticationFailed) {
                try await authorizer.completeChallenge(
                    challenge, uiConnection: ui, result: result)
            }
            #expect(try await authorizer.status(of: setup.reference.approvalID) == .failed)
        }
    }

    @Test func challengeSubstitutionAcrossApprovalsRejects() async throws {
        let (authorizer, _) = authorizer()
        let first = try await created(authorizer)
        let second = try await created(authorizer)
        let (challengeA, uiA) = try await challenged(
            authorizer, approvalID: first.reference.approvalID)
        let (challengeB, uiB) = try await challenged(
            authorizer, approvalID: second.reference.approvalID)
        // Tampered challenge: A's body retargeted at B's approval.
        // Stored-for-B is challengeB, so full equality fails.
        let retargeted = ActionApprovalChallenge(
            id: challengeA.id, epoch: challengeA.epoch,
            approvalID: second.reference.approvalID,
            principal: challengeA.principal,
            actionDigestHex: challengeA.actionDigestHex,
            continuationID: challengeA.continuationID,
            uiConnection: challengeA.uiConnection,
            issuedWall: challengeA.issuedWall,
            deadlineMono: challengeA.deadlineMono)
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.completeChallenge(
                retargeted, uiConnection: uiA, result: .authenticated)
        }
        // Honest challenges still complete their own approvals.
        _ = try await authorizer.completeChallenge(
            challengeA, uiConnection: uiA, result: .authenticated)
        _ = try await authorizer.completeChallenge(
            challengeB, uiConnection: uiB, result: .authenticated)
        #expect(try await authorizer.status(of: first.reference.approvalID) == .authorized)
        #expect(try await authorizer.status(of: second.reference.approvalID) == .authorized)
    }

    // MARK: - Expiry (monotonic, now == deadline fails closed)

    @Test func pendingExpiryAtExactDeadline() async throws {
        let (authorizer, clock) = authorizer()
        let setup = try await created(authorizer)
        clock.advance(by: ActionApprovalLimits.approvalLifetime - 1)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .pending)
        clock.advance(by: 1)
        await #expect(throws: ActionApprovalError.expired) {
            try await authorizer.issueChallenge(
                approvalID: setup.reference.approvalID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .expired)
    }

    @Test func challengeExpiryAtExactDeadline() async throws {
        let (authorizer, clock) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        clock.advance(by: ActionApprovalLimits.challengeLifetime)
        await #expect(throws: ActionApprovalError.expired) {
            try await authorizer.completeChallenge(
                challenge, uiConnection: ui, result: .authenticated)
        }
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .expired)
    }

    @Test func grantExpiryAtExactDeadline() async throws {
        let (authorizer, clock) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        clock.advance(by: ActionApprovalLimits.grantLifetime - 1)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .authorized)
        clock.advance(by: 1)
        await #expect(throws: ActionApprovalError.expired) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .expired)
    }

    // MARK: - Terminal discipline

    @Test func terminalStatesNeverLeave() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        _ = try await authorizer.consumeGrant(
            reference,
            expectation: ActionApprovalConsumeExpectation(
                principal: setup.principal, actionDigestHex: setup.digest,
                continuationID: setup.continuation))
        // Consumed: every further transition rejects.
        await #expect(throws: ActionApprovalError.consumed) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.cancel(approvalID: setup.reference.approvalID)
        }
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.issueChallenge(
                approvalID: setup.reference.approvalID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func cancelBurnsIssuedGrant() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        try await authorizer.cancel(approvalID: setup.reference.approvalID)
        #expect(try await authorizer.status(of: setup.reference.approvalID) == .invalidated)
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
    }

    // MARK: - Invalidation

    @Test func hostDisconnectInvalidatesBoundLiveOnly() async throws {
        let (authorizer, _) = authorizer()
        let channel = UUID()
        let bound = try await created(authorizer, hostConnection: channel)
        let other = try await created(authorizer, hostConnection: UUID())
        await authorizer.hostDisconnected(connectionID: channel)
        #expect(try await authorizer.status(of: bound.reference.approvalID) == .invalidated)
        #expect(try await authorizer.status(of: other.reference.approvalID) == .pending)
    }

    @Test func uiDisconnectInvalidatesBoundCeremonyOnly() async throws {
        let (authorizer, _) = authorizer()
        let ui = AuthenticatedOperatorUIConnectionID()
        let bound = try await created(authorizer)
        _ = try await challenged(authorizer, approvalID: bound.reference.approvalID, uiConnection: ui)
        let unbound = try await created(authorizer)
        await authorizer.uiDisconnected(ui)
        #expect(try await authorizer.status(of: bound.reference.approvalID) == .invalidated)
        // No UI binding yet: untouched.
        #expect(try await authorizer.status(of: unbound.reference.approvalID) == .pending)
    }

    @Test func principalInvalidationKillsOnlyThatInstance() async throws {
        let (authorizer, _) = authorizer()
        let dead = principal()
        let live = principal()
        let deadSetup = try await created(authorizer, principal: dead)
        let liveSetup = try await created(authorizer, principal: live)
        await authorizer.principalInvalidated(dead.instanceID)
        #expect(try await authorizer.status(of: deadSetup.reference.approvalID) == .invalidated)
        #expect(try await authorizer.status(of: liveSetup.reference.approvalID) == .pending)
    }

    @Test func invalidationBurnsIssuedGrant() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        await authorizer.principalInvalidated(setup.principal.instanceID)
        await #expect(throws: ActionApprovalError.stateMismatch) {
            try await authorizer.consumeGrant(
                reference,
                expectation: ActionApprovalConsumeExpectation(
                    principal: setup.principal, actionDigestHex: setup.digest,
                    continuationID: setup.continuation))
        }
    }

    // MARK: - Capacity

    @Test func storeFullRefusesBeyondCap() async throws {
        let (authorizer, _) = authorizer()
        for _ in 0..<ActionApprovalLimits.maxApprovals {
            _ = try await created(authorizer)
        }
        await #expect(throws: ActionApprovalError.storeFull) {
            _ = try await self.created(authorizer)
        }
    }

    @Test func perPrincipalQuotaBoundsOneHostileAgent() async throws {
        let (authorizer, _) = authorizer()
        let hog = principal()
        var hogRefs: [ActionApprovalReference] = []
        for _ in 0..<ActionApprovalLimits.maxLivePerPrincipal {
            hogRefs.append((try await created(authorizer, principal: hog)).reference)
        }
        // Ninth live approval for the same instance refuses, while the
        // global store still has room: another principal creates freely.
        await #expect(throws: ActionApprovalError.storeFull) {
            _ = try await self.created(authorizer, principal: hog)
        }
        _ = try await created(authorizer)
        // Terminal records never count against the quota: deny one of the
        // hog's approvals and it may create again, then refuses once more.
        let (challenge, ui) = try await challenged(
            authorizer, approvalID: hogRefs[0].approvalID)
        try await authorizer.deny(challenge, uiConnection: ui)
        _ = try await created(authorizer, principal: hog)
        await #expect(throws: ActionApprovalError.storeFull) {
            _ = try await self.created(authorizer, principal: hog)
        }
    }

    @Test func consumedMarkersSurviveSweepForReplay() async throws {
        let (authorizer, clock) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let expectation = ActionApprovalConsumeExpectation(
            principal: setup.principal, actionDigestHex: setup.digest,
            continuationID: setup.continuation)
        _ = try await authorizer.consumeGrant(reference, expectation: expectation)
        clock.advance(by: ActionApprovalLimits.approvalLifetime + 60)
        await authorizer.sweep()
        // Still known as consumed (replay rejects), not resurrected.
        await #expect(throws: ActionApprovalError.consumed) {
            try await authorizer.consumeGrant(reference, expectation: expectation)
        }
    }

    // MARK: - Concurrency (deterministic)

    @Test func concurrentConsumeYieldsExactlyOneWinner() async throws {
        let (authorizer, _) = authorizer()
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        let expectation = ActionApprovalConsumeExpectation(
            principal: setup.principal, actionDigestHex: setup.digest,
            continuationID: setup.continuation)
        let winners = Mutex(0)
        let consumed = Mutex(0)
        // Barrier: all tasks enter together so the race is real.
        let gate = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    gate.withLock { $0 += 1 }
                    while gate.withLock({ $0 }) < 32 { await Task.yield() }
                    do {
                        _ = try await authorizer.consumeGrant(reference, expectation: expectation)
                        winners.withLock { $0 += 1 }
                    } catch ActionApprovalError.consumed {
                        consumed.withLock { $0 += 1 }
                    } catch {
                        Issue.record("unexpected consume error: \(error)")
                    }
                }
            }
        }
        #expect(winners.withLock { $0 } == 1)
        #expect(consumed.withLock { $0 } == 31)
    }

    @Test func completeVersusUIDisconnectIsConsistent() async throws {
        // UI disconnect racing completion: either the grant issues (then
        // the disconnect finds authorized-and-bound and burns it) or the
        // disconnect wins (completion throws). Both are terminally
        // consistent; no grant survives usable after a disconnect.
        for _ in 0..<25 {
            let (authorizer, _) = authorizer()
            let setup = try await created(authorizer)
            let (challenge, ui) = try await challenged(
                authorizer, approvalID: setup.reference.approvalID)
            let gate = Mutex(0)
            async let complete: Void = {
                gate.withLock { $0 += 1 }
                while gate.withLock({ $0 }) < 2 { await Task.yield() }
                _ = try? await authorizer.completeChallenge(
                    challenge, uiConnection: ui, result: .authenticated)
            }()
            async let disconnect: Void = {
                gate.withLock { $0 += 1 }
                while gate.withLock({ $0 }) < 2 { await Task.yield() }
                await authorizer.uiDisconnected(ui)
            }()
            _ = await (complete, disconnect)
            let status = try await authorizer.status(of: setup.reference.approvalID)
            // Whoever wins, the bound ceremony is dead: either the
            // disconnect burned the issued grant or it killed the challenge
            // before completion.
            #expect(status == .invalidated)
            await #expect(throws: ActionApprovalError.self) {
                try await authorizer.consumeGrant(
                    setup.reference,
                    expectation: ActionApprovalConsumeExpectation(
                        principal: setup.principal, actionDigestHex: setup.digest,
                        continuationID: setup.continuation))
            }
        }
    }

    @Test func completeVersusExpiryIsConsistent() async throws {
        // Completion racing the challenge deadline: either the grant
        // issues just in time or expiry wins. Both are terminally
        // consistent.
        for _ in 0..<25 {
            let (authorizer, clock) = authorizer()
            let setup = try await created(authorizer)
            let (challenge, ui) = try await challenged(
                authorizer, approvalID: setup.reference.approvalID)
            clock.advance(by: ActionApprovalLimits.challengeLifetime - 0.5)
            let gate = Mutex(0)
            async let complete: Void = {
                gate.withLock { $0 += 1 }
                while gate.withLock({ $0 }) < 2 { await Task.yield() }
                _ = try? await authorizer.completeChallenge(
                    challenge, uiConnection: ui, result: .authenticated)
            }()
            async let expire: Void = {
                gate.withLock { $0 += 1 }
                while gate.withLock({ $0 }) < 2 { await Task.yield() }
                clock.advance(by: 1)
            }()
            _ = await (complete, expire)
            let status = try await authorizer.status(of: setup.reference.approvalID)
            #expect(status == .authorized || status == .expired)
            if status == .authorized {
                _ = try await authorizer.consumeGrant(
                    setup.reference,
                    expectation: ActionApprovalConsumeExpectation(
                        principal: setup.principal, actionDigestHex: setup.digest,
                        continuationID: setup.continuation))
            } else {
                await #expect(throws: ActionApprovalError.self) {
                    try await authorizer.consumeGrant(
                        setup.reference,
                        expectation: ActionApprovalConsumeExpectation(
                            principal: setup.principal, actionDigestHex: setup.digest,
                            continuationID: setup.continuation))
                }
            }
        }
    }

    @Test func completeVersusDenyYieldsExactlyOneWinner() async throws {
        for _ in 0..<25 {
            let (authorizer, _) = authorizer()
            let setup = try await created(authorizer)
            let (challenge, ui) = try await challenged(
                authorizer, approvalID: setup.reference.approvalID)
            let gate = Mutex(0)
            async let complete: Void = {
                gate.withLock { $0 += 1 }
                while gate.withLock({ $0 }) < 2 { await Task.yield() }
                _ = try? await authorizer.completeChallenge(
                    challenge, uiConnection: ui, result: .authenticated)
            }()
            async let deny: Void = {
                gate.withLock { $0 += 1 }
                while gate.withLock({ $0 }) < 2 { await Task.yield() }
                _ = try? await authorizer.deny(challenge, uiConnection: ui)
            }()
            _ = await (complete, deny)
            let status = try await authorizer.status(of: setup.reference.approvalID)
            #expect(status == .authorized || status == .denied)
        }
    }

    // MARK: - Audit

    @Test func auditTrailCoversLifecycle() async throws {
        let events = Mutex<[ActionApprovalAuditEvent]>([])
        let authorizer = ActionApprovalAuthorizer(
            clock: { Date() },
            monotonicNow: { ContinuousClock.now },
            audit: { event in events.withLock { $0.append(event) } })
        let setup = try await created(authorizer)
        let (challenge, ui) = try await challenged(authorizer, approvalID: setup.reference.approvalID)
        let reference = try await authorized(authorizer, challenge: challenge, uiConnection: ui)
        _ = try await authorizer.consumeGrant(
            reference,
            expectation: ActionApprovalConsumeExpectation(
                principal: setup.principal, actionDigestHex: setup.digest,
                continuationID: setup.continuation))
        let kinds = events.withLock { $0.map(\.kind) }
        #expect(kinds == [
            .approvalCreated, .challengeIssued, .authenticationCompleted,
            .grantIssued, .grantConsumed,
        ])
        for event in events.withLock({ $0 }) {
            #expect(event.approvalID == setup.reference.approvalID)
            #expect(event.principal == setup.principal)
            #expect(event.actionDigestHex == setup.digest)
            #expect(event.continuationID == setup.continuation)
        }
    }
}
