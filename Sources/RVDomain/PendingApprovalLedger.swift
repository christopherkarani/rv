import Foundation

/// Pure pending-approval transitions. No clock, filesystem, or process state.
public enum PendingApprovalLedger: Sendable {
    /// Apply timeout policy. `expiresAt == now` is still awaiting a human.
    public static func sweep(_ records: [PendingApproval], now: Date) -> [PendingApproval] {
        records.map { record in
            guard case .awaitingHuman = record.state, now > record.expiresAt else {
                return record
            }
            switch record.timeoutPolicy {
            case .keepWaiting:
                return record
            case .autoDeny, .failTask:
                var next = record
                next.state = .timedOut(ApprovalTimeoutEnding(policy: record.timeoutPolicy, at: now))
                return next
            }
        }
    }

    public static func create(
        records: [PendingApproval],
        request: PendingApprovalRequest,
        now: Date
    ) throws(PendingApprovalError) -> (PendingApproval, [PendingApproval]) {
        try validate(request)
        let swept = sweep(records, now: now)
        if swept.contains(where: { $0.id == request.id }) {
            throw .duplicateID
        }
        let record = PendingApproval(
            id: request.id,
            identity: request.identity,
            action: request.action,
            reason: request.reason,
            continuation: request.continuation,
            timeoutPolicy: request.timeoutPolicy,
            createdAt: now,
            expiresAt: now.addingTimeInterval(request.ttl),
            state: .awaitingHuman
        )
        var next = swept
        next.append(record)
        return (record, next)
    }

    public static func resolve(
        records: [PendingApproval],
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) throws(PendingApprovalError) -> (PendingApproval, [PendingApproval]) {
        do {
            return try mutate(records, id: id, now: now) { (record) throws(PendingApprovalError) in
                try ensureBinding(record, fingerprint: fingerprint, identity: identity)
                try ensureAwaitingHuman(record)
                var next = record
                next.state = .resolved(ApprovalResolution(decision: decision, resolvedAt: now))
                return next
            }
        } catch {
            throw error
        }
    }

    public static func expire(
        records: [PendingApproval],
        id: ApprovalID,
        now: Date
    ) throws(PendingApprovalError) -> (PendingApproval, [PendingApproval]) {
        do {
            return try mutate(records, id: id, now: now) { (record) throws(PendingApprovalError) in
                try ensureAwaitingHuman(record)
                var next = record
                next.state = .expired(at: now)
                return next
            }
        } catch {
            throw error
        }
    }

    public static func cancel(
        records: [PendingApproval],
        id: ApprovalID,
        now: Date
    ) throws(PendingApprovalError) -> (PendingApproval, [PendingApproval]) {
        do {
            return try mutate(records, id: id, now: now) { (record) throws(PendingApprovalError) in
                try ensureAwaitingHuman(record)
                var next = record
                next.state = .canceled(at: now)
                return next
            }
        } catch {
            throw error
        }
    }

    public static func consume(
        records: [PendingApproval],
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) throws(PendingApprovalError) -> (ApprovalConsumption, [PendingApproval]) {
        let (record, next): (PendingApproval, [PendingApproval])
        do {
            (record, next) = try mutate(records, id: id, now: now) { (record) throws(PendingApprovalError) in
                try ensureBinding(record, fingerprint: fingerprint, identity: identity)
                if record.consumedAt != nil {
                    throw .alreadyConsumed
                }
                switch record.state {
                case .awaitingHuman:
                    throw .notResolved
                case .resolved:
                    var next = record
                    next.consumedAt = now
                    return next
                case .expired:
                    throw .expired
                case .canceled:
                    throw .canceled
                case .timedOut:
                    throw .timedOut
                }
            }
        } catch {
            throw error
        }
        guard case .resolved(let resolution) = record.state else {
            throw .notResolved
        }
        return (ApprovalConsumption(approval: record, decision: resolution.decision), next)
    }

    public static func record(
        in records: [PendingApproval],
        id: ApprovalID,
        now: Date
    ) throws(PendingApprovalError) -> (PendingApproval, [PendingApproval]) {
        let swept = sweep(records, now: now)
        guard let record = swept.first(where: { $0.id == id }) else {
            throw .notFound
        }
        return (record, swept)
    }

    public static func awaitingHuman(_ records: [PendingApproval], now: Date) -> [PendingApproval] {
        sweep(records, now: now).filter { record in
            if case .awaitingHuman = record.state { return true }
            return false
        }
    }

    private static func mutate(
        _ records: [PendingApproval],
        id: ApprovalID,
        now: Date,
        update: (PendingApproval) throws(PendingApprovalError) -> PendingApproval
    ) throws(PendingApprovalError) -> (PendingApproval, [PendingApproval]) {
        let swept = sweep(records, now: now)
        guard let index = swept.firstIndex(where: { $0.id == id }) else {
            throw .notFound
        }
        let updated = try update(swept[index])
        var next = swept
        next[index] = updated
        return (updated, next)
    }

    private static func validate(_ request: PendingApprovalRequest) throws(PendingApprovalError) {
        if request.id.rawValue.isEmpty
            || request.identity.session.rawValue.isEmpty
            || request.identity.agent.rawValue.isEmpty
            || request.ttl <= 0
        {
            throw .invalidRequest
        }
        switch request.continuation {
        case .hostNative:
            return
        case .resume(let token):
            if token.rawValue.isEmpty { throw .invalidRequest }
        case .retry(let fingerprint):
            if fingerprint != request.action.fingerprint {
                throw .continuationMismatch
            }
        }
    }

    private static func ensureBinding(
        _ record: PendingApproval,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity
    ) throws(PendingApprovalError) {
        if record.identity != identity {
            throw .identityMismatch
        }
        if record.fingerprint != fingerprint {
            throw .fingerprintMismatch
        }
        if case .retry(let retryFingerprint) = record.continuation, retryFingerprint != fingerprint {
            throw .continuationMismatch
        }
    }

    private static func ensureAwaitingHuman(_ record: PendingApproval) throws(PendingApprovalError) {
        if record.consumedAt != nil {
            throw .alreadyConsumed
        }
        switch record.state {
        case .awaitingHuman:
            return
        case .resolved:
            throw .alreadyResolved
        case .expired:
            throw .expired
        case .canceled:
            throw .canceled
        case .timedOut:
            throw .timedOut
        }
    }
}
