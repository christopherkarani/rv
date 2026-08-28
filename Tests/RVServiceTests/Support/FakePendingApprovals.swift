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
    var listError: PendingApprovalError?

    func seed(_ record: PendingApproval) {
        records.append(record)
    }

    func create(_ request: PendingApprovalRequest, now: Date) async throws -> PendingApproval {
        throw PendingApprovalError.invalidRequest
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
        case .resolved, .expired, .canceled, .timedOut:
            throw PendingApprovalError.alreadyResolved
        }
    }

    func expire(id _: ApprovalID, now _: Date) async throws -> PendingApproval {
        throw PendingApprovalError.notFound
    }

    func cancel(id _: ApprovalID, now _: Date) async throws -> PendingApproval {
        throw PendingApprovalError.notFound
    }

    func consume(
        id _: ApprovalID,
        fingerprint _: ActionFingerprint,
        identity _: ApprovalIdentity,
        now _: Date
    ) async throws -> ApprovalConsumption {
        throw PendingApprovalError.notResolved
    }

    func events() -> AsyncStream<PendingApprovalEvent> {
        AsyncStream { $0.finish() }
    }
}
