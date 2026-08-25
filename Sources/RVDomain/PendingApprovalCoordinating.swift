import Foundation

/// Subscribe/resolve capability a host adapter and later Mac app sit on.
/// Host adapters create; they do not own UI state. Not an XPC transport.
public protocol PendingApprovalCoordinating: Sendable {
    /// Record a pending approval. Caller supplies identity, fingerprint, and continuation.
    func create(_ request: PendingApprovalRequest, now: Date) async throws -> PendingApproval
    /// Awaiting-human records after timeout sweep.
    func list(now: Date) async throws -> [PendingApproval]
    /// Load one record by id after timeout sweep, including terminal rows.
    func record(id: ApprovalID, now: Date) async throws -> PendingApproval
    /// Record a human decision exactly once for this id + fingerprint + identity.
    func resolve(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws -> PendingApproval
    func expire(id: ApprovalID, now: Date) async throws -> PendingApproval
    func cancel(id: ApprovalID, now: Date) async throws -> PendingApproval
    /// Deliver the resolution exactly once to the waiting host path.
    func consume(
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws -> ApprovalConsumption
    func events() async -> AsyncStream<PendingApprovalEvent>
}
