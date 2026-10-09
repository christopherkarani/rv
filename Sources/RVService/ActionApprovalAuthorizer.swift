import Foundation
import RVDomain
import RVIsolation

/// Service-owned consume-once authorization for principal-bound actions.
///
/// One actor instance owns one issuer epoch and every record it mints. All
/// state is memory-only: a service restart is a fresh instance with a fresh
/// epoch, which inherently rejects everything from the prior lifetime.
///
/// Every transition runs to completion with no suspension, so actor
/// serialization makes each check-and-mutate atomic: two racing consumers
/// yield exactly one winner. Monotonic time is the sole expiry authority;
/// wall clock is recorded for audit only and can neither extend nor revive.
///
/// This step wires to no transport: no UI, no LocalAuthentication, no host
/// RPC, no execution. `consumeGrant` returns a data-only consumption record
/// for the ceremony's resume path. The ceremony (not this actor) proves the
/// principal live via the host registry around creation, completion, and
/// consumption; this actor additionally kills every live record the moment
/// it learns a principal died (`principalInvalidated`) or a channel dropped.
actor ActionApprovalAuthorizer {
    /// Fresh unguessable epoch minted once per instance lifetime. Never persisted.
    /// Nonisolated: immutable after init, so every reader sees one value.
    nonisolated let epoch: ActionApprovalIssuerEpoch

    private let clock: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let audit: (@Sendable (ActionApprovalAuditEvent) -> Void)?
    private var approvals: [ActionApprovalID: PendingActionApproval] = [:]

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        audit: (@Sendable (ActionApprovalAuditEvent) -> Void)? = nil
    ) {
        self.epoch = ActionApprovalIssuerEpoch()
        self.clock = clock
        self.monotonicNow = monotonicNow
        self.audit = audit
    }

    // MARK: - Creation

    /// Records one exact action of one exact live principal as awaiting
    /// future human authorization.
    ///
    /// The caller must have proved the principal live through the
    /// authoritative host registry immediately before this call; the
    /// principal binding, host channel, and action arrive from trusted
    /// internal construction, never from request bytes. The service
    /// computes the action digest itself — no presenter-supplied digest is
    /// trusted. A fresh continuation ID is minted: this approval may resume
    /// only the one continuation the host parked for it.
    func createApproval(
        principal: ActionApprovalPrincipal,
        hostConnectionID: UUID,
        action: ProposedAction
    ) throws(ActionApprovalError) -> (reference: ActionApprovalReference, continuationID: ActionApprovalContinuationID) {
        evictIfNeeded()
        guard approvals.count < ActionApprovalLimits.maxApprovals else {
            throw ActionApprovalError.storeFull
        }
        let liveForPrincipal = approvals.values.count {
            $0.principal.instanceID == principal.instanceID && isLive($0.state)
        }
        guard liveForPrincipal < ActionApprovalLimits.maxLivePerPrincipal else {
            throw ActionApprovalError.storeFull
        }
        // Defense in depth: never let a fresh mint overwrite a live record,
        // however improbable the collision.
        var id = ActionApprovalID()
        while approvals[id] != nil {
            id = ActionApprovalID()
        }
        let record = PendingActionApproval(
            id: id,
            epoch: epoch,
            principal: principal,
            hostConnectionID: hostConnectionID,
            actionDigestHex: CanonicalActionDigest.sha256Hex(of: action),
            continuationID: ActionApprovalContinuationID(),
            createdWall: clock(),
            deadlineMono: monotonicNow().advanced(
                by: .seconds(ActionApprovalLimits.approvalLifetime)),
            state: .pendingReview
        )
        approvals[id] = record
        emit(.approvalCreated, record: record, actor: nil, outcome: "created")
        return (
            ActionApprovalReference(approvalID: id, epoch: epoch),
            record.continuationID
        )
    }

    // MARK: - Challenge

    /// Issues the single authentication challenge for a pending approval.
    /// A second challenge is never allowed; a new attempt is a new approval.
    func issueChallenge(
        approvalID: ActionApprovalID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) throws(ActionApprovalError) -> ActionApprovalChallenge {
        guard var record = approvals[approvalID] else {
            throw ActionApprovalError.unknownApproval
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            approvals[approvalID] = record
            throw ActionApprovalError.expired
        }
        if record.state == .expired {
            throw ActionApprovalError.expired
        }
        guard case .pendingReview = record.state else {
            throw ActionApprovalError.stateMismatch
        }
        let challenge = ActionApprovalChallenge(
            id: ActionApprovalChallengeID(),
            epoch: epoch,
            approvalID: approvalID,
            principal: record.principal,
            actionDigestHex: record.actionDigestHex,
            continuationID: record.continuationID,
            uiConnection: uiConnection,
            issuedWall: clock(),
            deadlineMono: min(
                now.advanced(by: .seconds(ActionApprovalLimits.challengeLifetime)),
                record.deadlineMono)
        )
        record.state = .challengeIssued(challenge)
        approvals[approvalID] = record
        emit(.challengeIssued, record: record, actor: nil, outcome: "challenge issued")
        return challenge
    }

    /// Applies one trusted authentication completion to its exact challenge.
    ///
    /// The presented challenge must equal the stored challenge in full
    /// (substitution across approvals, epochs, principals, digests, or
    /// continuations rejects), and the UI connection must be the one the
    /// challenge was issued to. Success issues a server-held grant and
    /// returns only its opaque reference; any other result terminally fails
    /// the approval. The caller must have re-proved the principal live
    /// before this call; revocation racing the call is caught again at
    /// consumption.
    func completeChallenge(
        _ challenge: ActionApprovalChallenge,
        uiConnection: AuthenticatedOperatorUIConnectionID,
        result: OperatorAuthenticationResult
    ) throws(ActionApprovalError) -> ActionApprovalReference {
        guard challenge.epoch == epoch else {
            throw ActionApprovalError.wrongEpoch
        }
        guard var record = approvals[challenge.approvalID] else {
            throw ActionApprovalError.unknownApproval
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            approvals[challenge.approvalID] = record
            throw ActionApprovalError.expired
        }
        if record.state == .expired {
            throw ActionApprovalError.expired
        }
        guard case .challengeIssued(let stored) = record.state, stored == challenge else {
            throw ActionApprovalError.stateMismatch
        }
        guard uiConnection == challenge.uiConnection else {
            throw ActionApprovalError.bindingMismatch
        }
        switch result {
        case .authenticated:
            let actor = OperatorAuthorizationActor(
                mechanism: .deviceOwnerAuthentication, uiConnection: uiConnection)
            let grant = ActionApprovalGrant(
                approvalID: record.id,
                epoch: epoch,
                actor: actor,
                principal: record.principal,
                hostConnectionID: record.hostConnectionID,
                actionDigestHex: record.actionDigestHex,
                continuationID: record.continuationID,
                challengeID: challenge.id,
                uiConnection: uiConnection,
                issuedWall: clock(),
                expiryMono: min(
                    now.advanced(by: .seconds(ActionApprovalLimits.grantLifetime)),
                    record.deadlineMono)
            )
            record.state = .authorized(grant)
            approvals[record.id] = record
            emit(.authenticationCompleted, record: record, actor: actor, outcome: "authenticated")
            emit(.grantIssued, record: record, actor: actor, outcome: "grant issued")
            return ActionApprovalReference(approvalID: record.id, epoch: epoch)
        case .cancelled, .unavailable, .failed:
            record.state = .failed
            approvals[record.id] = record
            emit(.authenticationCompleted, record: record, actor: nil, outcome: String(describing: result))
            emit(.approvalFailed, record: record, actor: nil, outcome: String(describing: result))
            throw ActionApprovalError.authenticationFailed
        }
    }

    // MARK: - Deny

    /// Records an explicit human deny for the exact bound review. Terminal:
    /// no grant exists, none can later issue, and replay cannot reopen the
    /// approval. A later new action request is a new approval, unaffected.
    ///
    /// Deny binds the same challenge as completion: only the UI connection
    /// holding the live bound review may deny it, so one connection cannot
    /// deny another connection's review. Deny grants nothing, but an
    /// unbound deny would still be a cross-review kill — hence the binding.
    func deny(
        _ challenge: ActionApprovalChallenge,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) throws(ActionApprovalError) {
        guard challenge.epoch == epoch else {
            throw ActionApprovalError.wrongEpoch
        }
        guard var record = approvals[challenge.approvalID] else {
            throw ActionApprovalError.unknownApproval
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            approvals[challenge.approvalID] = record
            throw ActionApprovalError.expired
        }
        if record.state == .expired {
            throw ActionApprovalError.expired
        }
        guard case .challengeIssued(let stored) = record.state, stored == challenge else {
            throw ActionApprovalError.stateMismatch
        }
        guard uiConnection == challenge.uiConnection else {
            throw ActionApprovalError.bindingMismatch
        }
        record.state = .denied
        approvals[record.id] = record
        emit(.approvalDenied, record: record, actor: nil, outcome: "denied")
    }

    // MARK: - Cancellation

    /// Cancels a live approval (host-driven: the parked continuation went
    /// away, or the operator abandoned the review). Cancelling an authorized
    /// approval burns its grant (explicit invalidation, audited as such).
    /// Terminal states reject.
    func cancel(approvalID: ActionApprovalID) throws(ActionApprovalError) {
        guard var record = approvals[approvalID] else {
            throw ActionApprovalError.unknownApproval
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            approvals[approvalID] = record
            throw ActionApprovalError.expired
        }
        if record.state == .expired {
            throw ActionApprovalError.expired
        }
        switch record.state {
        case .pendingReview, .challengeIssued:
            record.state = .cancelled
            approvals[approvalID] = record
            emit(.approvalCancelled, record: record, actor: nil, outcome: "cancelled")
        case .authorized:
            record.state = .invalidated
            approvals[approvalID] = record
            emit(.grantInvalidated, record: record, actor: nil, outcome: "cancelled after issuance")
        case .consumed, .denied, .cancelled, .expired, .invalidated, .failed:
            throw ActionApprovalError.stateMismatch
        }
    }

    // MARK: - Consume-once

    /// Atomically consumes one issued grant for its exact expected bindings.
    ///
    /// No suspension occurs between the final checks and the `authorized →
    /// consumed` mutation, so concurrent consumers yield exactly one winner;
    /// the loser sees `.consumed`. Consumption burns the authority even if a
    /// later resume step fails: there is no retry, only a new approval.
    /// Returns a data-only consumption record; executes nothing.
    ///
    /// The caller must have re-proved the principal live immediately before
    /// this call and must re-prove it once more before acting on the result:
    /// revocation racing the call is caught by that trailing check (the
    /// grant stays spent, the action does not run).
    func consumeGrant(
        _ reference: ActionApprovalReference,
        expectation: ActionApprovalConsumeExpectation
    ) throws(ActionApprovalError) -> VerifiedActionApprovalConsumption {
        guard reference.epoch == epoch else {
            throw ActionApprovalError.wrongEpoch
        }
        guard var record = approvals[reference.approvalID] else {
            throw ActionApprovalError.unknownApproval
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            approvals[reference.approvalID] = record
            throw ActionApprovalError.expired
        }
        if record.state == .expired {
            throw ActionApprovalError.expired
        }
        guard case .authorized(let grant) = record.state else {
            if case .consumed = record.state {
                emit(.replayRejected, record: record, actor: nil, outcome: "replay of consumed grant")
                throw ActionApprovalError.consumed
            }
            throw ActionApprovalError.stateMismatch
        }
        guard expectation.principal == grant.principal,
            expectation.actionDigestHex == grant.actionDigestHex,
            expectation.continuationID == grant.continuationID
        else {
            throw ActionApprovalError.bindingMismatch
        }
        record.state = .consumed
        approvals[reference.approvalID] = record
        let consumption = VerifiedActionApprovalConsumption(
            approvalID: grant.approvalID,
            epoch: grant.epoch,
            actor: grant.actor,
            principal: grant.principal,
            actionDigestHex: grant.actionDigestHex,
            continuationID: grant.continuationID,
            challengeID: grant.challengeID,
            uiConnection: grant.uiConnection,
            consumedWall: clock(),
            consumedMono: now
        )
        emit(.grantConsumed, record: record, actor: grant.actor, outcome: "consumed")
        return consumption
    }

    // MARK: - Invalidation (void, idempotent)

    /// Host channel loss invalidates every live record bound to that host
    /// channel. Consumed authority stays consumed; other terminals stay put.
    func hostDisconnected(connectionID: UUID) {
        sweep()
        for id in Array(approvals.keys) {
            guard var record = approvals[id], isLive(record.state) else { continue }
            guard record.hostConnectionID == connectionID else { continue }
            let hadGrant = isAuthorized(record.state)
            record.state = .invalidated
            approvals[id] = record
            emitInvalidation(record: record, hadGrant: hadGrant, reason: "host disconnected")
        }
    }

    /// UI channel loss before consume invalidates the bound ceremony: a
    /// disconnected challenge can never complete into a usable grant, and an
    /// issued-but-unconsumed grant dies with its ceremony. Approvals still
    /// awaiting challenge issuance have no UI binding yet and are untouched.
    func uiDisconnected(_ uiConnection: AuthenticatedOperatorUIConnectionID) {
        sweep()
        for id in Array(approvals.keys) {
            guard var record = approvals[id] else { continue }
            let bound: Bool = switch record.state {
            case .challengeIssued(let challenge): challenge.uiConnection == uiConnection
            case .authorized(let grant): grant.uiConnection == uiConnection
            case .pendingReview, .consumed, .denied, .cancelled, .expired, .invalidated, .failed: false
            }
            guard bound else { continue }
            let hadGrant = isAuthorized(record.state)
            record.state = .invalidated
            approvals[id] = record
            emitInvalidation(record: record, hadGrant: hadGrant, reason: "ui disconnected")
        }
    }

    /// The bound principal died (revoked, finished, or replaced). Every live
    /// record for that exact instance dies with it: no new grant may issue
    /// and no issued grant may be consumed. Consumed authority stays
    /// consumed — it was valid when spent — but nothing further flows.
    func principalInvalidated(_ instanceID: AgentInstanceID) {
        sweep()
        for id in Array(approvals.keys) {
            guard var record = approvals[id], isLive(record.state) else { continue }
            guard record.principal.instanceID == instanceID else { continue }
            let hadGrant = isAuthorized(record.state)
            record.state = .invalidated
            approvals[id] = record
            emitInvalidation(record: record, hadGrant: hadGrant, reason: "principal invalid")
        }
    }

    // MARK: - Status and hygiene

    /// Read-only status. Grants nothing. Lazily materializes expiry so the
    /// reported status always reflects the monotonic clock.
    func status(of approvalID: ActionApprovalID) throws(ActionApprovalError) -> ActionApprovalStatus {
        guard var record = approvals[approvalID] else {
            throw ActionApprovalError.unknownApproval
        }
        if materializeExpiry(&record, now: monotonicNow()) {
            approvals[approvalID] = record
        }
        return switch record.state {
        case .pendingReview: .pending
        case .challengeIssued: .awaitingAuthentication
        case .authorized: .authorized
        case .consumed: .consumed
        case .denied: .denied
        case .cancelled: .cancelled
        case .expired: .expired
        case .invalidated: .invalidated
        case .failed: .failed
        }
    }

    /// Materializes expiries and drops parent-expired terminal records, except
    /// consumed markers, which are retained for replay rejection until capacity
    /// pressure evicts them. Security never depends on this running: every
    /// entry point enforces its own deadlines first.
    func sweep() {
        let now = monotonicNow()
        for id in Array(approvals.keys) {
            guard var record = approvals[id] else { continue }
            if materializeExpiry(&record, now: now) {
                approvals[id] = record
            }
            guard !isLive(record.state),
                now >= record.deadlineMono,
                record.state != .consumed
            else { continue }
            approvals.removeValue(forKey: id)
        }
    }

    // MARK: - Private

    /// Transitions a live record to `expired` when any governing monotonic
    /// deadline has passed. `now == deadline` fails closed. Returns whether
    /// the record expired here.
    private func materializeExpiry(
        _ record: inout PendingActionApproval,
        now: ContinuousClock.Instant
    ) -> Bool {
        let expired: Bool = switch record.state {
        case .pendingReview:
            now >= record.deadlineMono
        case .challengeIssued(let challenge):
            now >= record.deadlineMono || now >= challenge.deadlineMono
        case .authorized(let grant):
            now >= record.deadlineMono || now >= grant.expiryMono
        case .consumed, .denied, .cancelled, .expired, .invalidated, .failed:
            false
        }
        guard expired else { return false }
        record.state = .expired
        emit(.approvalExpired, record: record, actor: nil, outcome: "monotonic deadline passed")
        return true
    }

    private func isLive(_ state: ActionApprovalState) -> Bool {
        switch state {
        case .pendingReview, .challengeIssued, .authorized: true
        case .consumed, .denied, .cancelled, .expired, .invalidated, .failed: false
        }
    }

    /// Evict-expired-first, then refuse-when-full. Consumed markers go last so
    /// replay rejection survives ordinary hygiene; only capacity pressure drops
    /// them (unknown references still reject, safely).
    private func evictIfNeeded() {
        sweep()
        guard approvals.count >= ActionApprovalLimits.maxApprovals else { return }
        let now = monotonicNow()
        let evictable = approvals.values
            .filter { $0.state == .consumed && now >= $0.deadlineMono }
            .sorted { $0.deadlineMono < $1.deadlineMono }
        for record in evictable {
            guard approvals.count >= ActionApprovalLimits.maxApprovals else { return }
            approvals.removeValue(forKey: record.id)
        }
    }

    private func isAuthorized(_ state: ActionApprovalState) -> Bool {
        if case .authorized = state { return true }
        return false
    }

    private func emitInvalidation(
        record: PendingActionApproval,
        hadGrant: Bool,
        reason: String
    ) {
        emit(hadGrant ? .grantInvalidated : .approvalInvalidated,
            record: record, actor: nil, outcome: reason)
    }

    private func emit(
        _ kind: ActionApprovalAuditEvent.Kind,
        record: PendingActionApproval,
        actor: OperatorAuthorizationActor?,
        outcome: String
    ) {
        guard let audit else { return }
        audit(ActionApprovalAuditEvent(
            kind: kind,
            approvalID: record.id,
            principal: record.principal,
            actionDigestHex: record.actionDigestHex,
            continuationID: record.continuationID,
            actor: actor,
            wall: clock(),
            outcome: outcome))
    }
}
