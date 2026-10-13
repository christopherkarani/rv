import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct AllowOnceLedgerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let createdAt = Date(timeIntervalSince1970: 1_699_999_990)

    @Test func mintFreshHashPrunesExpiredAndReusesSameCommandPending() throws {
        let stalePending = Self.record(kind: .pending, hash: "stale", expiresAt: Self.epoch.addingTimeInterval(-1))
        let staleGranted = Self.record(kind: .granted, hash: "oldg", expiresAt: Self.epoch.addingTimeInterval(-1))
        let oldConsumed = Self.record(kind: .consumed, hash: "spent", expiresAt: Self.epoch.addingTimeInterval(-1))
        let livePending = Self.record(kind: .pending, hash: "live", expiresAt: Self.epoch.addingTimeInterval(60))
        let out = try AllowOnceLedger.mint(
            records: [stalePending, staleGranted, oldConsumed, livePending],
            codeHash: "fresh",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600
        )
        guard case .reused(let records) = out else {
            Issue.record("same command+cwd must reuse the live pending")
            return
        }
        #expect(records.map(\.codeHash.rawValue) == ["spent", "live"])
        #expect(records.first?.kind == .consumed)
        #expect(records.last?.kind == .pending)
        #expect(records.last?.codeHash.rawValue == "live")
        #expect(records.last?.commandFingerprint.rawValue == "fp")
        #expect(records.last?.cwd == wd("/tmp/ws"))
    }

    @Test func mintDifferentFingerprintStillAppends() throws {
        let livePending = Self.record(kind: .pending, hash: "live", expiresAt: Self.epoch.addingTimeInterval(60))
        let out = try AllowOnceLedger.mint(
            records: [livePending],
            codeHash: "fresh",
            fingerprint: "other-fp",
            redacted: "gh …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600
        )
        guard case .appended(let records) = out else {
            Issue.record("a different command must mint a new pending")
            return
        }
        #expect(records.map(\.codeHash.rawValue) == ["live", "fresh"])
        #expect(records.last?.commandFingerprint.rawValue == "other-fp")
        #expect(records.last?.createdAt == Self.epoch)
        #expect(records.last?.expiresAt == Self.epoch.addingTimeInterval(3600))
    }

    @Test func mintSameViewDifferentPayloadAppends() throws {
        // M1: same-view commands with different hidden payloads must
        // mint separate rows; the first writer must not win a shared row.
        let live = Self.record(
            kind: .pending, hash: "live", expiresAt: Self.epoch.addingTimeInterval(60),
            payloadDigest: "digest-a"
        )
        let out = try AllowOnceLedger.mint(
            records: [live],
            codeHash: "fresh",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600,
            payloadDigest: "digest-b"
        )
        guard case .appended(let records) = out else {
            Issue.record("a different payload must mint a new pending")
            return
        }
        #expect(records.map(\.codeHash.rawValue) == ["live", "fresh"])
        #expect(records.last?.payloadDigest?.rawValue == "digest-b")
    }

    @Test func mintSameViewSamePayloadReuses() throws {
        let live = Self.record(
            kind: .pending, hash: "live", expiresAt: Self.epoch.addingTimeInterval(60),
            payloadDigest: "digest-a"
        )
        let out = try AllowOnceLedger.mint(
            records: [live],
            codeHash: "fresh",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600,
            payloadDigest: "digest-a"
        )
        guard case .reused(let records) = out else {
            Issue.record("an identical retry must reuse the live pending")
            return
        }
        #expect(records.map(\.codeHash.rawValue) == ["live"])
    }

    @Test func mintLegacyNilDigestReusesOnlyNil() throws {
        let legacy = Self.record(
            kind: .pending, hash: "live", expiresAt: Self.epoch.addingTimeInterval(60)
        )
        #expect(legacy.payloadDigest == nil)
        let bound = try AllowOnceLedger.mint(
            records: [legacy],
            codeHash: "fresh",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600,
            payloadDigest: "digest-a"
        )
        guard case .appended = bound else {
            Issue.record("a bound mint must not reuse a legacy row")
            return
        }
        let again = try AllowOnceLedger.mint(
            records: [legacy],
            codeHash: "fresh",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600
        )
        guard case .reused = again else {
            Issue.record("a legacy retry must reuse the legacy row")
            return
        }
    }

    @Test func mintCollidesWithLivePendingSameHash() {
        let twin = Self.record(
            kind: .pending,
            hash: "dup",
            fingerprint: "other-fp",
            expiresAt: Self.epoch.addingTimeInterval(60)
        )
        #expect(throws: AllowOnceError.collision) {
            _ = try AllowOnceLedger.mint(
                records: [twin],
                codeHash: "dup",
                fingerprint: "fp",
                redacted: "git …",
                cwd: wd("/tmp/ws"),
                ruleID: nil,
                now: Self.epoch,
                ttl: 3600
            )
        }
    }

    @Test func mintExpiredSameHashDoesNotCollide() throws {
        let staleTwin = Self.record(kind: .pending, hash: "dup", expiresAt: Self.epoch.addingTimeInterval(-1))
        let out = try AllowOnceLedger.mint(
            records: [staleTwin],
            codeHash: "dup",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600
        )
        guard case .appended(let records) = out else {
            Issue.record("expired pending must not block a remint")
            return
        }
        #expect(records.map(\.kind) == [.pending])
        #expect(records.map(\.codeHash.rawValue) == ["dup"])
        #expect(records.first?.expiresAt == Self.epoch.addingTimeInterval(3600))
    }

    @Test func redeemGrantsPendingAndPrunesStaleSiblings() throws {
        let target = Self.record(kind: .pending, hash: "hit", expiresAt: Self.epoch.addingTimeInterval(60))
        let stalePending = Self.record(kind: .pending, hash: "p2", expiresAt: Self.epoch.addingTimeInterval(-1))
        let staleGranted = Self.record(kind: .granted, hash: "g3", expiresAt: Self.epoch.addingTimeInterval(-1))
        switch try AllowOnceLedger.redeem(records: [target, stalePending, staleGranted], codeHash: "hit", now: Self.epoch) {
        case let .granted(records, row):
            #expect(records.map(\.codeHash.rawValue) == ["hit"])
            #expect(records.map(\.kind) == [.granted])
            #expect(row == AllowOnceListRow(
                kind: .granted,
                codeHash: "hit",
                commandRedacted: target.commandRedacted,
                cwd: wd("/tmp/ws"),
                createdAt: Self.createdAt,
                expiresAt: Self.epoch.addingTimeInterval(60)
            ))
        case .expired:
            Issue.record("valid pending must redeem to granted")
        }
    }

    @Test func redeemExpiredPendingReturnsRecordsWithoutItForWrite() throws {
        let stale = Self.record(kind: .pending, hash: "old", expiresAt: Self.epoch.addingTimeInterval(-1))
        let live = Self.record(kind: .pending, hash: "new", expiresAt: Self.epoch.addingTimeInterval(60))
        switch try AllowOnceLedger.redeem(records: [stale, live], codeHash: "old", now: Self.epoch) {
        case let .expired(records):
            #expect(records.map(\.codeHash.rawValue) == ["new"])
        case .granted:
            Issue.record("expired pending must not redeem")
        }
    }

    @Test func redeemExpiredPendingRemovesOnlyThatRow() throws {
        let target = Self.record(kind: .pending, hash: "old", expiresAt: Self.epoch.addingTimeInterval(-1))
        let expiredGranted = Self.record(kind: .granted, hash: "g", expiresAt: Self.epoch.addingTimeInterval(-2))
        let expiredOtherPending = Self.record(kind: .pending, hash: "p2", expiresAt: Self.epoch.addingTimeInterval(-3))
        switch try AllowOnceLedger.redeem(
            records: [expiredGranted, target, expiredOtherPending],
            codeHash: "old",
            now: Self.epoch
        ) {
        case let .expired(records):
            #expect(records.map(\.codeHash.rawValue) == ["g", "p2"])
        case .granted:
            Issue.record("expired pending must not redeem")
        }
    }

    @Test func redeemSpentHashesThrowAlreadySpent() {
        let granted = Self.record(kind: .granted, hash: "spent", expiresAt: Self.epoch.addingTimeInterval(60))
        let consumedPastExpiry = Self.record(kind: .consumed, hash: "gone", expiresAt: Self.epoch.addingTimeInterval(-5))
        #expect(throws: AllowOnceError.alreadySpent) {
            _ = try AllowOnceLedger.redeem(records: [granted], codeHash: "spent", now: Self.epoch)
        }
        #expect(throws: AllowOnceError.alreadySpent) {
            _ = try AllowOnceLedger.redeem(records: [consumedPastExpiry], codeHash: "gone", now: Self.epoch)
        }
    }

    @Test func redeemUnknownHashThrowsUnknownCode() {
        let unrelated = Self.record(kind: .pending, hash: "other", fingerprint: "fp", expiresAt: Self.epoch.addingTimeInterval(60))
        #expect(throws: AllowOnceError.unknownCode) {
            _ = try AllowOnceLedger.redeem(records: [unrelated], codeHash: "zzzz", now: Self.epoch)
        }
        #expect(throws: AllowOnceError.unknownCode) {
            _ = try AllowOnceLedger.redeem(records: [], codeHash: "zzzz", now: Self.epoch)
        }
    }

    @Test func rowsKeepLiveAndConsumedPastExpiryDropOthers() {
        let livePending = Self.record(kind: .pending, hash: "p", expiresAt: Self.epoch.addingTimeInterval(60))
        let liveGranted = Self.record(kind: .granted, hash: "g", expiresAt: Self.epoch.addingTimeInterval(120))
        let expiredPending = Self.record(kind: .pending, hash: "ep", expiresAt: Self.epoch.addingTimeInterval(-1))
        let oldConsumed = Self.record(
            kind: .consumed,
            hash: "oc",
            expiresAt: Self.epoch.addingTimeInterval(-100),
            consumedAt: Self.epoch.addingTimeInterval(-200)
        )
        let rows = AllowOnceLedger.rows(
            records: [livePending, expiredPending, liveGranted, oldConsumed],
            now: Self.epoch
        )
        #expect(rows.count == 3)
        #expect(rows[0] == AllowOnceListRow(
            kind: .pending,
            codeHash: "p",
            commandRedacted: livePending.commandRedacted,
            cwd: wd("/tmp/ws"),
            createdAt: Self.createdAt,
            expiresAt: Self.epoch.addingTimeInterval(60)
        ))
        #expect(rows.map(\.codeHash) == ["p", "g", "oc"])
    }

    @Test func rowsProjectDenyRuleID() throws {
        var denied = Self.record(
            kind: .pending, hash: "p", expiresAt: Self.epoch.addingTimeInterval(60))
        denied.ruleID = RuleID(pack: PackID(rawValue: "core.git"), pattern: "reset-hard")
        let rows = AllowOnceLedger.rows(records: [denied], now: Self.epoch)
        #expect(rows.map(\.ruleID) == [denied.ruleID])
    }

    @Test func exactNowIsExpired() throws {
        let pending = Self.record(kind: .pending, hash: "p", expiresAt: Self.epoch)
        let other = Self.record(
            kind: .pending,
            hash: "p",
            fingerprint: "other-fp",
            expiresAt: Self.epoch
        )
        // No collision: the same-code row is already expired, so the mint
        // appends a fresh row instead of throwing.
        let minted = try AllowOnceLedger.mint(
            records: [other],
            codeHash: "p",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600
        )
        guard case .appended(let fresh) = minted else {
            Issue.record("exact-now mint over an expired row must append")
            return
        }
        #expect(fresh.map(\.codeHash.rawValue) == ["p"])
        // No reuse: the same-command row is expired, so a fresh row mints.
        let second = try AllowOnceLedger.mint(
            records: [pending],
            codeHash: "fresh",
            fingerprint: "fp",
            redacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: Self.epoch,
            ttl: 3600
        )
        guard case .appended(let records) = second else {
            Issue.record("exact-now pending for the same command must not be reused")
            return
        }
        #expect(records.map(\.codeHash.rawValue) == ["fresh"])
        switch try AllowOnceLedger.redeem(records: [pending], codeHash: "p", now: Self.epoch) {
        case .expired(let expired):
            #expect(expired.isEmpty)
        case .granted:
            Issue.record("expiresAt == now must expire")
        }
        #expect(AllowOnceLedger.rows(records: [pending], now: Self.epoch).isEmpty)
        let consumed = Self.record(
            kind: .consumed,
            hash: "c",
            expiresAt: Self.epoch,
            consumedAt: Self.createdAt
        )
        #expect(AllowOnceLedger.keepConsumed(records: [consumed], now: Self.epoch).isEmpty)
    }

    @Test func keepConsumedRetainsOnlyFreshConsumedForClear() {
        let freshConsumed = Self.record(kind: .consumed, hash: "keep", expiresAt: Self.epoch.addingTimeInterval(30))
        let staleConsumed = Self.record(kind: .consumed, hash: "drop-old", expiresAt: Self.epoch.addingTimeInterval(-1))
        let liveGranted = Self.record(kind: .granted, hash: "grant", expiresAt: Self.epoch.addingTimeInterval(30))
        let out = AllowOnceLedger.keepConsumed(
            records: [freshConsumed, staleConsumed, liveGranted],
            now: Self.epoch
        )
        #expect(out.map(\.codeHash.rawValue) == ["keep"])
    }

    @Test func cappedPassesThroughUnderTheCap() {
        let rows = (0..<4).map { Self.stampedRecord(hash: "h\($0)", createdAt: Self.epoch.addingTimeInterval(Double($0))) }
        let out = AllowOnceLedger.capped(records: rows, maxRows: 4)
        #expect(out.map(\.codeHash.rawValue) == ["h0", "h1", "h2", "h3"])
    }

    @Test func cappedKeepsNewestRowsInOrder() {
        let rows = (0..<6).map { Self.stampedRecord(hash: "h\($0)", createdAt: Self.epoch.addingTimeInterval(Double($0))) }
        let out = AllowOnceLedger.capped(records: rows, maxRows: 4)
        #expect(out.map(\.codeHash.rawValue) == ["h2", "h3", "h4", "h5"])
    }
}

private extension AllowOnceLedgerTests {
    static func stampedRecord(hash: String, createdAt: Date) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: .pending,
            codeHash: CodeHash(rawValue: hash),
            commandFingerprint: GrantFingerprint(rawValue: "fp-\(hash)"),
            commandRedacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3600)
        )
    }
    static func record(
        kind: AllowOnceRecord.Kind,
        hash: String,
        fingerprint: String = "fp",
        expiresAt: Date,
        consumedAt: Date? = nil,
        payloadDigest: String? = nil
    ) -> AllowOnceRecord {
        let lifecycle: AllowOnceLifecycle
        switch kind {
        case .pending:
            lifecycle = .pending
        case .granted:
            lifecycle = .granted
        case .consumed:
            lifecycle = .consumed(at: consumedAt ?? createdAt)
        }
        return AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: lifecycle,
            codeHash: CodeHash(rawValue: hash),
            commandFingerprint: GrantFingerprint(rawValue: fingerprint),
            commandRedacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            createdAt: createdAt,
            expiresAt: expiresAt,
            payloadDigest: payloadDigest.map(ContentPayloadDigest.init(rawValue:))
        )
    }
}
