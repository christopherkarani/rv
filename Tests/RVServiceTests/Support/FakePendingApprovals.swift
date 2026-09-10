import Foundation
import RVDomain

actor FakePendingApprovals: PendingApprovalCoordinating {
    struct ResolveCall: Sendable, Equatable {
        var id: ApprovalID
        var decision: ApprovalDecision
        var fingerprint: ActionFingerprint
        var identity: ApprovalIdentity
    }

    private var records: [PendingApproval] = []
    private(set) var resolveCalls: [ResolveCall] = []
    private(set) var createCalls: [PendingApprovalRequest] = []
    var listError: PendingApprovalError?

    func seed(_ record: PendingApproval) {
        records.append(record)
    }

    func create(_ request: PendingApprovalRequest, now: Date) async throws -> PendingApproval {
        createCalls.append(request)
        let (record, next) = try PendingApprovalLedger.create(
            records: records,
            request: request,
            now: now
        )
        records = next
        return record
    }

    func list(now _: Date) async throws -> [PendingApproval] {
        if let listError {
            throw listError
        }
        return records.filter { record in
            if case .awaitingHuman = record.state {
                return true
            }
            return false
        }
    }

    func load(id: ApprovalID, now _: Date) async throws -> PendingApproval {
        guard let record = records.first(where: { $0.id == id }) else {
            throw PendingApprovalError.notFound
        }
        return record
    }

    func resolve(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws -> PendingApproval {
        resolveCalls.append(
            ResolveCall(id: id, decision: decision, fingerprint: fingerprint, identity: identity)
        )
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw PendingApprovalError.notFound
        }
        var record = records[index]
        if record.identity != identity {
            throw PendingApprovalError.identityMismatch
        }
        if record.fingerprint != fingerprint {
            throw PendingApprovalError.fingerprintMismatch
        }
        switch record.state {
        case .awaitingHuman:
            record.state = .resolved(ApprovalResolution(decision: decision, resolvedAt: now))
            records[index] = record
            return record
        case .consumed:
            throw PendingApprovalError.alreadyConsumed
        case .resolved, .expired, .canceled, .timedOut:
            throw PendingApprovalError.alreadyResolved
        }
    }

    func expire(id _: ApprovalID, now _: Date) async throws -> PendingApproval {
        throw PendingApprovalError.notFound
    }

    func cancel(id: ApprovalID, now: Date) async throws -> PendingApproval {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw PendingApprovalError.notFound
        }
        var record = records[index]
        switch record.state {
        case .awaitingHuman:
            record.state = .canceled(at: now)
            records[index] = record
            return record
        case .resolved:
            throw PendingApprovalError.alreadyResolved
        case .consumed:
            throw PendingApprovalError.alreadyConsumed
        case .expired:
            throw PendingApprovalError.expired
        case .canceled:
            throw PendingApprovalError.canceled
        case .timedOut:
            throw PendingApprovalError.timedOut
        }
    }

    func consume(
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws -> ApprovalConsumption {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw PendingApprovalError.notFound
        }
        var record = records[index]
        if record.identity != identity {
            throw PendingApprovalError.identityMismatch
        }
        if record.fingerprint != fingerprint {
            throw PendingApprovalError.fingerprintMismatch
        }
        switch record.state {
        case .resolved(let resolution):
            record.state = .consumed(resolution, at: now)
            records[index] = record
            return ApprovalConsumption(approval: record, decision: resolution.decision)
        case .consumed:
            throw PendingApprovalError.alreadyConsumed
        case .awaitingHuman:
            throw PendingApprovalError.notResolved
        case .expired:
            throw PendingApprovalError.expired
        case .canceled:
            throw PendingApprovalError.canceled
        case .timedOut:
            throw PendingApprovalError.timedOut
        }
    }

    func events() -> AsyncStream<PendingApprovalEvent> {
        AsyncStream { $0.finish() }
    }
}
