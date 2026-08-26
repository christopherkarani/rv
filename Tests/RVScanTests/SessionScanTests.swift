import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func extractedEvent_commandIsShellCommand() {
    let event = ExtractedEvent(
        host: .claude,
        sourcePath: "/tmp/session.jsonl",
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    #expect(event.command.rawValue == "git reset --hard")
    let boxed: any Sendable = event
    _ = boxed
}

@Test func scanFinding_lastSeenIsOptionalDate() {
    let occurred = Date(timeIntervalSince1970: 1_700_000_100)
    let lastSeen = Date(timeIntervalSince1970: 1_700_000_200)
    let finding = ScanFinding(
        host: .pi,
        sessionID: "s1",
        sourcePath: "/tmp/session.jsonl",
        occurredAt: occurred,
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        matchingView: MatchingView("git reset --hard"),
        count: 3,
        lastSeen: lastSeen
    )
    #expect(finding.lastSeen == lastSeen)
    #expect(finding.occurredAt == occurred)
    #expect(finding.count == 3)
    #expect(ScanFinding(
        host: .grok,
        sourcePath: "/tmp/other.jsonl",
        ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf"),
        packID: .coreFilesystem,
        matchingView: MatchingView("rm -rf /")
    ).lastSeen == nil)
}

@Test func scanReport_hasNoSetupNudgeField() {
    let report = ScanReport(
        findings: [],
        warnings: [ScanWarning(code: "cap.files", message: "Stopped after 3 files")],
        filesScanned: 3,
        eventsExtracted: 0
    )
    let labels = Set(Mirror(reflecting: report).children.compactMap(\.label))
    #expect(labels.contains("setupNudgeRecommended") == false)
    #expect(labels.contains("setupNudge") == false)
    #expect(labels.contains("setup_nudge") == false)
    #expect(labels == ["findings", "warnings", "filesScanned", "eventsExtracted"])
}

@Test func sessionScanRequest_nowIsInjectedDate() throws {
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home"))
    let now = Date(timeIntervalSince1970: 1_777_000_000)
    let request = SessionScanRequest(home: home, now: now, days: 7)
    #expect(request.now == now)
    #expect(request.days == 7)
    #expect(request.scanAll == false)
    #expect(request.packIDs == dayOnePackIDs)
    let boxed: any Sendable = request
    _ = boxed
}

@Test func sessionScan_runNilRootPathFailsClosed() throws {
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home"))
    let now = Date(timeIntervalSince1970: 1_777_000_000)
    let request = SessionScanRequest(home: home, now: now)
    #expect(request.rootPath == nil)
    #expect(throws: SessionScanError.missingRoot) {
        try SessionScan().run(request)
    }
}

@Test func sessionScan_runRootListingFailureThrows() throws {
    try withTempTree { root in
        let home = try #require(ScanHome(validating: root.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let expected = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
        #expect(throws: SessionScanError.listingFailed(expected)) {
            try SessionScan().run(
                SessionScanRequest(home: home, now: now, rootPath: root.path),
                fileManager: ListFailingFileManager()
            )
        }
    }
}

@Test func sessionScan_runMissingPathFailsClosed() throws {
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home"))
    let now = Date(timeIntervalSince1970: 1_777_000_000)
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-missing-\(UUID().uuidString)", isDirectory: true)
        .path
    let request = SessionScanRequest(home: home, now: now, rootPath: missing)
    #expect(throws: SessionScanError.pathNotFound(missing)) {
        try SessionScan().run(request)
    }
}

@Test func sessionScan_runWalksPathWithoutCallingWallClock() throws {
    try withTempTree { root in
        try writeFile(root.appendingPathComponent("a.txt"), contents: "a")
        try writeFile(root.appendingPathComponent("b.txt"), contents: "b")
        let home = try #require(ScanHome(validating: root.path))
        let now = Date(timeIntervalSince1970: 0)
        let report = try SessionScan().run(
            SessionScanRequest(home: home, now: now, rootPath: root.path)
        )
        #expect(report.filesScanned == 2)
        #expect(report.findings.isEmpty)
        #expect(report.eventsExtracted == 0)
        #expect(now.timeIntervalSince1970 == 0)
    }
}

@Test func sessionScan_typesAreSendable() throws {
    let home = try #require(ScanHome(validating: "/tmp/h"))
    let finding: any Sendable = ScanFinding(
        host: .opencode,
        sourcePath: "/tmp/s.jsonl",
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        matchingView: MatchingView("git reset --hard"),
        lastSeen: Date(timeIntervalSince1970: 1)
    )
    let report: any Sendable = ScanReport()
    let request: any Sendable = SessionScanRequest(
        home: home,
        now: Date(timeIntervalSince1970: 2)
    )
    let scan: any Sendable = SessionScan()
    _ = (finding, report, request, scan)
}

private func withTempTree(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func writeFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url, options: .atomic)
}

private final class ListFailingFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        throw CocoaError(.fileReadNoPermission)
    }
}
