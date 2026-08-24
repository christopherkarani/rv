import Foundation
import RVDomain

enum AllowOnceLedger {
    enum RedeemOutcome: Equatable, Sendable {
        case granted(records: [AllowOnceRecord], row: AllowOnceListRow)
        case expired(records: [AllowOnceRecord])
    }

    enum ConsumeOutcome: Equatable, Sendable {
        case consumed(tokenID: String, records: [AllowOnceRecord])
        case expired([AllowOnceRecord])
        case alreadyConsumed
        case notFound
    }

    static func mint(
        records: [AllowOnceRecord],
        codeHash: String,
        fingerprint: String,
        redacted: String,
        cwd: String,
        ruleID: RuleID?,
        now: Date,
        ttl: TimeInterval
    ) throws(AllowOnceError) -> [AllowOnceRecord] {
        var updated = records.filter { $0.expiresAt >= now || $0.kind == .consumed }
        if updated.contains(where: {
            $0.kind == .pending && $0.codeHash == codeHash && $0.expiresAt >= now
        }) {
            throw AllowOnceError.collision
        }
        updated.append(
            AllowOnceRecord(
                schemaVersion: 1,
                kind: .pending,
                codeHash: codeHash,
                commandFingerprint: fingerprint,
                commandRedacted: redacted,
                cwd: cwd,
                ruleID: ruleID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(ttl),
                consumedAt: nil
            )
        )
        return updated
    }

    static func redeem(
        records: [AllowOnceRecord],
        codeHash: String,
        now: Date
    ) throws(AllowOnceError) -> RedeemOutcome {
        guard let index = records.firstIndex(where: {
            $0.kind == .pending && $0.codeHash == codeHash
        }) else {
            if records.contains(where: {
                ($0.kind == .granted || $0.kind == .consumed) && $0.codeHash == codeHash
            }) {
                throw AllowOnceError.alreadySpent
            }
            throw AllowOnceError.unknownCode
        }
        var pending = records[index]
        guard pending.expiresAt >= now else {
            var updated = records
            updated.remove(at: index)
            return .expired(records: updated)
        }
        pending.kind = .granted
        var updated = records
        updated[index] = pending
        updated.removeAll {
            ($0.kind == .pending || $0.kind == .granted) && $0.expiresAt < now
        }
        return .granted(records: updated, row: row(pending))
    }

    static func consume(
        records: [AllowOnceRecord],
        fingerprint: String,
        cwd: String,
        now: Date
    ) -> ConsumeOutcome {
        let related = records.indices.filter {
            records[$0].commandFingerprint == fingerprint && records[$0].cwd == cwd
        }
        if let index = related.first(where: {
            records[$0].kind == .granted && records[$0].expiresAt >= now
        }) {
            var granted = records[index]
            granted.kind = .consumed
            granted.consumedAt = now
            var updated = records
            updated[index] = granted
            updated.removeAll { $0.kind == .granted && $0.expiresAt < now }
            return .consumed(tokenID: granted.codeHash, records: updated)
        }
        let hadExpiredGrant = related.contains {
            records[$0].kind == .granted && records[$0].expiresAt < now
        }
        if hadExpiredGrant {
            var updated = records
            updated.removeAll { $0.kind == .granted && $0.expiresAt < now }
            return .expired(updated)
        }
        if related.contains(where: { records[$0].kind == .consumed }) {
            return .alreadyConsumed
        }
        return .notFound
    }

    static func rows(records: [AllowOnceRecord], now: Date) -> [AllowOnceListRow] {
        records.compactMap { record in
            guard record.expiresAt >= now || record.kind == .consumed else { return nil }
            return row(record)
        }
    }

    static func keepConsumed(records: [AllowOnceRecord], now: Date) -> [AllowOnceRecord] {
        records.filter { record in
            record.kind == .consumed && record.expiresAt >= now
        }
    }

    private static func row(_ record: AllowOnceRecord) -> AllowOnceListRow {
        AllowOnceListRow(
            kind: record.kind,
            codeHash: record.codeHash,
            commandRedacted: record.commandRedacted,
            cwd: record.cwd,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt
        )
    }
}
