import Foundation
import RVDomain

/// The resolver is separate from the Agent Instance that is the approval subject.
/// Constructed only by a trusted transport after verifying its control role.
struct ApprovalActor: Sendable, Equatable {
    let owner: OwnerPrincipal
    let connectionID: UUID
}

/// Exact service-derived mutation. Never decoded from client bytes.
struct ApprovalOperation: Sendable, Equatable {
    let row: PendingApproval
    let decision: ApprovalDecision
    let ruleDraftDigest: String?
    let targetPolicyContext: String

    init?(row: PendingApproval, decision: ApprovalDecision, ruleDraftDigest: String? = nil) {
        guard let subject = row.subject,
            subject.fingerprint == row.fingerprint,
            subject.continuation == row.continuation,
            !subject.policyContext.isEmpty,
            case .awaitingHuman = row.state,
            decision != .createRule || !(ruleDraftDigest ?? "").isEmpty
        else { return nil }
        self.row = row
        self.decision = decision
        self.ruleDraftDigest = ruleDraftDigest
        self.targetPolicyContext = subject.policyContext
    }
}

/// An opaque internal receipt, with no Codable conformance or client minting path.
struct ControlAuthorization: Sendable {
    fileprivate let id: UUID
}

enum ControlAuthorizationError: Error, Equatable {
    case unavailable, rejected, disconnected, expired, changed, inactive, consumed
}

/// Consume-once owner authentication bound to a stored row and exact mutation.
/// Live validation must query the authoritative host, never a cached description.
actor ControlAuthorizationBroker {
    private struct Entry {
        let actor: ApprovalActor
        let operation: ApprovalOperation
        let expiresAt: Date
        let monotonicDeadline: ContinuousClock.Instant
    }
    private let authenticator: any OwnerAuthenticating
    private let clock: @Sendable () -> Date
    private let lifetime: TimeInterval
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private var entries: [UUID: Entry] = [:]
    private var disconnected: Set<UUID> = []

    init(
        authenticator: any OwnerAuthenticating = LocalOwnerAuthenticator(),
        lifetime: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.authenticator = authenticator
        self.lifetime = lifetime
        self.clock = clock
        self.monotonicNow = monotonicNow
    }

    func disconnect(_ connectionID: UUID) {
        disconnected.insert(connectionID)
        entries = entries.filter { $0.value.actor.connectionID != connectionID }
    }

    func authenticate(
        actor: ApprovalActor,
        operation: ApprovalOperation,
        reload: @Sendable () async throws -> PendingApproval,
        validateLive: @Sendable (ApprovalSubject) async -> Bool
    ) async throws -> ControlAuthorization {
        guard actor.owner == OwnerPrincipal.current(), lifetime.isFinite, lifetime > 0, lifetime <= 300 else {
            throw ControlAuthorizationError.rejected
        }
        guard !disconnected.contains(actor.connectionID) else {
            throw ControlAuthorizationError.disconnected
        }
        guard let subject = operation.row.subject else { throw ControlAuthorizationError.unavailable }
        let deadline = clock().addingTimeInterval(lifetime)
        let monotonicDeadline = monotonicNow().advanced(by: .seconds(lifetime))
        // All prompt content originates in the service's stored row.
        let reason = "\(operation.decision.rawValue) approval \(operation.row.id.rawValue) for action \(operation.row.fingerprint.rawValue) in policy \(operation.targetPolicyContext)"
            + (operation.ruleDraftDigest.map { " with rule draft digest \($0)" } ?? "")
        guard await authenticator.authenticate(reason: reason) else { throw ControlAuthorizationError.rejected }
        guard clock() < deadline, monotonicNow() < monotonicDeadline else {
            throw ControlAuthorizationError.expired
        }
        guard try await reload() == operation.row else { throw ControlAuthorizationError.changed }
        guard clock() < deadline, monotonicNow() < monotonicDeadline else {
            throw ControlAuthorizationError.expired
        }
        guard await validateLive(subject) else { throw ControlAuthorizationError.inactive }
        guard !disconnected.contains(actor.connectionID) else { throw ControlAuthorizationError.disconnected }
        guard clock() < deadline, monotonicNow() < monotonicDeadline else {
            throw ControlAuthorizationError.expired
        }
        let id = UUID()
        entries[id] = Entry(actor: actor, operation: operation, expiresAt: deadline,
            monotonicDeadline: monotonicDeadline)
        return ControlAuthorization(id: id)
    }

    /// Removes the receipt before suspension, so racing consumers cannot reuse it.
    /// Returning the operation does not create a grant; the authoritative mutation
    /// must still compare-and-transition its row and bind any grant to the subject.
    func consume(
        _ authorization: ControlAuthorization,
        actor: ApprovalActor,
        operation: ApprovalOperation,
        reload: @Sendable () async throws -> PendingApproval,
        validateLive: @Sendable (ApprovalSubject) async -> Bool
    ) async throws -> ApprovalOperation {
        guard let entry = entries.removeValue(forKey: authorization.id) else {
            throw ControlAuthorizationError.consumed
        }
        guard entry.actor == actor, entry.operation == operation else { throw ControlAuthorizationError.changed }
        guard clock() < entry.expiresAt, monotonicNow() < entry.monotonicDeadline else {
            throw ControlAuthorizationError.expired
        }
        guard !disconnected.contains(actor.connectionID) else { throw ControlAuthorizationError.disconnected }
        guard try await reload() == operation.row else { throw ControlAuthorizationError.changed }
        guard clock() < entry.expiresAt, monotonicNow() < entry.monotonicDeadline else {
            throw ControlAuthorizationError.expired
        }
        guard let subject = operation.row.subject, await validateLive(subject) else {
            throw ControlAuthorizationError.inactive
        }
        guard !disconnected.contains(actor.connectionID) else { throw ControlAuthorizationError.disconnected }
        guard clock() < entry.expiresAt, monotonicNow() < entry.monotonicDeadline else {
            throw ControlAuthorizationError.expired
        }
        return operation
    }
}
