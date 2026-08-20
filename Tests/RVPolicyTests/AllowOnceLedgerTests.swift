import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct AllowOnceLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let cwd = "/tmp/ws"
    private let view: MatchingView = "git reset --hard"

    @Test func hasGrantRequiresLiveGrantedRow() {
        let live = granted(expiresAt: now.addingTimeInterval(60))
        let expired = granted(expiresAt: now.addingTimeInterval(-1))
        #expect(AllowOnceLedger.hasGrant(records: [live], matchingView: view, cwd: cwd, now: now))
        #expect(AllowOnceLedger.hasGrant(records: [expired], matchingView: view, cwd: cwd, now: now) == false)
        #expect(
            AllowOnceLedger.hasGrant(records: [live], matchingView: view, cwd: "/tmp/other", now: now)
                == false
        )
    }

    @Test func consumeSpendsFirstLiveGrantAndPrunesExpired() {
        let expired = granted(codeHash: "old", expiresAt: now.addingTimeInterval(-10))
        let live = granted(codeHash: "new", expiresAt: now.addingTimeInterval(60))
        let result = AllowOnceLedger.consume(
            records: [expired, live],
            matchingView: view,
            cwd: cwd,
            now: now
        )
        guard case .consumed(let token) = result.status else {
            Issue.record("live grant must consume")
            return
        }
        #expect(token == "new")
        #expect(result.records.count == 1)
        #expect(result.records[0].kind == AllowOnceRecord.Kind.consumed)
        #expect(result.records[0].consumedAt == now)
        let leftoverExpired = result.records.contains {
            $0.kind == .granted && $0.expiresAt < now
        }
        #expect(leftoverExpired == false)
    }

    @Test func consumeAlreadyConsumedDoesNotMutate() {
        let spent = consumed(codeHash: "tok")
        let result = AllowOnceLedger.consume(
            records: [spent],
            matchingView: view,
            cwd: cwd,
            now: now
        )
        #expect(result.status == AllowOnceConsumeStatus.alreadyConsumed)
        #expect(result.records == [spent])
    }

    @Test func consumeExpiredPrunesAndReportsExpired() {
        let expired = granted(expiresAt: now.addingTimeInterval(-1))
        let result = AllowOnceLedger.consume(
            records: [expired],
            matchingView: view,
            cwd: cwd,
            now: now
        )
        #expect(result.status == AllowOnceConsumeStatus.expired)
        #expect(result.records.isEmpty)
    }

    @Test func consumeMissingIsNotFound() {
        let result = AllowOnceLedger.consume(
            records: [],
            matchingView: view,
            cwd: cwd,
            now: now
        )
        #expect(result.status == AllowOnceConsumeStatus.notFound)
        #expect(result.records.isEmpty)
    }

    @Test func wrongCwdIsNotFound() {
        let live = granted(expiresAt: now.addingTimeInterval(60))
        let result = AllowOnceLedger.consume(
            records: [live],
            matchingView: view,
            cwd: "/tmp/other",
            now: now
        )
        #expect(result.status == AllowOnceConsumeStatus.notFound)
        #expect(result.records == [live])
    }

    @Test func makeGrantedUsesInjectedCodeHashAndFingerprint() {
        let record = AllowOnceLedger.makeGranted(
            matchingView: view,
            cwd: cwd,
            now: now,
            ttl: 100,
            codeHash: "abc"
        )
        #expect(record.kind == AllowOnceRecord.Kind.granted)
        #expect(record.codeHash == "abc")
        #expect(record.commandFingerprint == commandFingerprint(view))
        #expect(record.commandRedacted == "[redacted]")
        #expect(record.cwd == cwd)
        #expect(record.createdAt == now)
        #expect(record.expiresAt == now.addingTimeInterval(100))
        #expect(record.consumedAt == nil)
        #expect(record.schemaVersion == 1)
    }

    private func granted(
        codeHash: String = "hash",
        expiresAt: Date
    ) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            kind: .granted,
            codeHash: codeHash,
            commandFingerprint: commandFingerprint(view),
            commandRedacted: "[redacted]",
            cwd: cwd,
            ruleID: nil,
            createdAt: expiresAt.addingTimeInterval(-60),
            expiresAt: expiresAt,
            consumedAt: nil
        )
    }

    private func consumed(codeHash: String) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            kind: .consumed,
            codeHash: codeHash,
            commandFingerprint: commandFingerprint(view),
            commandRedacted: "[redacted]",
            cwd: cwd,
            ruleID: nil,
            createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60),
            consumedAt: now.addingTimeInterval(-30)
        )
    }
}
