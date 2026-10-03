import Foundation
import RVDomain

/// Service-minted correlation for one parked ASK. The IDs name the approval
/// and its continuation; they grant nothing. Every call re-proves the live
/// principal and the exact action before the service acts.
public struct CreatedActionApproval: Sendable, Equatable {
    public var approvalID: UUID
    public var continuationID: UUID
    /// Trusted subject snapshot the host retained when parking (session,
    /// workspace, agent context). A description only: every RPC re-proves
    /// liveness against the live registry and the service re-validates via
    /// its own validity RPC before acting.
    public var subject: RuntimeAdmissionSubject

    public init(approvalID: UUID, continuationID: UUID, subject: RuntimeAdmissionSubject) {
        self.approvalID = approvalID
        self.continuationID = continuationID
        self.subject = subject
    }
}

/// Host-side driver for principal-bound action approvals (Step 6).
///
/// The production implementation lives in rv-workspace-host and speaks to
/// rvd over the authenticated host bridge. Tests use fakes. All calls are
/// synchronous and bounded (fail-closed on timeout or transport failure),
/// matching the admission pipeline's synchronous shape; the human wait
/// itself happens in the session's asynchronous waiter, never on the watch
/// thread and never inside the gate.
public protocol ActionApprovalAsking: Sendable {
    /// Record one ASK as a principal-bound approval. Returns the minted
    /// correlation IDs, or nil when no approval exists (service
    /// unreachable, principal not live, store full, malformed input).
    /// Nil leaves the ASK pending-forever, exactly as before Step 6.
    func createApproval(
        subject: RuntimeAdmissionSubject,
        action: ProposedAction,
        reason: RuntimeAskReason,
        policyContext: String
    ) -> CreatedActionApproval?

    /// Safe status poll. Never consumes, never a grant. Returns nil on
    /// transport failure (the waiter keeps polling); terminal strings end
    /// the wait. Status vocabulary: pending, awaitingAuthentication,
    /// authorized, consumed, denied, cancelled, expired, invalidated,
    /// failed, unknown.
    func approvalStatus(_ approval: CreatedActionApproval) -> String?

    /// Atomically consume for the exact parked continuation. Returns true
    /// if and only if THIS call consumed the grant (mayExecute). False —
    /// including on replay — means do not run.
    func consumeApproval(
        _ approval: CreatedActionApproval,
        actionDigestHex: String
    ) -> Bool

    /// Best-effort cancel of one approval (the parked continuation went
    /// away). Never blocks long; results are ignored.
    func cancelApproval(_ approval: CreatedActionApproval)
}
