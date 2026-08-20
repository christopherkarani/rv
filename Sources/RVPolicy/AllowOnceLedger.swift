import Foundation
import RVDomain

/// Pure grant matching / spend rules. Persistence, locks, and ID minting stay in `AllowOnceStore`.
enum AllowOnceLedger {
    struct ConsumeResult: Equatable, Sendable {
        var status: AllowOnceConsumeStatus
        var records: [AllowOnceRecord]
    }

    static func hasGrant(
        records: [AllowOnceRecord],
        matchingView: MatchingView,
        cwd: String,
        now: Date
    ) -> Bool {
        let fingerprint = commandFingerprint(matchingView)
        return records.contains {
            $0.kind == .granted
                && $0.commandFingerprint == fingerprint
                && $0.cwd == cwd
                && $0.expiresAt >= now
        }
    }

    static func consume(
        records: [AllowOnceRecord],
        matchingView: MatchingView,
        cwd: String,
        now: Date
    ) -> ConsumeResult {
        let fingerprint = commandFingerprint(matchingView)
        var records = records
        let related = records.indices.filter {
            records[$0].commandFingerprint == fingerprint && records[$0].cwd == cwd
        }
        if let index = related.first(where: {
            records[$0].kind == .granted && records[$0].expiresAt >= now
        }) {
            var granted = records[index]
            granted.kind = .consumed
            granted.consumedAt = now
            records[index] = granted
            records.removeAll {
                $0.kind == .granted && $0.expiresAt < now
            }
            return ConsumeResult(status: .consumed(tokenID: granted.codeHash), records: records)
        }
        let hadExpiredGrant = related.contains {
            records[$0].kind == .granted && records[$0].expiresAt < now
        }
        if hadExpiredGrant {
            records.removeAll {
                $0.kind == .granted && $0.expiresAt < now
            }
            return ConsumeResult(status: .expired, records: records)
        }
        if related.contains(where: { records[$0].kind == .consumed }) {
            return ConsumeResult(status: .alreadyConsumed, records: records)
        }
        return ConsumeResult(status: .notFound, records: records)
    }

    static func makeGranted(
        matchingView: MatchingView,
        cwd: String,
        now: Date,
        ttl: TimeInterval,
        codeHash: String
    ) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            kind: .granted,
            codeHash: codeHash,
            commandFingerprint: commandFingerprint(matchingView),
            commandRedacted: "[redacted]",
            cwd: cwd,
            ruleID: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            consumedAt: nil
        )
    }
}
