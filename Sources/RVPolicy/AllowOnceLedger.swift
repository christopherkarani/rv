import Foundation
import RVDomain

enum AllowOnceLedger {
    enum MintResult: Equatable, Sendable {
        case appended([AllowOnceRecord])
        case reused([AllowOnceRecord])

        var records: [AllowOnceRecord] {
            switch self {
            case .appended(let records), .reused(let records):
                return records
            }
        }
    }

    enum RedeemOutcome: Equatable, Sendable {
        case granted(records: [AllowOnceRecord], row: AllowOnceListRow)
        case expired(records: [AllowOnceRecord])
    }

    static func mint(
        records: [AllowOnceRecord],
        codeHash: String,
        fingerprint: String,
        redacted: String,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        now: Date,
        ttl: TimeInterval,
        payloadDigest: String? = nil,
        invocationDisplay: String? = nil
    ) throws(AllowOnceError) -> MintResult {
        let updated = prepare(records, now: now)
        if existingPending(in: updated, fingerprint: fingerprint, cwd: cwd) != nil {
            return .reused(updated)
        }
        if updated.contains(where: { record in
            guard case .pending = record.lifecycle else { return false }
            return record.codeHash == codeHash && record.expiresAt >= now
        }) {
            throw AllowOnceError.collision
        }
        var appended = updated
        appended.append(
            AllowOnceRecord(
                schemaVersion: 1,
                lifecycle: .pending,
                codeHash: codeHash,
                commandFingerprint: fingerprint,
                commandRedacted: redacted,
                cwd: cwd,
                ruleID: ruleID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(ttl),
                payloadDigest: payloadDigest,
                invocationDisplay: invocationDisplay
            )
        )
        return .appended(appended)
    }

    static func prepare(_ records: [AllowOnceRecord], now: Date) -> [AllowOnceRecord] {
        records.filter { record in
            switch record.lifecycle {
            case .consumed:
                return true
            case .pending, .granted:
                return record.expiresAt >= now
            }
        }
    }

    static func existingPending(
        in records: [AllowOnceRecord],
        fingerprint: String,
        cwd: WorkingDirectory
    ) -> AllowOnceRecord? {
        records.first { record in
            guard case .pending = record.lifecycle else { return false }
            return record.commandFingerprint == fingerprint && record.cwd == cwd
        }
    }

    /// Read-only lookup of a live pending row by code hash. Nil for unknown,
    /// spent, or expired codes. Used to pre-display the grant in the redeem
    /// ceremony (B-F6); granting still goes through `redeem`.
    static func pendingRow(
        in records: [AllowOnceRecord],
        codeHash: String,
        now: Date
    ) -> AllowOnceRecord? {
        records.first { record in
            guard case .pending = record.lifecycle else { return false }
            guard record.codeHash == codeHash else { return false }
            return record.expiresAt >= now
        }
    }

    static func redeem(
        records: [AllowOnceRecord],
        codeHash: String,
        now: Date,
        expectedFingerprint: String? = nil,
        expectedPayloadDigest: String? = nil
    ) throws(AllowOnceError) -> RedeemOutcome {
        guard let index = records.firstIndex(where: { record in
            guard case .pending = record.lifecycle else { return false }
            return record.codeHash == codeHash
        }) else {
            if records.contains(where: { record in
                switch record.lifecycle {
                case .granted, .consumed:
                    return record.codeHash == codeHash
                case .pending:
                    return false
                }
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
        if let expectedFingerprint, pending.commandFingerprint != expectedFingerprint {
            throw AllowOnceError.redemptionChanged
        }
        if let expectedPayloadDigest, pending.payloadDigest != expectedPayloadDigest {
            throw AllowOnceError.redemptionChanged
        }
        pending.lifecycle = .granted
        var updated = records
        updated[index] = pending
        updated.removeAll { record in
            switch record.lifecycle {
            case .pending, .granted:
                return record.expiresAt < now
            case .consumed:
                return false
            }
        }
        return .granted(records: updated, row: row(pending))
    }

    static func rows(records: [AllowOnceRecord], now: Date) -> [AllowOnceListRow] {
        records.compactMap { record in
            switch record.lifecycle {
            case .consumed:
                break
            case .pending, .granted:
                guard record.expiresAt >= now else { return nil }
            }
            return row(record)
        }
    }

    static func keepConsumed(records: [AllowOnceRecord], now: Date) -> [AllowOnceRecord] {
        records.filter { record in
            guard case .consumed = record.lifecycle else { return false }
            return record.expiresAt >= now
        }
    }

    /// Hard row cap for the projection file. Under the cap the list passes
    /// through untouched; over it the newest rows by creation survive and
    /// the oldest are dropped. Newest-first keeps live ceremonies (just
    /// minted) while shedding stale history: a dropped pending row fails
    /// closed at redeem (`unknownCode`), and a same-user attacker flooding
    /// rows can already delete the file outright. Callers apply this on
    /// every write so the file can never grow past `maxRows`.
    static func capped(
        records: [AllowOnceRecord],
        maxRows: Int
    ) -> [AllowOnceRecord] {
        guard records.count > maxRows else { return records }
        return Array(
            records
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(maxRows)
                .reversed()
        )
    }

    private static func row(_ record: AllowOnceRecord) -> AllowOnceListRow {
        AllowOnceListRow(
            kind: record.kind,
            codeHash: record.codeHash,
            commandRedacted: record.commandRedacted,
            cwd: record.cwd,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            ruleID: record.ruleID,
            invocationDisplay: record.invocationDisplay
        )
    }
}
