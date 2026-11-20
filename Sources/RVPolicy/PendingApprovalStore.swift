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

    /// Every row after the timeout sweep, terminal rows included: one
    /// consistent snapshot read under the store lock. Review displays
    /// derive from it so what is shown and what is bound agree.
    public func records(now: Date) async throws(PendingApprovalError) -> [PendingApproval] {
        try persistSweep(now: now)
    }

    /// `resolve`, but only while `stillHolds` is true for the swept
    /// ledger. The check runs inside the same file lock as the write, so
    /// no other resolve can land between check and write. Returns nil and
    /// writes nothing when the check fails.
    ///
    /// The ledger's own refusals come first, so `stillHolds` judges only a
    /// readable ledger in which the row still awaits: an unreadable file
    /// throws `encodeFailed` (never an empty ledger), and an unknown,
    /// resolved, expired or timed-out row throws its usual error.
    public func resolve(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date,
        onlyIf stillHolds: @Sendable ([PendingApproval]) -> Bool
    ) async throws(PendingApprovalError) -> PendingApproval? {
        let outcome: (PendingApproval, [PendingApprovalEvent])?
        do {
            outcome = try withFileLock {
                let loaded = try store.loadChecked().filter { $0.schemaVersion == 1 }.map(\.approval)
                let (record, next) = try PendingApprovalLedger.resolve(
                    records: loaded,
                    id: id,
                    decision: decision,
                    fingerprint: fingerprint,
                    identity: identity,
                    now: now
                )
                guard stillHolds(PendingApprovalLedger.sweep(loaded, now: now)) else { return nil }
                try writeRecords(next)
                return (record, timeoutEvents(before: loaded, after: next) + [.resolved(record)])
            }
        } catch let error as PendingApprovalError {
            throw error
        } catch {
            throw PendingApprovalError.lockFailed
        }
        guard let outcome else { return nil }
        publish(outcome.1)
        return outcome.0
    }

    /// Record a human decision exactly once. Unbound: network (egress)
    /// approvals must use `resolve(…, onlyIf:)` with their review token
    /// (`EgressReview`), so an approval cannot apply against grant state
    /// the owner never saw.
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

    /// What this instance last read or wrote, keyed by the rows file's
    /// stamp. Every hook ask records a row under the exclusive file lock, so
    /// decoding and re-encoding the whole file each time made asks queue
    /// behind each other and grow slower with the file (14 ms per ask at 120
    /// rows on a 4-vCPU Linux host, ~100 ms at 8 agents at once). Any other
    /// writer (the CLI's approve, another process) changes the stamp, so its
    /// rows are read on the next call. Same scheme as `AllowOnceStore`.
    private struct LedgerCache {
        var stamp: FileStamp
        var records: [PendingApproval]
        /// `lines[i]` is `records[i]` as saved, when this instance wrote the
        /// file. Nil after a plain load: the file may then hold rows `load`
        /// skipped (corrupt, torn or another schema), which only a rewrite
        /// drops, and an append must not follow a torn last line.
        var lines: [String]?
    }

    private var ledgerCache: LedgerCache?

    private func loadRecords() -> [PendingApproval] {
        let stamp = store.stamp()
        if let stamp, let cache = ledgerCache, cache.stamp == stamp {
            return cache.records
        }
        let records = store.load().filter { $0.schemaVersion == 1 }.map(\.approval)
        // Stamp taken before the read: a write racing the read changes the
        // stamp, so the next load reads again rather than trusting this one.
        ledgerCache = stamp.map { LedgerCache(stamp: $0, records: records, lines: nil) }
        return records
    }

    private func writeRecords(_ records: [PendingApproval]) throws(PendingApprovalError) {
        do {
            if let current = store.stamp(), let cache = ledgerCache, cache.stamp == current,
               var lines = cache.lines, lines.count == cache.records.count
            {
                // The file is exactly what this instance last wrote.
                if cache.records == records {
                    // A repeated ask reuses its waiting row: nothing to write.
                    return
                }
                if records.count == cache.records.count + 1,
                   records.dropLast().elementsEqual(cache.records),
                   let added = records.last
                {
                    // A fresh ask appends one row: append its line instead of
                    // rewriting them all.
                    let line = try Self.encodeLine(added)
                    ledgerCache = nil
                    try store.append(line: line)
                    lines.append(line)
                    ledgerCache = store.stamp().map { LedgerCache(stamp: $0, records: records, lines: lines) }
                    return
                }
            }
            let lines = try encodedLines(for: records, reusing: ledgerCache)
            ledgerCache = nil
            try store.save(lines: lines)
            ledgerCache = store.stamp().map { LedgerCache(stamp: $0, records: records, lines: lines) }
        } catch {
            ledgerCache = nil
            // RVFileStore boundary: every save failure (encode or IO) becomes
            // the domain persistence error, so withFileLock only ever sees
            // lock-acquisition or lock-setup failures (FileLockedJSONLStoreError),
            // never untranslated save failures.
            throw PendingApprovalError.encodeFailed
        }
    }

    private static func encodeLine(
        _ approval: PendingApproval,
        encoder: JSONEncoder = FileLockedJSONLStore<PendingApprovalRecord>.lineEncoder()
    ) throws(FileLockedJSONLStoreError) -> String {
        try FileLockedJSONLStore<PendingApprovalRecord>.encodeLine(
            PendingApprovalRecord(schemaVersion: 1, approval: approval), encoder: encoder)
    }

    /// Saved lines for `records`, re-encoding only rows the cache does not
    /// hold verbatim (matched by full equality). Ledger transitions keep row
    /// order (sweep flips states in place, create appends), so a forward
    /// merge against the cached rows finds each reusable line; a row it does
    /// not find nearby is encoded again.
    private func encodedLines(
        for records: [PendingApproval],
        reusing cache: LedgerCache?
    ) throws(FileLockedJSONLStoreError) -> [String] {
        let cachedRecords = cache?.records ?? []
        let cachedLines = cache?.lines ?? []
        let reusable = cachedLines.count == cachedRecords.count ? cachedRecords.count : 0
        let encoder = FileLockedJSONLStore<PendingApprovalRecord>.lineEncoder()
        var lines: [String] = []
        lines.reserveCapacity(records.count)
        var cursor = 0
        for record in records {
            var hit: Int?
            var probe = cursor
            while probe < min(reusable, cursor + 64) {
                if cachedRecords[probe] == record {
                    hit = probe
                    break
                }
                probe += 1
            }
            if let hit {
                lines.append(cachedLines[hit])
                cursor = hit + 1
            } else {
                lines.append(try Self.encodeLine(record, encoder: encoder))
            }
        }
        return lines
    }

    /// Maximum retained rejection reasons. Past the cap the oldest
    /// records evict; the terminal decisions they annotated stand.
    private static let maxRejectionReasons = 1024

    private static func rejectionReasonsFile(inConfigDir configDir: URL) -> URL {
        RVPolicyPaths.pendingRejectionReasonsFile(inConfigDir: configDir)
    }

    private static func rejectionReasonsLockFile(inConfigDir configDir: URL) -> URL {
        RVPolicyPaths.pendingRejectionReasonsLockFile(inConfigDir: configDir)
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
