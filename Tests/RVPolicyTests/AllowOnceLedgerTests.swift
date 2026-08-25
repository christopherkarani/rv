import Foundation
import Testing
@testable import RVPolicy

struct AllowOnceLedgerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let createdAt = Date(timeIntervalSince1970: 1_699_999_990)

    @Test func mintFreshHashPrunesExpiredAndAppendsPending() throws {
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
        #expect(out.map(\.codeHash) == ["spent", "live", "fresh"])
        #expect(out.first?.kind == .consumed)
        #expect(out.last?.kind == .pending)
        #expect(out.last?.createdAt == Self.epoch)
        #expect(out.last?.expiresAt == Self.epoch.addingTimeInterval(3600))
        #expect(out.last?.commandFingerprint == "fp")
        #expect(out.last?.cwd == wd("/tmp/ws"))
    }

    @Test func mintCollidesWithLivePendingSameHash() {
        let twin = Self.record(kind: .pending, hash: "dup", expiresAt: Self.epoch.addingTimeInterval(60))
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
        #expect(out.map(\.kind) == [.pending])
        #expect(out.map(\.codeHash) == ["dup"])
        #expect(out.first?.expiresAt == Self.epoch.addingTimeInterval(3600))
    }

    @Test func redeemGrantsPendingAndPrunesStaleSiblings() throws {
        let target = Self.record(kind: .pending, hash: "hit", expiresAt: Self.epoch.addingTimeInterval(60))
        let stalePending = Self.record(kind: .pending, hash: "p2", expiresAt: Self.epoch.addingTimeInterval(-1))
        let staleGranted = Self.record(kind: .granted, hash: "g3", expiresAt: Self.epoch.addingTimeInterval(-1))
        switch try AllowOnceLedger.redeem(records: [target, stalePending, staleGranted], codeHash: "hit", now: Self.epoch) {
        case let .granted(records, row):
            #expect(records.map(\.codeHash) == ["hit"])
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
            #expect(records.map(\.codeHash) == ["new"])
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
            #expect(records.map(\.codeHash) == ["g", "p2"])
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

    @Test func consumeFreshGrantWinsAndPrunesExpiredGrants() {
        let fresh = Self.record(kind: .granted, hash: "tok", expiresAt: Self.epoch.addingTimeInterval(60))
        let expiredSibling = Self.record(kind: .granted, hash: "old", expiresAt: Self.epoch.addingTimeInterval(-1))
        let consumedSibling = Self.record(
            kind: .consumed,
            hash: "done",
            expiresAt: Self.epoch.addingTimeInterval(-10),
            consumedAt: Self.epoch.addingTimeInterval(-20)
        )
        switch AllowOnceLedger.consume(
            records: [expiredSibling, consumedSibling, fresh],
            fingerprint: "fp",
            cwd: wd("/tmp/ws"),
            now: Self.epoch
        ) {
        case let .consumed(tokenID, records):
            #expect(tokenID == "tok")
            #expect(records.map(\.codeHash) == ["done", "tok"])
            #expect(records.last?.kind == .consumed)
            #expect(records.last?.consumedAt == Self.epoch)
        case .expired, .alreadyConsumed, .notFound:
            Issue.record("valid grant must consume")
        }
    }

    @Test func consumeOnlyExpiredGrantReportsExpiredWithPrunedRecords() {
        let staleA = Self.record(kind: .granted, hash: "a", expiresAt: Self.epoch.addingTimeInterval(-1))
        let staleB = Self.record(kind: .granted, hash: "b", expiresAt: Self.epoch.addingTimeInterval(-2))
        let otherView = Self.record(kind: .granted, hash: "c", fingerprint: "other-fp", expiresAt: Self.epoch.addingTimeInterval(60))
        let outcome = AllowOnceLedger.consume(
            records: [staleA, otherView, staleB],
            fingerprint: "fp",
            cwd: wd("/tmp/ws"),
            now: Self.epoch
        )
        #expect(outcome == .expired([otherView]))
    }

    @Test func consumeExpiredGrantBeatsAlreadyConsumed() {
        let expiredGrant = Self.record(kind: .granted, hash: "old", expiresAt: Self.epoch.addingTimeInterval(-1))
        let spentBefore = Self.record(
            kind: .consumed,
            hash: "done",
            expiresAt: Self.epoch.addingTimeInterval(60),
            consumedAt: Self.epoch.addingTimeInterval(-30)
        )
        let outcome = AllowOnceLedger.consume(
            records: [expiredGrant, spentBefore],
            fingerprint: "fp",
            cwd: wd("/tmp/ws"),
            now: Self.epoch
        )
        guard case let .expired(records) = outcome else {
            Issue.record("expired grant must take precedence over consumed history")
            return
        }
        #expect(records.map(\.codeHash) == ["done"])
    }

    @Test func consumeRelatedConsumedIsAlreadyConsumed() {
        let spent = Self.record(
            kind: .consumed,
            hash: "done",
            expiresAt: Self.epoch.addingTimeInterval(60),
            consumedAt: Self.epoch.addingTimeInterval(-5)
        )
        let outcome = AllowOnceLedger.consume(records: [spent], fingerprint: "fp", cwd: wd("/tmp/ws"), now: Self.epoch)
        #expect(outcome == .alreadyConsumed)
    }

    @Test func consumeWrongCwdOrFingerprintIsNotFound() {
        let grant = Self.record(kind: .granted, hash: "tok", expiresAt: Self.epoch.addingTimeInterval(60))
        let wrongCwd = AllowOnceLedger.consume(records: [grant], fingerprint: "fp", cwd: wd("/tmp/other"), now: Self.epoch)
        #expect(wrongCwd == .notFound)
        let wrongFingerprint = AllowOnceLedger.consume(
            records: [grant],
            fingerprint: "other-fp",
            cwd: wd("/tmp/ws"),
            now: Self.epoch
        )
        #expect(wrongFingerprint == .notFound)
        #expect(AllowOnceLedger.consume(records: [], fingerprint: "fp", cwd: wd("/tmp/ws"), now: Self.epoch) == .notFound)
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

    @Test func exactNowIsStillLive() throws {
        let pending = Self.record(kind: .pending, hash: "p", expiresAt: Self.epoch)
        #expect(throws: AllowOnceError.collision) {
            _ = try AllowOnceLedger.mint(
                records: [pending],
                codeHash: "p",
                fingerprint: "fp",
                redacted: "git …",
                cwd: wd("/tmp/ws"),
                ruleID: nil,
                now: Self.epoch,
                ttl: 3600
            )
        }
        switch try AllowOnceLedger.redeem(records: [pending], codeHash: "p", now: Self.epoch) {
        case let .granted(records, _):
            #expect(records.map(\.kind) == [.granted])
        case .expired:
            Issue.record("expiresAt == now must redeem")
        }
        let granted = Self.record(kind: .granted, hash: "g", expiresAt: Self.epoch)
        switch AllowOnceLedger.consume(
            records: [granted],
            fingerprint: "fp",
            cwd: wd("/tmp/ws"),
            now: Self.epoch
        ) {
        case let .consumed(tokenID, records):
            #expect(tokenID == "g")
            #expect(records.map(\.kind) == [.consumed])
        case .expired, .alreadyConsumed, .notFound:
            Issue.record("expiresAt == now must consume")
        }
        #expect(AllowOnceLedger.rows(records: [pending], now: Self.epoch).map(\.codeHash) == ["p"])
        let consumed = Self.record(
            kind: .consumed,
            hash: "c",
            expiresAt: Self.epoch,
            consumedAt: Self.createdAt
        )
        #expect(AllowOnceLedger.keepConsumed(records: [consumed], now: Self.epoch).map(\.codeHash) == ["c"])
    }

    @Test func keepConsumedRetainsOnlyFreshConsumedForClear() {
        let freshConsumed = Self.record(kind: .consumed, hash: "keep", expiresAt: Self.epoch.addingTimeInterval(30))
        let staleConsumed = Self.record(kind: .consumed, hash: "drop-old", expiresAt: Self.epoch.addingTimeInterval(-1))
        let liveGranted = Self.record(kind: .granted, hash: "grant", expiresAt: Self.epoch.addingTimeInterval(30))
        let out = AllowOnceLedger.keepConsumed(
            records: [freshConsumed, staleConsumed, liveGranted],
            now: Self.epoch
        )
        #expect(out.map(\.codeHash) == ["keep"])
    }
}

private extension AllowOnceLedgerTests {
    static func record(
        kind: AllowOnceRecord.Kind,
        hash: String,
        fingerprint: String = "fp",
        expiresAt: Date,
        consumedAt: Date? = nil
    ) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            kind: kind,
            codeHash: hash,
            commandFingerprint: fingerprint,
            commandRedacted: "git …",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            createdAt: createdAt,
            expiresAt: expiresAt,
            consumedAt: consumedAt
        )
    }
}
