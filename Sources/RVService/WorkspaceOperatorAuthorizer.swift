import Foundation
import RVDomain
import RVIsolation

/// Service-owned consume-once authorization for identity launches.
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
/// This step wires to nothing: no UI, no LocalAuthentication, no host
/// redemption, no dispatch. `consumePermit` returns a data-only redemption
/// record for future host integration.
actor WorkspaceOperatorAuthorizer {
    /// Fresh unguessable epoch minted once per instance lifetime. Never persisted.
    let epoch: WorkspaceAuthorizationIssuerEpoch

    private let clock: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let audit: (@Sendable (WorkspaceOperatorAuthorizationAuditEvent) -> Void)?
    private var operations: [WorkspaceOperationAuthorizationID: PendingWorkspaceOperation] = [:]

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        audit: (@Sendable (WorkspaceOperatorAuthorizationAuditEvent) -> Void)? = nil
    ) {
        self.epoch = WorkspaceAuthorizationIssuerEpoch()
        self.clock = clock
        self.monotonicNow = monotonicNow
        self.audit = audit
    }

    // MARK: - Creation

    /// Records one exact host-prepared launch as awaiting future human authorization.
    ///
    /// All bindings arrive from trusted internal construction (future:
    /// authenticated host/service paths). The client request ID is stored for
    /// correlation only and is never a key or an authority input.
    func createOperation(
        requester: WorkspaceAuthorizationRequester,
        clientRequestID: UUID?,
        workspace: WorkspaceSessionID,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        registration: WorkspaceHostRegistrationBinding,
        preparedLaunch: PreparedLaunchID,
        intentDigest: WorkspaceLaunchIntentDigest,
        kind: WorkspaceOperationKind,
        definition: WorkspaceOperationDefinitionBinding?
    ) throws -> WorkspaceOperationAuthorizationReference {
        switch kind {
        case .launchAgent:
            guard definition != nil else { throw WorkspaceOperatorAuthorizationError.invalidRequest }
        case .launchCustom:
            guard definition == nil else { throw WorkspaceOperatorAuthorizationError.invalidRequest }
        }
        guard registration.host == host, registration.generation == generation else {
            throw WorkspaceOperatorAuthorizationError.invalidRequest
        }
        evictIfNeeded()
        guard operations.count < WorkspaceOperatorAuthorizationLimits.maxOperations else {
            throw WorkspaceOperatorAuthorizationError.storeFull
        }
        // Defense in depth (mirrors PreparedLaunchStore.insert): never let a
        // fresh mint overwrite a live record, however improbable the collision.
        var id = WorkspaceOperationAuthorizationID()
        while operations[id] != nil {
            id = WorkspaceOperationAuthorizationID()
        }
        let record = PendingWorkspaceOperation(
            id: id,
            epoch: epoch,
            requester: requester,
            clientRequestID: clientRequestID,
            workspace: workspace,
            host: host,
            generation: generation,
            registration: registration,
            preparedLaunch: preparedLaunch,
            intentDigest: intentDigest,
            kind: kind,
            definition: definition,
            createdWall: clock(),
            deadlineMono: monotonicNow().advanced(
                by: .seconds(WorkspaceOperatorAuthorizationLimits.operationLifetime)),
            state: .pendingReview
        )
        operations[id] = record
        emit(.operationCreated, record: record, actor: nil, outcome: "created")
        return WorkspaceOperationAuthorizationReference(authorizationID: id, epoch: epoch)
    }

    // MARK: - Challenge

    /// Issues the single authentication challenge for a pending operation.
    /// A second challenge is never allowed; a new attempt is a new operation.
    func issueChallenge(
        operationID: WorkspaceOperationAuthorizationID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) throws -> OperatorAuthorizationChallenge {
        guard var record = operations[operationID] else {
            throw WorkspaceOperatorAuthorizationError.unknownOperation
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            operations[operationID] = record
            throw WorkspaceOperatorAuthorizationError.expired
        }
        if record.state == .expired {
            throw WorkspaceOperatorAuthorizationError.expired
        }
        guard case .pendingReview = record.state else {
            throw WorkspaceOperatorAuthorizationError.stateMismatch
        }
        let challenge = OperatorAuthorizationChallenge(
            id: OperatorAuthorizationChallengeID(),
            epoch: epoch,
            operationID: operationID,
            workspace: record.workspace,
            host: record.host,
            generation: record.generation,
            registration: record.registration,
            preparedLaunch: record.preparedLaunch,
            intentDigest: record.intentDigest,
            kind: record.kind,
            uiConnection: uiConnection,
            issuedWall: clock(),
            deadlineMono: min(
                now.advanced(by: .seconds(WorkspaceOperatorAuthorizationLimits.challengeLifetime)),
                record.deadlineMono)
        )
        record.state = .challengeIssued(challenge)
        operations[operationID] = record
        emit(.challengeIssued, record: record, actor: nil, outcome: "challenge issued")
        return challenge
    }

    /// Applies one trusted authentication completion to its exact challenge.
    ///
    /// The presented challenge must equal the stored challenge in full
    /// (substitution across operations, epochs, or bindings rejects), and the
    /// UI connection must be the one the challenge was issued to. Success
    /// issues a server-held permit and returns only its opaque reference;
    /// any other result terminally fails the operation.
    func completeChallenge(
        _ challenge: OperatorAuthorizationChallenge,
        uiConnection: AuthenticatedOperatorUIConnectionID,
        result: OperatorAuthenticationResult
    ) throws -> WorkspaceOperationAuthorizationReference {
        guard challenge.epoch == epoch else {
            throw WorkspaceOperatorAuthorizationError.wrongEpoch
        }
        guard var record = operations[challenge.operationID] else {
            throw WorkspaceOperatorAuthorizationError.unknownOperation
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            operations[challenge.operationID] = record
            throw WorkspaceOperatorAuthorizationError.expired
        }
        if record.state == .expired {
            throw WorkspaceOperatorAuthorizationError.expired
        }
        guard case .challengeIssued(let stored) = record.state, stored == challenge else {
            throw WorkspaceOperatorAuthorizationError.stateMismatch
        }
        guard uiConnection == challenge.uiConnection else {
            throw WorkspaceOperatorAuthorizationError.bindingMismatch
        }
        switch result {
        case .authenticated:
            let actor = OperatorAuthorizationActor(
                mechanism: .deviceOwnerAuthentication, uiConnection: uiConnection)
            let permit = WorkspaceOperationPermit(
                authorizationID: record.id,
                epoch: epoch,
                actor: actor,
                requester: record.requester,
                workspace: record.workspace,
                host: record.host,
                generation: record.generation,
                registration: record.registration,
                preparedLaunch: record.preparedLaunch,
                kind: record.kind,
                intentDigest: record.intentDigest,
                definition: record.definition,
                challengeID: challenge.id,
                uiConnection: uiConnection,
                issuedWall: clock(),
                expiryMono: min(
                    now.advanced(by: .seconds(WorkspaceOperatorAuthorizationLimits.permitLifetime)),
                    record.deadlineMono)
            )
            record.state = .authorized(permit)
            operations[record.id] = record
            emit(.authenticationCompleted, record: record, actor: actor, outcome: "authenticated")
            emit(.permitIssued, record: record, actor: actor, outcome: "permit issued")
            return WorkspaceOperationAuthorizationReference(authorizationID: record.id, epoch: epoch)
        case .cancelled, .unavailable, .failed:
            record.state = .failed
            operations[record.id] = record
            emit(.authenticationCompleted, record: record, actor: nil, outcome: String(describing: result))
            emit(.operationFailed, record: record, actor: nil, outcome: String(describing: result))
            throw WorkspaceOperatorAuthorizationError.authenticationFailed
        }
    }

    // MARK: - Cancellation

    /// Cancels a live operation. Cancelling an authorized operation burns its
    /// permit (explicit invalidation, audited as such). Terminal states reject.
    func cancel(operationID: WorkspaceOperationAuthorizationID) throws {
        guard var record = operations[operationID] else {
            throw WorkspaceOperatorAuthorizationError.unknownOperation
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            operations[operationID] = record
            throw WorkspaceOperatorAuthorizationError.expired
        }
        if record.state == .expired {
            throw WorkspaceOperatorAuthorizationError.expired
        }
        switch record.state {
        case .pendingReview, .challengeIssued:
            record.state = .cancelled
            operations[operationID] = record
            emit(.operationCancelled, record: record, actor: nil, outcome: "cancelled")
        case .authorized:
            record.state = .invalidated
            operations[operationID] = record
            emit(.permitInvalidated, record: record, actor: nil, outcome: "cancelled after issuance")
        case .consumed, .cancelled, .expired, .invalidated, .failed:
            throw WorkspaceOperatorAuthorizationError.stateMismatch
        }
    }

    // MARK: - Consume-once

    /// Atomically consumes one issued permit for its exact expected bindings.
    ///
    /// No suspension occurs between the final checks and the `authorized →
    /// consumed` mutation, so concurrent consumers yield exactly one winner;
    /// the loser sees `.consumed`. Consumption burns the authority even if a
    /// future host launch later fails: there is no retry, only a new ceremony.
    /// Returns a data-only redemption record; calls no supervisor, spawns
    /// nothing, mints no instance or capability.
    func consumePermit(
        _ reference: WorkspaceOperationAuthorizationReference,
        expectation: WorkspaceOperationRedemptionExpectation
    ) throws -> VerifiedWorkspaceOperationRedemption {
        guard reference.epoch == epoch else {
            throw WorkspaceOperatorAuthorizationError.wrongEpoch
        }
        guard var record = operations[reference.authorizationID] else {
            throw WorkspaceOperatorAuthorizationError.unknownOperation
        }
        let now = monotonicNow()
        guard !materializeExpiry(&record, now: now) else {
            operations[reference.authorizationID] = record
            throw WorkspaceOperatorAuthorizationError.expired
        }
        if record.state == .expired {
            throw WorkspaceOperatorAuthorizationError.expired
        }
        guard case .authorized(let permit) = record.state else {
            if case .consumed = record.state {
                emit(.replayRejected, record: record, actor: nil, outcome: "replay of consumed permit")
                throw WorkspaceOperatorAuthorizationError.consumed
            }
            throw WorkspaceOperatorAuthorizationError.stateMismatch
        }
        guard expectation.workspace == permit.workspace,
            expectation.host == permit.host,
            expectation.generation == permit.generation,
            expectation.registration == permit.registration,
            expectation.preparedLaunch == permit.preparedLaunch,
            expectation.intentDigest == permit.intentDigest,
            expectation.kind == permit.kind
        else {
            throw WorkspaceOperatorAuthorizationError.bindingMismatch
        }
        record.state = .consumed
        operations[reference.authorizationID] = record
        let redemption = VerifiedWorkspaceOperationRedemption(
            authorizationID: permit.authorizationID,
            epoch: permit.epoch,
            actor: permit.actor,
            workspace: permit.workspace,
            host: permit.host,
            generation: permit.generation,
            registration: permit.registration,
            preparedLaunch: permit.preparedLaunch,
            kind: permit.kind,
            intentDigest: permit.intentDigest,
            definition: permit.definition,
            challengeID: permit.challengeID,
            uiConnection: permit.uiConnection,
            consumedWall: clock(),
            consumedMono: now
        )
        emit(.permitConsumed, record: record, actor: permit.actor, outcome: "consumed")
        return redemption
    }

    // MARK: - Disconnect invalidation (void, idempotent)

    /// Host channel loss invalidates every live record bound to that host
    /// registration. Consumed authority stays consumed; other terminals stay put.
    func hostDisconnected(connectionID: UUID) {
        sweep()
        for id in Array(operations.keys) {
            guard var record = operations[id], isLive(record.state) else { continue }
            guard record.registration.connectionID == connectionID else { continue }
            let hadPermit = isAuthorized(record.state)
            record.state = .invalidated
            operations[id] = record
            emitInvalidation(record: record, hadPermit: hadPermit, reason: "host disconnected")
        }
    }

    /// UI channel loss before consume invalidates the ceremony (fail-closed v1):
    /// a disconnected challenge can never complete into a usable permit, and an
    /// issued-but-unconsumed permit dies with its ceremony. Operations still
    /// awaiting challenge issuance have no UI binding yet and are untouched.
    func uiDisconnected(_ uiConnection: AuthenticatedOperatorUIConnectionID) {
        sweep()
        for id in Array(operations.keys) {
            guard var record = operations[id] else { continue }
            let bound: Bool = switch record.state {
            case .challengeIssued(let challenge): challenge.uiConnection == uiConnection
            case .authorized(let permit): permit.uiConnection == uiConnection
            case .pendingReview, .consumed, .cancelled, .expired, .invalidated, .failed: false
            }
            guard bound else { continue }
            let hadPermit = isAuthorized(record.state)
            record.state = .invalidated
            operations[id] = record
            emitInvalidation(record: record, hadPermit: hadPermit, reason: "ui disconnected")
        }
    }

    /// Requester channel loss invalidates the attempt: authority never outlives
    /// the client that will present it for redemption.
    func requesterDisconnected(connectionID: UUID) {
        sweep()
        for id in Array(operations.keys) {
            guard var record = operations[id], isLive(record.state) else { continue }
            guard record.requester.connectionID == connectionID else { continue }
            let hadPermit = isAuthorized(record.state)
            record.state = .invalidated
            operations[id] = record
            emitInvalidation(record: record, hadPermit: hadPermit, reason: "requester disconnected")
        }
    }

    // MARK: - Status and hygiene

    /// Read-only status. Grants nothing. Lazily materializes expiry so the
    /// reported status always reflects the monotonic clock.
    func status(of operationID: WorkspaceOperationAuthorizationID) throws
        -> WorkspaceOperationAuthorizationStatus
    {
        guard var record = operations[operationID] else {
            throw WorkspaceOperatorAuthorizationError.unknownOperation
        }
        if materializeExpiry(&record, now: monotonicNow()) {
            operations[operationID] = record
        }
        return switch record.state {
        case .pendingReview: .pending
        case .challengeIssued: .awaitingAuthentication
        case .authorized: .authorized
        case .consumed: .consumed
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
        for id in Array(operations.keys) {
            guard var record = operations[id] else { continue }
            if materializeExpiry(&record, now: now) {
                operations[id] = record
            }
            guard !isLive(record.state),
                now >= record.deadlineMono,
                record.state != .consumed
            else { continue }
            operations.removeValue(forKey: id)
        }
    }

    // MARK: - Private

    /// Transitions a live record to `expired` when any governing monotonic
    /// deadline has passed. `now == deadline` fails closed. Returns whether
    /// the record expired here.
    private func materializeExpiry(
        _ record: inout PendingWorkspaceOperation,
        now: ContinuousClock.Instant
    ) -> Bool {
        let expired: Bool = switch record.state {
        case .pendingReview:
            now >= record.deadlineMono
        case .challengeIssued(let challenge):
            now >= record.deadlineMono || now >= challenge.deadlineMono
        case .authorized(let permit):
            now >= record.deadlineMono || now >= permit.expiryMono
        case .consumed, .cancelled, .expired, .invalidated, .failed:
            false
        }
        guard expired else { return false }
        record.state = .expired
        emit(.operationExpired, record: record, actor: nil, outcome: "monotonic deadline passed")
        return true
    }

    private func isLive(_ state: WorkspaceOperationAuthorizationState) -> Bool {
        switch state {
        case .pendingReview, .challengeIssued, .authorized: true
        case .consumed, .cancelled, .expired, .invalidated, .failed: false
        }
    }

    /// Evict-expired-first, then refuse-when-full. Consumed markers go last so
    /// replay rejection survives ordinary hygiene; only capacity pressure drops
    /// them (unknown references still reject, safely).
    private func evictIfNeeded() {
        sweep()
        guard operations.count >= WorkspaceOperatorAuthorizationLimits.maxOperations else { return }
        let now = monotonicNow()
        let evictable = operations.values
            .filter { $0.state == .consumed && now >= $0.deadlineMono }
            .sorted { $0.deadlineMono < $1.deadlineMono }
        for record in evictable {
            guard operations.count >= WorkspaceOperatorAuthorizationLimits.maxOperations else { return }
            operations.removeValue(forKey: record.id)
        }
    }

    private func isAuthorized(_ state: WorkspaceOperationAuthorizationState) -> Bool {
        if case .authorized = state { return true }
        return false
    }

    private func emitInvalidation(
        record: PendingWorkspaceOperation,
        hadPermit: Bool,
        reason: String
    ) {
        emit(hadPermit ? .permitInvalidated : .operationInvalidated,
            record: record, actor: nil, outcome: reason)
    }

    private func emit(
        _ kind: WorkspaceOperatorAuthorizationAuditEvent.Kind,
        record: PendingWorkspaceOperation,
        actor: OperatorAuthorizationActor?,
        outcome: String
    ) {
        guard let audit else { return }
        audit(WorkspaceOperatorAuthorizationAuditEvent(
            kind: kind,
            operationID: record.id,
            workspace: record.workspace,
            host: record.host,
            generation: record.generation,
            preparedLaunch: record.preparedLaunch,
            intentDigestHex: record.intentDigest.sha256Hex,
            operationKind: record.kind,
            actor: actor,
            wall: clock(),
            outcome: outcome))
    }
}
