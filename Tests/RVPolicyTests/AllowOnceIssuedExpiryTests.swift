import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// rvd's memory of a code it issued decides whether it raises the owner
/// prompt and plants a grant (`issued(codeHash:now:)`). Its expiry comes
/// from the saved pending row, so it never outlives the row the CLI's
/// redeem checks, and it is never later than the mint's own deadline: a
/// granted or consumed row that shares the hash (a six-hex collision with
/// a spent code, a planted row, a clock step back) must not lengthen it.
struct AllowOnceIssuedExpiryTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let ttl: TimeInterval = 15 * 60
    private static let deadline = now.addingTimeInterval(ttl)
    private static let hash = String(repeating: "a", count: 64)

    private static func row(
        _ lifecycle: AllowOnceLifecycle,
        hash: String = hash,
        createdAt: Date = now,
        expiresAt: Date
    ) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: lifecycle,
            codeHash: CodeHash(rawValue: hash),
            commandFingerprint: GrantFingerprint(rawValue: String(repeating: "f", count: 64)),
            commandRedacted: "git push --force",
            cwd: WorkingDirectory(validating: "/tmp/ws")!,
            ruleID: nil,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    /// The whole-second expiry the file keeps for a sub-second mint.
    private static let savedPendingExpiry = deadline.addingTimeInterval(-0.5)
    private static let pending = row(.pending, expiresAt: savedPendingExpiry)
    /// Same hash, created later (so `capped` sorts it last), expiring far
    /// past the mint's deadline.
    private static let spentLater = [
        row(.granted, createdAt: now.addingTimeInterval(5), expiresAt: now.addingTimeInterval(24 * 3600)),
        row(.consumed(at: now), createdAt: now.addingTimeInterval(6), expiresAt: now.addingTimeInterval(48 * 3600)),
    ]

    @Test func aPendingRowSuppliesItsSavedExpiry() {
        let other = Self.row(.pending, hash: String(repeating: "b", count: 64), expiresAt: Self.deadline)
        #expect(AllowOnceStore.savedExpiry(of: Self.hash, in: [Self.pending, other]) == Self.savedPendingExpiry)
        #expect(AllowOnceStore.issuedExpiry(
            of: Self.hash, in: [Self.pending, other], now: Self.now, ttl: Self.ttl) == Self.savedPendingExpiry)
    }

    @Test func onlyASpentRowWithTheHashNeverLengthensTheExpiry() {
        for spent in Self.spentLater {
            #expect(AllowOnceStore.savedExpiry(of: Self.hash, in: [spent]) == nil, "\(spent.kind)")
            let issued = AllowOnceStore.issuedExpiry(of: Self.hash, in: [spent], now: Self.now, ttl: Self.ttl)
            #expect(issued <= Self.deadline, "\(spent.kind)")
        }
    }

    @Test func thePendingRowWinsOverALaterSpentRowWithTheSameHash() {
        let saved = [Self.pending] + Self.spentLater
        #expect(AllowOnceStore.savedExpiry(of: Self.hash, in: saved) == Self.savedPendingExpiry)
        #expect(AllowOnceStore.issuedExpiry(
            of: Self.hash, in: saved, now: Self.now, ttl: Self.ttl) == Self.savedPendingExpiry)
    }

    /// "Never extends" holds by construction, whatever the date encoding
    /// does to a saved pending row's expiry.
    @Test func aSavedExpiryPastTheDeadlineIsClamped() {
        let late = Self.row(.pending, expiresAt: Self.deadline.addingTimeInterval(1))
        #expect(AllowOnceStore.issuedExpiry(
            of: Self.hash, in: [late], now: Self.now, ttl: Self.ttl) == Self.deadline)
    }

    @Test func noSavedRowFallsBackToTheDeadline() {
        #expect(AllowOnceStore.issuedExpiry(of: Self.hash, in: [], now: Self.now, ttl: Self.ttl) == Self.deadline)
    }
}
