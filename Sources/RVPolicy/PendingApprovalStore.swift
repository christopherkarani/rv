import Foundation
import RVDomain
import RVFileStore

/// Durable pending-approval source of truth. Survives process restart.
public actor PendingApprovalStore: PendingApprovalCoordinating {
    nonisolated public let baseDirectory: URL

    private let store: FileLockedJSONLStore<PendingApprovalRecord>
    private var subscribers: [UUID: AsyncStream<PendingApprovalEvent>.Continuation] = [:]

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.store = FileLockedJSONLStore(
            fileURL: RVPolicyPaths.pendingApprovalsFile(inConfigDir: baseDirectory),
            lockURL: RVPolicyPaths.pendingApprovalsLockFile(inConfigDir: baseDirectory),
            directoryURL: baseDirectory
        )
    }

    nonisolated public static func makeLive(home: HomeDirectory) -> PendingApprovalStore {
        PendingApprovalStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
    }

    nonisolated public static func makeID() -> ApprovalID {
        ApprovalID(rawValue: UUID().uuidString)
    }

    public func create(_ request: PendingApprovalRequest, now: Date) async throws -> PendingApproval {
        try mutate(now: now) { records in
            let (record, next) = try PendingApprovalLedger.create(
                records: records,
                request: request,
                now: now
            )
            return Mutation(record: record, records: next, event: .created(record))
        }
    }

    public func list(now: Date) async throws -> [PendingApproval] {
        let swept = try persistSweep(now: now)
        return PendingApprovalLedger.awaitingHuman(swept, now: now)
    }

    public func load(id: ApprovalID, now: Date) async throws -> PendingApproval {
        try mutate(now: now) { records in
            let (record, next) = try PendingApprovalLedger.record(in: records, id: id, now: now)
            return Mutation(record: record, records: next, event: nil)
        }
    }

    public func resolve(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws -> PendingApproval {
        try mutate(now: now) { records in
            let (record, next) = try PendingApprovalLedger.resolve(
                records: records,
                id: id,
                decision: decision,
                fingerprint: fingerprint,
                identity: identity,
                now: now
            )
            return Mutation(record: record, records: next, event: .resolved(record))
        }
    }

    public func expire(id: ApprovalID, now: Date) async throws -> PendingApproval {
        try mutate(now: now) { records in
            let (record, next) = try PendingApprovalLedger.expire(records: records, id: id, now: now)
            return Mutation(record: record, records: next, event: .expired(record))
        }
    }

    public func cancel(id: ApprovalID, now: Date) async throws -> PendingApproval {
        try mutate(now: now) { records in
            let (record, next) = try PendingApprovalLedger.cancel(records: records, id: id, now: now)
            return Mutation(record: record, records: next, event: .canceled(record))
        }
    }

    public func consume(
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws -> ApprovalConsumption {
        let outcome: (ApprovalConsumption, [PendingApprovalEvent])
        do {
            outcome = try withFileLock {
                let loaded = loadRecords()
                let (consumption, next) = try PendingApprovalLedger.consume(
                    records: loaded,
                    id: id,
                    fingerprint: fingerprint,
                    identity: identity,
                    now: now
                )
                let events = timeoutEvents(before: loaded, after: next)
                    + [.consumed(consumption.approval)]
                try writeRecords(next)
                return (consumption, events)
            }
        } catch let error as PendingApprovalError {
            throw error
        } catch {
            throw PendingApprovalError.lockFailed
        }
        publish(outcome.1)
        return outcome.0
    }

    public func events() -> AsyncStream<PendingApprovalEvent> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private struct Mutation {
        var record: PendingApproval
        var records: [PendingApproval]
        var event: PendingApprovalEvent?
    }

    private func mutate(
        now: Date,
        _ body: ([PendingApproval]) throws -> Mutation
    ) throws -> PendingApproval {
        let outcome: (PendingApproval, [PendingApprovalEvent])
        do {
            outcome = try withFileLock {
                let loaded = loadRecords()
                let mutation = try body(loaded)
                let events = timeoutEvents(before: loaded, after: mutation.records)
                    + [mutation.event].compactMap { $0 }
                try writeRecords(mutation.records)
                return (mutation.record, events)
            }
        } catch let error as PendingApprovalError {
            throw error
        } catch {
            throw PendingApprovalError.lockFailed
        }
        publish(outcome.1)
        return outcome.0
    }

    private func persistSweep(now: Date) throws -> [PendingApproval] {
        let outcome: ([PendingApproval], [PendingApprovalEvent])
        do {
            outcome = try withFileLock {
                let loaded = loadRecords()
                let swept = PendingApprovalLedger.sweep(loaded, now: now)
                let events = timeoutEvents(before: loaded, after: swept)
                if swept != loaded {
                    try writeRecords(swept)
                }
                return (swept, events)
            }
        } catch let error as PendingApprovalError {
            throw error
        } catch {
            throw PendingApprovalError.lockFailed
        }
        publish(outcome.1)
        return outcome.0
    }

    private func timeoutEvents(
        before: [PendingApproval],
        after: [PendingApproval]
    ) -> [PendingApprovalEvent] {
        let previous = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        return after.compactMap { record in
            guard case .timedOut = record.state else { return nil }
            if let existing = previous[record.id], case .timedOut = existing.state {
                return nil
            }
            return .timedOut(record)
        }
    }

    private func publish(_ events: [PendingApprovalEvent]) {
        for event in events {
            for continuation in subscribers.values {
                continuation.yield(event)
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func loadRecords() -> [PendingApproval] {
        store.load().filter { $0.schemaVersion == 1 }.map(\.approval)
    }

    private func writeRecords(_ records: [PendingApproval]) throws {
        do {
            try store.save(records.map { PendingApprovalRecord(schemaVersion: 1, approval: $0) })
        } catch is FileLockedStoreError {
            // RVFileStore boundary: every save failure (encode or IO) becomes
            // the domain persistence error, so withFileLock only ever sees
            // genuine lock-acquisition failures.
            throw PendingApprovalError.encodeFailed
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try store.withLock(nonBlocking: false, body)
        } catch let error as FileLockedStoreError {
            // Only withLock-originated failures reach here: the body throws
            // domain errors (writeRecords translates save failures). IO from
            // lock setup collapses into encodeFailed — fail-closed, and both
            // map to ipcError for callers.
            switch error {
            case .lockFailed:
                throw PendingApprovalError.lockFailed
            case .encodeFailed, .ioFailed:
                throw PendingApprovalError.encodeFailed
            }
        }
    }
}

private struct PendingApprovalRecord: Codable, Sendable {
    var schemaVersion: Int
    var approval: PendingApproval
}
