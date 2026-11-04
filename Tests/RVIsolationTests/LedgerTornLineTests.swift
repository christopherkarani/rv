import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// AC-008 end to end for the ledgers that share `JSONLAppendLog`: a crash
/// can leave the last line without its newline, and the next real append
/// must not concatenate onto it. The runtime-sessions ledger is covered in
/// `LaunchBoundaryRegressionTests.tornSessionLineDoesNotHideTheNextRecord`.
@Suite("LedgerTornLine")
struct LedgerTornLineTests {
    private static let fragment = "{\"torn\""

    private func temporaryLedger(_ name: String) throws -> (root: URL, ledger: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-torn-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent(name))
    }

    /// The raw file as lines: the fragment, then exactly one record, each
    /// newline-terminated.
    private func lines(of ledger: URL) throws -> [String] {
        let text = try String(contentsOf: ledger, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    @Test func workspaceLifecycleAppendClosesATornLine() throws {
        let (root, ledger) = try temporaryLedger("workspace-sessions.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.fragment.utf8).write(to: ledger)
        let record = WorkspaceLifecycleRecord(
            kind: .created,
            workspace: UUID(),
            originalPath: "/tmp/proj",
            protectedPath: "/private/tmp/rv-saved/proj",
            volumeDevice: 1,
            disk: "/dev/disk9",
            runtime: nil,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        switch WorkspaceLifecycleLog.append(record, to: ledger) {
        case .success:
            break
        case .failure(let error):
            Issue.record("append after a torn line must succeed, got \(error)")
        }
        let written = try lines(of: ledger)
        #expect(written.count == 2)
        #expect(written.first == Self.fragment)
        #expect(WorkspaceLifecycleLog.records(at: ledger) == [record])
        guard case .decoded(let read) = WorkspaceLifecycleLog.load(at: ledger) else {
            Issue.record("ledger must stay readable")
            return
        }
        #expect(read.tornTrailing == false)
    }

    @Test func agentInstanceJournalAppendClosesATornLine() throws {
        let (root, ledger) = try temporaryLedger("agent-instances.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.fragment.utf8).write(to: ledger)
        let record = AgentInstanceJournalRecord(
            kind: .attempted,
            instance: UUID(),
            workspace: UUID(),
            runtime: UUID(),
            definition: "claude",
            revision: "r1",
            ownerUID: 501,
            assurance: "launchObserved",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        switch AgentInstanceJournal.append(record, to: ledger) {
        case .success:
            break
        case .failure(let error):
            Issue.record("append after a torn line must succeed, got \(error)")
        }
        let written = try lines(of: ledger)
        #expect(written.count == 2)
        #expect(written.first == Self.fragment)
        #expect(AgentInstanceJournal.records(at: ledger) == [record])
        guard case .decoded(let read) = AgentInstanceJournal.load(at: ledger) else {
            Issue.record("ledger must stay readable")
            return
        }
        #expect(read.tornTrailing == false)
    }
}
