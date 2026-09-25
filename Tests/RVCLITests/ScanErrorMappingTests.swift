import Foundation
import Testing
import RVDomain
@testable import RVCLI

/// T4: a corrupt session store surfaces as a mapped CLI error, never a raw
/// adapter error dump (AC-002).
@Test func scanErrorMapping_corruptOpenClawStore_mapsExtractFailed() throws {
    try withScanErrorHome { home, root in
        let db = root.appendingPathComponent("openclaw-agent.sqlite")
        try Data("not-a-database".utf8).write(to: db, options: .atomic)
        let expected = db.standardizedFileURL.path
        do {
            _ = try ScanRun.run(
                .fixture(rootPath: root.path, home: home, hostFilter: .openclaw)
            )
            Issue.record("expected extractFailed for corrupt store")
        } catch ScanRun.Error.extractFailed(let storeError) {
            #expect(storeError == .unreadable(host: .openclaw, sourcePath: expected))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Test func scanErrorMapping_extractFailureMessages() {
    #expect(
        scanExtractFailureMessage(
            .unreadable(host: .openclaw, sourcePath: "/x/openclaw-agent.sqlite")
        ) == "cannot read openclaw session store: /x/openclaw-agent.sqlite"
    )
    #expect(
        scanExtractFailureMessage(.queryFailed(host: .cursor, sourcePath: "/x/y.jsonl"))
            == "cannot query cursor session store: /x/y.jsonl"
    )
}

private func withScanErrorHome(_ body: (ScanHome, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-scan-errors-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = try #require(ScanHome(validating: root.path))
    try body(home, root)
}
