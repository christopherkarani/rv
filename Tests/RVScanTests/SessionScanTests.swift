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
    #expect(labels.contains("eventHosts") == false)
    #expect(labels == ["findings", "warnings", "filesScanned", "eventsExtracted"])
}

@Test func sessionScanResult_carriesReportAndEventHosts() {
    let report = ScanReport(filesScanned: 1, eventsExtracted: 2)
    let result = SessionScanResult(report: report, eventHosts: [.claude, .pi])
    #expect(result.report == report)
    #expect(result.eventHosts == [.claude, .pi])
    let labels = Set(Mirror(reflecting: result).children.compactMap(\.label))
    #expect(labels == ["report", "eventHosts"])
}

@Test func sessionScanRequest_nowIsInjectedDate() throws {
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home"))
    let now = Date(timeIntervalSince1970: 1_777_000_000)
    let request = SessionScanRequest(home: home, now: now, days: 7)
    #expect(request.now == now)
    #expect(request.days == 7)
    #expect(request.scanAll == false)
    #expect(request.includeGlobs.isEmpty)
    #expect(request.packIDs == dayOnePackIDs)
    #expect(request.timeWindow == ScanTimeWindow(dayCount: 7))
    let boxed: any Sendable = request
    _ = boxed
}

@Test func sessionScanAdapters_areTheSixKnownHosts() {
    #expect(SessionScanAdapters.all.map(\.host) == [
        .claude, .pi, .grok, .opencode, .openclaw, .hermes,
    ])
    #expect(SessionScanAdapters.selected(hostFilter: .pi).map(\.host) == [.pi])
}

@Test func sessionScan_runNilRootPath_usesKnownHostRootsWithoutMissingRoot() throws {
    try withTempTree { root in
        let home = try #require(ScanHome(validating: root.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let request = SessionScanRequest(home: home, now: now)
        #expect(request.rootPath == nil)
        let result = try SessionScan().run(request)
        #expect(result.report.findings.isEmpty)
        #expect(result.report.eventsExtracted == 0)
        #expect(result.eventHosts.isEmpty)
    }
}

@Test func sessionScan_runRootListingFailureThrows() throws {
    try withTempTree { root in
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        #expect(throws: (any Error).self) {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        }

        let home = try #require(ScanHome(validating: root.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let expected = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
        #expect(throws: SessionScanError.listingFailed(expected)) {
            try SessionScan().run(SessionScanRequest(home: home, now: now, rootPath: root.path))
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

@Test func sessionScan_includeGlobsWithoutPath_throwsTypedError() throws {
    try withTempTree { homeURL in
        try installClaudeResetHard(into: homeURL)
        let home = try #require(ScanHome(validating: homeURL.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        #expect(throws: SessionScanError.includeGlobRequiresPath) {
            try SessionScan().run(
                SessionScanRequest(
                    home: home,
                    now: now,
                    includeGlobs: ["**/*.jsonl"],
                    scanAll: true
                )
            )
        }
    }
}

@Test func sessionScan_runWalksPathWithoutCallingWallClock() throws {
    try withTempTree { root in
        try writeFile(root.appendingPathComponent("a.txt"), contents: "a")
        try writeFile(root.appendingPathComponent("b.txt"), contents: "b")
        let home = try #require(ScanHome(validating: root.path))
        let now = Date(timeIntervalSince1970: 0)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, rootPath: root.path)
        )
        #expect(result.report.filesScanned == 2)
        #expect(result.report.findings.isEmpty)
        #expect(result.report.eventsExtracted == 0)
        #expect(now.timeIntervalSince1970 == 0)
    }
}

@Test func sessionScan_knownHostRoots_findsClaudeDenyInTempHome() throws {
    try withTempTree { homeURL in
        try installClaudeResetHard(into: homeURL)
        let home = try #require(ScanHome(validating: homeURL.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, scanAll: true)
        )
        #expect(result.report.findings.count == 1)
        #expect(result.report.findings.first?.ruleID.rawValue == "core.git:reset-hard")
        #expect(result.report.eventsExtracted == 1)
        #expect(result.eventHosts == [.claude])
    }
}

@Test func sessionScan_knownHostRoots_doesNotReadOutsideRegisteredRoots() throws {
    try withTempTree { homeURL in
        try installClaudeResetHard(into: homeURL)
        let outside = homeURL.appendingPathComponent("outside-reset-hard.jsonl")
        let payload = """
        {"type":"assistant","sessionId":"x","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git reset --hard"}}]}}
        """
        try payload.write(to: outside, atomically: true, encoding: .utf8)

        let home = try #require(ScanHome(validating: homeURL.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, scanAll: true)
        )

        #expect(result.report.findings.count == 1)
        #expect(result.report.findings.first?.sourcePath.contains("outside-reset-hard.jsonl") == false)
        #expect(result.report.findings.first?.sourcePath.contains(".claude/projects") == true)
    }
}

@Test func sessionScan_hostFilterPi_ignoresClaudeFixture() throws {
    try withTempTree { homeURL in
        try installClaudeResetHard(into: homeURL)
        try installPiSession(into: homeURL)
        let home = try #require(ScanHome(validating: homeURL.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, hostFilter: .pi, scanAll: true)
        )

        #expect(result.report.findings.allSatisfy { $0.host == .pi })
        #expect(result.report.findings.contains { $0.ruleID.rawValue == "core.git:reset-hard" })
        #expect(result.report.findings.contains { $0.host == .claude } == false)
        #expect(result.eventHosts == [.pi])
    }
}

@Test func sessionScan_allowOnlyClaudeEvents_stillRecordEventHost() throws {
    try withTempTree { homeURL in
        try installClaudeAllowStatus(into: homeURL)
        let home = try #require(ScanHome(validating: homeURL.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, scanAll: true)
        )
        #expect(result.report.findings.isEmpty)
        #expect(result.report.eventsExtracted == 1)
        #expect(result.eventHosts == [.claude])
    }
}

@Test func sessionScan_explicitTree_findsKnownLayoutJsonl() throws {
    try withTempTree { root in
        let dest = root.appendingPathComponent("ac001-reset-hard.jsonl")
        try FileManager.default.copyItem(
            at: try fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl"),
            to: dest
        )
        let home = try #require(ScanHome(validating: "/tmp/rv-scan-unused-home"))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, rootPath: root.path, scanAll: true)
        )
        #expect(result.report.findings.count == 1)
        #expect(result.report.findings.first?.ruleID.rawValue == "core.git:reset-hard")
    }
}

@Test func sessionScan_dedupesDuplicateClaudeDenies() throws {
    try withTempTree { homeURL in
        try installClaudeResetHard(into: homeURL)
        let projects = homeURL
            .appendingPathComponent(".claude/projects/-tmp-rv-scan-fixture", isDirectory: true)
        try FileManager.default.copyItem(
            at: try fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl"),
            to: projects.appendingPathComponent("dup-reset-hard.jsonl")
        )
        let home = try #require(ScanHome(validating: homeURL.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(home: home, now: now, scanAll: true)
        )
        #expect(result.report.findings.count == 1)
        #expect(result.report.findings.first?.count == 2)
        #expect(result.report.eventsExtracted == 2)
    }
}

@Test func sessionScan_unknownPacks_throwsPacksUnavailable() throws {
    try withTempTree { root in
        let home = try #require(ScanHome(validating: root.path))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        #expect(throws: SessionScanError.packsUnavailable) {
            try SessionScan().run(
                SessionScanRequest(
                    home: home,
                    now: now,
                    rootPath: root.path,
                    packIDs: [PackID(rawValue: "no.such.pack")]
                )
            )
        }
    }
}

@Test func includeGlob_matchesBasenameAndRelativePath() {
    let root = URL(fileURLWithPath: "/tmp/rv-scan-glob", isDirectory: true)
    let nested = root.appendingPathComponent("nested/notes.txt")
    let top = root.appendingPathComponent("notes.txt")
    #expect(matchesIncludeGlob(fileURL: top, scanRoot: root, patterns: ["*.txt"]))
    #expect(matchesIncludeGlob(fileURL: nested, scanRoot: root, patterns: ["*.txt"]))
    #expect(matchesIncludeGlob(fileURL: nested, scanRoot: root, patterns: ["nested/*.txt"]))
    #expect(matchesIncludeGlob(fileURL: nested, scanRoot: root, patterns: ["*.jsonl"]) == false)
    #expect(matchesIncludeGlob(fileURL: top, scanRoot: root, patterns: []) == false)
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
    let result: any Sendable = SessionScanResult(report: ScanReport(), eventHosts: [])
    _ = (finding, report, request, scan, result)
}

@Test func sessionScan_sourcesDoNotImportForbiddenModules() throws {
    let scanRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RVScan", isDirectory: true)
    let names = [
        "SessionScan.swift",
        "SessionScanResult.swift",
        "SessionScanAdapters.swift",
        "IncludeGlob.swift",
    ]
    for name in names {
        let url = scanRoot.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("import RVCLI") == false)
        #expect(text.contains("import RVTUI") == false)
        #expect(text.contains("import RVService") == false)
        #expect(text.contains("import RVHooks") == false)
        #expect(text.contains("import RVPolicy") == false)
        #expect(text.contains("EvaluateSession") == false)
        #expect(text.contains("GatedEvaluate") == false)
        #expect(text.contains("PolicyGate") == false)
        #expect(text.contains("Date()") == false)
    }
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

private func installClaudeResetHard(into homeURL: URL) throws {
    let projects = homeURL
        .appendingPathComponent(".claude/projects/-tmp-rv-scan-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: try fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl"),
        to: projects.appendingPathComponent("ac001-reset-hard.jsonl")
    )
}

private func installClaudeAllowStatus(into homeURL: URL) throws {
    let projects = homeURL
        .appendingPathComponent(".claude/projects/-tmp-rv-scan-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: try fixtureURL("claude/projects/-tmp-rv-scan-fixture/allow-status.jsonl"),
        to: projects.appendingPathComponent("allow-status.jsonl")
    )
}

private func installPiSession(into homeURL: URL) throws {
    let sessions = homeURL
        .appendingPathComponent(".pi/agent/sessions/--tmp--", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: try fixtureURL("pi/session.jsonl"),
        to: sessions.appendingPathComponent("session.jsonl")
    )
}
