import Darwin
import Foundation
import RVDomain

/// Durable pending-approval source of truth. Survives process restart.
public actor PendingApprovalStore: PendingApprovalCoordinating {
    nonisolated public let baseDirectory: URL

    private var subscribers: [UUID: AsyncStream<PendingApprovalEvent>.Continuation] = [:]

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    nonisolated public static func live(home: HomeDirectory) -> PendingApprovalStore {
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

    public func record(id: ApprovalID, now: Date) async throws -> PendingApproval {
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

    private var fileURL: URL {
        RVPolicyPaths.pendingApprovalsFile(inConfigDir: baseDirectory)
    }

    private var lockURL: URL {
        RVPolicyPaths.pendingApprovalsLockFile(inConfigDir: baseDirectory)
    }

    private func loadRecords() -> [PendingApproval] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard raw.isEmpty == false, let lineData = raw.data(using: .utf8) else {
                return nil
            }
            guard let record = try? decoder.decode(PendingApprovalRecord.self, from: lineData),
                  record.schemaVersion == 1
            else {
                return nil
            }
            return record.approval
        }
    }

    private func writeRecords(_ records: [PendingApproval]) throws {
        try prepareStoreDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = try records.map { approval -> String in
            let data: Data
            do {
                data = try encoder.encode(
                    PendingApprovalRecord(schemaVersion: 1, approval: approval)
                )
            } catch {
                throw PendingApprovalError.encodeFailed
            }
            guard let line = String(data: data, encoding: .utf8) else {
                throw PendingApprovalError.encodeFailed
            }
            return line
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let temp = fileURL.appendingPathExtension("tmp")
        do {
            try body.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            throw PendingApprovalError.encodeFailed
        }
        try setOwnerOnlyFile(temp)
        let renamed: Int32 = fileURL.withUnsafeFileSystemRepresentation { dest in
            temp.withUnsafeFileSystemRepresentation { src in
                guard let dest, let src else { return Int32(-1) }
                return rename(src, dest)
            }
        }
        if renamed != 0 {
            throw PendingApprovalError.encodeFailed
        }
        try setOwnerOnlyFile(fileURL)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try prepareStoreDirectory()
        do {
            return try ExclusiveFileLock.withLock(at: lockURL, body)
        } catch let error as ExclusiveFileLock.LockError {
            switch error {
            case .lockFailed:
                throw PendingApprovalError.lockFailed
            }
        }
    }

    private func prepareStoreDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: baseDirectory.path
        )
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct PendingApprovalRecord: Codable {
    var schemaVersion: Int
    var approval: PendingApproval
}
