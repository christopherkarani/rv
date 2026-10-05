import Foundation
import Testing
import Synchronization
import RVDomain
@testable import RVService

@Suite("Exact owner authorization")
struct ControlAuthorizationTests {
    private struct Authenticator: OwnerAuthenticating {
        let accepted: Bool
        func authenticate(reason: String) async -> Bool { accepted }
    }

    private final class TestClock: Sendable {
        private let values = Mutex((date: Date(), instant: ContinuousClock.now))
        func wallNow() -> Date { values.withLock { $0.date } }
        func monotonicNow() -> ContinuousClock.Instant { values.withLock { $0.instant } }
        func rollBackWallAndAdvanceMonotonic() {
            values.withLock {
                $0.date = $0.date.addingTimeInterval(-3_600)
                $0.instant = $0.instant.advanced(by: .seconds(31))
            }
        }
    }

    private struct AdvancingAuthenticator: OwnerAuthenticating {
        let clock: TestClock
        func authenticate(reason: String) async -> Bool {
            clock.rollBackWallAndAdvanceMonotonic()
            return true
        }
    }

    private func row(subject: ApprovalSubject? = nil) throws -> PendingApproval {
        let fingerprint = ActionFingerprint(rawValue: "stored-action")
        let binding = subject ?? ApprovalSubject(
            agentInstanceID: AgentInstanceID(), runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(), workspaceHostID: WorkspaceHostID(),
            hostGeneration: WorkspaceHostGeneration(), fingerprint: fingerprint,
            continuation: .hostNative, policyContext: "trusted-policy-revision"
        )
        return try PendingApprovalLedger.create(records: [], request: PendingApprovalRequest(
            id: ApprovalID(rawValue: "approval"),
            identity: ApprovalIdentity(session: try #require(SessionID(rawValue: "display")), agent: .claude),
            action: .shell(ShellAction(fingerprint: fingerprint)), reason: .mandatoryHuman,
            continuation: .hostNative, timeoutPolicy: .autoDeny, subject: binding
        ), now: Date()).0
    }

    @Test func wallRollbackCannotExtendReceiptLifetime() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .allowOnce))
        let actor = ApprovalActor(owner: .current(), connectionID: UUID())
        let time = TestClock()
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true),
            clock: { time.wallNow() }, monotonicNow: { time.monotonicNow() })
        let permit = try await broker.authenticate(actor: actor, operation: operation,
            reload: { stored }, validateLive: { _ in true })
        time.rollBackWallAndAdvanceMonotonic()
        await #expect(throws: ControlAuthorizationError.expired) {
            _ = try await broker.consume(permit, actor: actor, operation: operation,
                reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test func monotonicExpiryDuringOwnerAuthenticationRejects() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .deny))
        let time = TestClock()
        let broker = ControlAuthorizationBroker(authenticator: AdvancingAuthenticator(clock: time),
            clock: { time.wallNow() }, monotonicNow: { time.monotonicNow() })
        await #expect(throws: ControlAuthorizationError.expired) {
            _ = try await broker.authenticate(actor: ApprovalActor(owner: .current(), connectionID: UUID()),
                operation: operation, reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 0, -1, 301])
    func invalidLifetimeFailsClosed(lifetime: TimeInterval) async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .deny))
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true), lifetime: lifetime)
        await #expect(throws: ControlAuthorizationError.rejected) {
            _ = try await broker.authenticate(actor: ApprovalActor(owner: .current(), connectionID: UUID()),
                operation: operation, reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test func exactOperationConsumesOnce() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .allowOnce))
        let actor = ApprovalActor(owner: .current(), connectionID: UUID())
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        let permit = try await broker.authenticate(actor: actor, operation: operation,
            reload: { stored }, validateLive: { _ in true })
        let first = try await broker.consume(permit, actor: actor, operation: operation,
            reload: { stored }, validateLive: { _ in true })
        #expect(first == operation)
        await #expect(throws: ControlAuthorizationError.consumed) {
            _ = try await broker.consume(permit, actor: actor, operation: operation,
                reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test func concurrentConsumptionHasOneWinner() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .allowOnce))
        let actor = ApprovalActor(owner: .current(), connectionID: UUID())
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        let permit = try await broker.authenticate(actor: actor, operation: operation,
            reload: { stored }, validateLive: { _ in true })
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await broker.consume(permit, actor: actor, operation: operation,
                            reload: { stored }, validateLive: { _ in true })
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        #expect(winners == 1)
    }

    @Test func subjectDiesBeforeConsumptionRejects() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .allowOnce))
        let actor = ApprovalActor(owner: .current(), connectionID: UUID())
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        let permit = try await broker.authenticate(actor: actor, operation: operation,
            reload: { stored }, validateLive: { _ in true })
        await #expect(throws: ControlAuthorizationError.inactive) {
            _ = try await broker.consume(permit, actor: actor, operation: operation,
                reload: { stored }, validateLive: { _ in false })
        }
    }

    @Test func rowMutationDuringAuthenticationRejects() async throws {
        let stored = try row()
        var changed = stored
        changed.continuation = .resume(ApprovalResumeToken(rawValue: "different"))
        let replacement = changed
        let operation = try #require(ApprovalOperation(row: stored, decision: .deny))
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        await #expect(throws: ControlAuthorizationError.changed) {
            _ = try await broker.authenticate(actor: ApprovalActor(owner: .current(), connectionID: UUID()),
                operation: operation, reload: { replacement }, validateLive: { _ in true })
        }
    }

    @Test func revokedDuringAuthenticationRejects() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .allowOnce))
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        await #expect(throws: ControlAuthorizationError.inactive) {
            _ = try await broker.authenticate(actor: ApprovalActor(owner: .current(), connectionID: UUID()),
                operation: operation, reload: { stored }, validateLive: { _ in false })
        }
    }

    @Test func disconnectInvalidatesReceipt() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .deny))
        let actor = ApprovalActor(owner: .current(), connectionID: UUID())
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        let permit = try await broker.authenticate(actor: actor, operation: operation,
            reload: { stored }, validateLive: { _ in true })
        await broker.disconnect(actor.connectionID)
        await #expect(throws: ControlAuthorizationError.consumed) {
            _ = try await broker.consume(permit, actor: actor, operation: operation,
                reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test func freshOwnerAuthenticationRequired() async throws {
        let stored = try row()
        let operation = try #require(ApprovalOperation(row: stored, decision: .deny))
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: false))
        await #expect(throws: ControlAuthorizationError.rejected) {
            _ = try await broker.authenticate(actor: ApprovalActor(owner: .current(), connectionID: UUID()),
                operation: operation, reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test func draftSubstitutionCannotUseReceipt() async throws {
        let stored = try row()
        let original = try #require(ApprovalOperation(row: stored, decision: .createRule, ruleDraftDigest: "draft-a"))
        let changed = try #require(ApprovalOperation(row: stored, decision: .createRule, ruleDraftDigest: "draft-b"))
        let actor = ApprovalActor(owner: .current(), connectionID: UUID())
        let broker = ControlAuthorizationBroker(authenticator: Authenticator(accepted: true))
        let permit = try await broker.authenticate(actor: actor, operation: original,
            reload: { stored }, validateLive: { _ in true })
        await #expect(throws: ControlAuthorizationError.changed) {
            _ = try await broker.consume(permit, actor: actor, operation: changed,
                reload: { stored }, validateLive: { _ in true })
        }
    }

    @Test func legacyRowsCannotCreateOwnerOperation() throws {
        var legacy = try row()
        legacy.subject = nil
        #expect(ApprovalOperation(row: legacy, decision: .allowOnce) == nil)
    }

    @Test func legacyAllowCannotBeDeliveredToHost() throws {
        var stored = try row()
        stored.subject = nil
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: [stored], id: stored.id, decision: .allowOnce,
            fingerprint: stored.fingerprint, identity: stored.identity, now: Date()
        )
        #expect(throws: PendingApprovalError.invalidRequest) {
            _ = try PendingApprovalLedger.consume(records: resolved, id: stored.id,
                fingerprint: stored.fingerprint, identity: stored.identity, now: Date())
        }
    }

    @Test func subjectRoundTripsWithoutBecomingAuthority() throws {
        let stored = try row()
        let decoded = try JSONDecoder().decode(PendingApproval.self, from: JSONEncoder().encode(stored))
        #expect(decoded.subject == stored.subject)
    }
}
