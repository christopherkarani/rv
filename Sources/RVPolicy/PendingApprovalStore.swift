import Foundation
import RVDomain
import RVFileStore

/// Durable pending-approval source of truth. Survives process restart.
public actor PendingApprovalStore: PendingApprovalCoordinating {
    nonisolated public let baseDirectory: URL

    private let store: FileLockedJSONLStore<PendingApprovalRecord>
    private let reasons: FileLockedJSONLStore<RejectionReasonRecord>
    private var subscribers: [UUID: AsyncStream<PendingApprovalEvent>.Continuation] = [:]

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.store = FileLockedJSONLStore(
            fileURL: RVPolicyPaths.pendingApprovalsFile(inConfigDir: baseDirectory),
            lockURL: RVPolicyPaths.pendingApprovalsLockFile(inConfigDir: baseDirectory),
            directoryURL: baseDirectory
        )
        self.reasons = FileLockedJSONLStore(
            fileURL: Self.rejectionReasonsFile(inConfigDir: baseDirectory),
            lockURL: Self.rejectionReasonsLockFile(inConfigDir: baseDirectory),
            directoryURL: baseDirectory
        )
    }

    nonisolated public static func makeLive(home: HomeDirectory) -> PendingApprovalStore {
        PendingApprovalStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
    }

    nonisolated public static func makeID() -> ApprovalID {
        ApprovalID(rawValue: UUID().uuidString)
    }

    public func create(_ request: PendingApprovalRequest, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        try mutate(now: now) { records throws(PendingApprovalError) in
            let (record, next) = try PendingApprovalLedger.create(
                records: records,
                request: request,
                now: now
            )
            return Mutation(record: record, records: next, event: .created(record))
        }
    }

    public func list(now: Date) async throws(PendingApprovalError) -> [PendingApproval] {
        let swept = try persistSweep(now: now)
        return PendingApprovalLedger.awaitingHuman(swept, now: now)
    }

    public func load(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        try mutate(now: now) { records throws(PendingApprovalError) in
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
    ) async throws(PendingApprovalError) -> PendingApproval {
        try mutate(now: now) { records throws(PendingApprovalError) in
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

    /// Resolve with a human-supplied reason. Phase 4: every rejection
    /// carries its reason; approvals carry none (a reason on an approval
    /// is a caller error, not an annotation).
    ///
    /// The reason is validated before the resolve CAS, and recorded after
    /// it wins: a lost CAS records nothing, and a won CAS whose reason
    /// write fails still stands resolved (the error reports the reason
    /// gap; the decision is already terminal and authoritative).
    public func resolveWithReason(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        reason: String?,
        now: Date
    ) async throws(PendingApprovalError) -> PendingApproval {
        let canonical: String?
        switch decision {
        case .deny:
            guard let text = Self.canonicalRejectionReason(reason) else {
                throw PendingApprovalError.invalidRequest
            }
            canonical = text
        case .allowOnce, .createRule:
            guard reason == nil else {
                throw PendingApprovalError.invalidRequest
            }
            canonical = nil
        }
        let resolved = try await resolve(
            id: id,
            decision: decision,
            fingerprint: fingerprint,
            identity: identity,
            now: now
        )
        if let canonical {
            try recordRejectionReason(id: id, reason: canonical, now: now)
        }
        return resolved
    }

    /// The recorded rejection reason for a denied row, if one landed.
    /// Nil for approvals, for rows resolved without this call, and for
    /// unknown ids. Display only: never authority.
    public func rejectionReason(for id: ApprovalID) -> String? {
        let loaded: [RejectionReasonRecord]
        do {
            loaded = try reasons.withLock(nonBlocking: false) {
                reasons.load().filter { $0.schemaVersion == 1 }
            }
        } catch {
            return nil
        }
        return loaded.first(where: { $0.id == id.rawValue })?.reason
    }

    /// Single-line, trimmed, bounded reason text. Rejects empties,
    /// over-long text, and control characters (fail closed: the human
    /// retypes instead of landing a confusing record).
    public static func canonicalRejectionReason(_ reason: String?) -> String? {
        guard let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.isEmpty == false,
            trimmed.count <= 500
        else {
            return nil
        }
        for scalar in trimmed.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F || (value >= 0x80 && value <= 0x9F) {
                return nil
            }
        }
        return trimmed
    }

    public func expire(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        try mutate(now: now) { records throws(PendingApprovalError) in
            let (record, next) = try PendingApprovalLedger.expire(records: records, id: id, now: now)
            return Mutation(record: record, records: next, event: .expired(record))
        }
    }

    public func cancel(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        try mutate(now: now) { records throws(PendingApprovalError) in
            let (record, next) = try PendingApprovalLedger.cancel(records: records, id: id, now: now)
            return Mutation(record: record, records: next, event: .canceled(record))
        }
    }

    public func consume(
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws(PendingApprovalError) -> ApprovalConsumption {
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
        _ body: ([PendingApproval]) throws(PendingApprovalError) -> Mutation
    ) throws(PendingApprovalError) -> PendingApproval {
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

    private func persistSweep(now: Date) throws(PendingApprovalError) -> [PendingApproval] {
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

    private func writeRecords(_ records: [PendingApproval]) throws(PendingApprovalError) {
        do {
            try store.save(records.map { PendingApprovalRecord(schemaVersion: 1, approval: $0) })
        } catch {
            // RVFileStore boundary: every save failure (encode or IO) becomes
            // the domain persistence error, so withFileLock only ever sees
            // lock-acquisition or lock-setup failures (FileLockedJSONLStoreError),
            // never untranslated save failures.
            throw PendingApprovalError.encodeFailed
        }
    }

    /// Maximum retained rejection reasons. Past the cap the oldest
    /// records evict; the terminal decisions they annotated stand.
    private static let maxRejectionReasons = 1024

    private static func rejectionReasonsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(
            "pending-rejection-reasons.jsonl", isDirectory: false)
    }

    private static func rejectionReasonsLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(
            ".pending-rejection-reasons.lock", isDirectory: false)
    }

    private func recordRejectionReason(
        id: ApprovalID,
        reason: String,
        now: Date
    ) throws(PendingApprovalError) {
        do {
            try reasons.withLock(nonBlocking: false) {
                var loaded = reasons.load().filter { $0.schemaVersion == 1 }
                loaded.removeAll(where: { $0.id == id.rawValue })
                loaded.append(
                    RejectionReasonRecord(
                        schemaVersion: 1,
                        id: id.rawValue,
                        reason: reason,
                        decidedAt: now
                    )
                )
                if loaded.count > Self.maxRejectionReasons {
                    loaded.sort(by: { $0.decidedAt < $1.decidedAt })
                    loaded.removeFirst(loaded.count - Self.maxRejectionReasons)
                }
                try reasons.save(loaded)
            }
        } catch let error as PendingApprovalError {
            throw error
        } catch let error as FileLockedJSONLStoreError {
            switch error {
            case .lockFailed:
                throw PendingApprovalError.lockFailed
            case .encodeFailed, .ioFailed:
                throw PendingApprovalError.encodeFailed
            }
        } catch {
            throw PendingApprovalError.encodeFailed
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try store.withLock(nonBlocking: false, body)
        } catch let error as FileLockedJSONLStoreError {
            // Only FileLockedJSONLStoreError-originated failures are caught here:
            // the body throws domain errors (writeRecords translates save
            // failures). IO from lock setup collapses into encodeFailed —
            // fail-closed, and both map to ipcError for callers.
            switch error {
            case .lockFailed:
                throw PendingApprovalError.lockFailed
            case .encodeFailed, .ioFailed:
                throw PendingApprovalError.encodeFailed
            }
        }
    }
}

/// Human-supplied rejection reason, keyed by approval id. An annotation
/// on the terminal decision, never authority: enforcement reads the
/// resolved row, reviewers read this for the why.
private struct RejectionReasonRecord: Codable, Sendable {
    var schemaVersion: Int
    var id: String
    var reason: String
    var decidedAt: Date
}

private struct PendingApprovalRecord: Codable, Sendable {
    var schemaVersion: Int
    var approval: PendingApproval
}
