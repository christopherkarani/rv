import Foundation

/// Subscribe/resolve capability a host adapter and later Mac app sit on.
/// Host adapters create; they do not own UI state. Not an XPC transport.
/// Every method fails only with `PendingApprovalError`; there is no untyped failure channel.
public protocol PendingApprovalCoordinating: Sendable {
    /// Record a pending approval. Caller supplies identity, fingerprint, and continuation.
    func create(_ request: PendingApprovalRequest, now: Date) async throws(PendingApprovalError) -> PendingApproval
    /// Awaiting-human records after timeout sweep.
    func list(now: Date) async throws(PendingApprovalError) -> [PendingApproval]
    /// Load one record by id after timeout sweep, including terminal rows.
    func load(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval
    /// Record a human decision exactly once for this id + fingerprint + identity.
    func resolve(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws(PendingApprovalError) -> PendingApproval
    func expire(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval
    func cancel(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval
    /// Deliver the resolution exactly once to the waiting host path.
    func consume(
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws(PendingApprovalError) -> ApprovalConsumption
    func events() async -> AsyncStream<PendingApprovalEvent>
}
