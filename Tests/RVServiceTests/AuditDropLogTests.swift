import Foundation
import Synchronization
import Testing
@testable import RVService

/// G1, G6: a dropped `audit.jsonl` row is logged, once per kind per minute.
struct AuditDropLogTests {
    private final class Lines: Sendable {
        let written = Mutex<[String]>([])
    }

    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let file = URL(fileURLWithPath: "/home/owner/.config/rv/audit.jsonl")

    @Test func logsOncePerKindPerMinute() {
        let lines = Lines()
        let log = AuditDropLog(write: { line in lines.written.withLock { $0.append(line) } })
        #expect(log.report(.ownerAction, file: Self.file, consequence: "x", now: Self.start))
        #expect(log.report(.ownerAction, file: Self.file, consequence: "x", now: Self.start.addingTimeInterval(59)) == false)
        // Another kind has its own minute.
        #expect(log.report(.commandOverride, file: Self.file, consequence: "y", now: Self.start.addingTimeInterval(1)))
        #expect(log.report(.ownerAction, file: Self.file, consequence: "x", now: Self.start.addingTimeInterval(60)))
        #expect(lines.written.withLock { $0.count } == 3)
    }

    @Test func theLineNamesTheFileTheRowAndWhatHappened() throws {
        let lines = Lines()
        let log = AuditDropLog(write: { line in lines.written.withLock { $0.append(line) } })
        log.report(.commandOverride, file: Self.file, consequence: "the command stays denied", now: Self.start)
        let line = try #require(lines.written.withLock { $0.first })
        #expect(line.contains("/home/owner/.config/rv/audit.jsonl"))
        #expect(line.contains("command.override"))
        #expect(line.contains("the command stays denied"))
        #expect(line.contains("rv audit verify"))
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().contains("\n") == false)
    }

    @Test func noHomeIsNamedAsSuch() throws {
        let lines = Lines()
        let log = AuditDropLog(write: { line in lines.written.withLock { $0.append(line) } })
        log.report(.ownerAction, file: nil, consequence: "the owner's approval was refused", now: Self.start)
        let line = try #require(lines.written.withLock { $0.first })
        #expect(line.contains("no home directory"))
    }

    /// G3: with no home there is nowhere to record an approval, so rvd
    /// does not give it.
    @Test func anOwnerApprovalWithNoHomeIsNotRecorded() async {
        let log = AuditDropLog(write: { _ in })
        let recorded = await OwnerPresence.audit(
            summary: "set safety to normal", approved: true, outcome: "approved",
            context: .unauthenticated, home: nil, dropLog: log)
        #expect(recorded == false)
    }
}
