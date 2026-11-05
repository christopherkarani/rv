import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
import RVPresentation
import RVScan
import RVTheme
@testable import RVCLI

private func scanFixtureURL(_ relativePath: String) throws -> URL {
    let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../RVScanTests/Fixtures", isDirectory: true)
        .standardizedFileURL
    let url = base.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("missing fixture \(relativePath) at \(url.path)")
        throw ScanFixtureError.missing(relativePath)
    }
    return url
}

private func withTempScanHome(_ body: (ScanHome, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = try #require(ScanHome(validating: root.path))
    try body(home, root)
}

private func installClaudeFixture(into homeURL: URL) throws {
    let projects = homeURL
        .appendingPathComponent(".claude/projects/-tmp-rv-scan-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let reset = try scanFixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
    try FileManager.default.copyItem(
        at: reset,
        to: projects.appendingPathComponent("ac001-reset-hard.jsonl")
    )
}

private func installPiFixture(into homeURL: URL) throws {
    let sessions = homeURL
        .appendingPathComponent(".pi/agent/sessions/--tmp--", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let fixture = try scanFixtureURL("pi/session.jsonl")
    try FileManager.default.copyItem(
        at: fixture,
        to: sessions.appendingPathComponent("session.jsonl")
    )
}

private func decodedJSON(_ text: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(object as? [String: Any])
}

/// Runs the RVScan seam with the whole-history window the deleted
/// `ScanRun.Request.fixture` defaulted to.
private func scanReport(
    home: ScanHome,
    rootPath: String? = nil,
    hostFilter: ScanHostID? = nil,
    packIDs: [PackID] = dayOnePackIDs,
    includeGlobs: [String] = []
) throws -> ScanReport {
    try SessionScan().run(
        SessionScanRequest(
            home: home,
            now: Date(),
            rootPath: rootPath,
            includeGlobs: includeGlobs,
            hostFilter: hostFilter,
            timeWindow: .all,
            packIDs: packIDs
        )
    ).report
}

@Test func scanConfiguration_sessionsOnly_noRepoSubcommand() {
    #expect(ScanSessions.configuration.commandName == "sessions")
    #expect(Scan.configuration.defaultSubcommand == ScanSessions.self)
    let subcommandNames = Scan.configuration.subcommands.map { $0.configuration.commandName }
    #expect(subcommandNames == ["sessions"])
    #expect(subcommandNames.contains("repo") == false)
}

@Test func sessionScan_autoMode_findsClaudeDenyInTempHome() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try scanReport(home: home)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.ruleID.rawValue == "core.git:reset-hard")
        #expect(report.eventsExtracted == 1)
    }
}

@Test func sessionScan_autoMode_doesNotReadOutsideRegisteredRoots() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let outside = homeURL.appendingPathComponent("outside-reset-hard.jsonl")
        let payload = """
        {"type":"assistant","sessionId":"x","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git reset --hard"}}]}}
        """
        try payload.write(to: outside, atomically: true, encoding: .utf8)

        let report = try scanReport(home: home)

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.sourcePath.contains("outside-reset-hard.jsonl") == false)
        #expect(report.findings.first?.sourcePath.contains(".claude/projects") == true)
    }
}

@Test func sessionScan_hostFilterPi_ignoresClaudeFixture() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        try installPiFixture(into: homeURL)

        let report = try scanReport(home: home, hostFilter: .pi)

        #expect(report.findings.allSatisfy { $0.host == .pi })
        #expect(report.findings.contains { $0.ruleID.rawValue == "core.git:reset-hard" })
        #expect(report.findings.contains { $0.host == .claude } == false)
    }
}

@Test func sessionScan_includeGlob_withExplicitPath_findsUnrecognizedGrokDeny() throws {
    try withTempScanHome { home, homeURL in
        let tree = homeURL.appendingPathComponent("explicit-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try scanFixtureURL("grok/chat_history.jsonl"),
            to: tree.appendingPathComponent("notes.txt")
        )

        let skipped = try scanReport(home: home, rootPath: tree.path)
        #expect(skipped.findings.isEmpty)
        #expect(skipped.eventsExtracted == 0)

        let report = try scanReport(
            home: home,
            rootPath: tree.path,
            includeGlobs: ["*.txt"]
        )
        #expect(report.findings.contains { $0.ruleID.rawValue == "core.git:reset-hard" })
        #expect(report.findings.first?.host == .grok)
        #expect(report.findings.first?.sourcePath.contains("notes.txt") == true)
    }
}

@Test func sessionScan_includeGlobWithoutPath_failsClosedWithoutWalkingHome() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        do {
            _ = try scanReport(home: home, includeGlobs: ["**/*.jsonl"])
            Issue.record("expected includeGlobRequiresPath without walking HOME")
        } catch SessionScanError.includeGlobRequiresPath {
            // usage error; registered roots under HOME must not be walked
        }
    }
}

@Test func sessionScan_missingPath_failsClosed() throws {
    let missing = "/tmp/rv-scan-missing-\(UUID().uuidString)"
    do {
        _ = try scanReport(
            home: try #require(ScanHome(validating: "/tmp")),
            rootPath: missing
        )
        Issue.record("expected pathNotFound for missing path")
    } catch SessionScanError.pathNotFound(let path) {
        #expect(path == missing)
    }
}

@Test func sessionScan_unknownPacks_throwsPacksUnavailable() throws {
    try withTempScanHome { home, homeURL in
        do {
            _ = try scanReport(
                home: home,
                rootPath: homeURL.path,
                packIDs: [PackID(rawValue: "no.such.pack")]
            )
            Issue.record("expected packsUnavailable")
        } catch SessionScanError.packsUnavailable {
            // fail-closed pack resolution at the RVScan seam
        }
    }
}

@Test func sessionScan_listingFailure_throwsListingFailed() throws {
    try withTempScanHome { home, homeURL in
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: homeURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homeURL.path)
        }
        let expected = URL(fileURLWithPath: homeURL.path, isDirectory: true).standardizedFileURL.path
        do {
            _ = try scanReport(home: home, rootPath: homeURL.path)
            Issue.record("expected listingFailed")
        } catch SessionScanError.listingFailed(let path) {
            #expect(path == expected)
        }
    }
}

@Test func sessionScan_unreadableStore_throwsUnreadableStore() throws {
    try withTempScanHome { home, homeURL in
        let tree = homeURL.appendingPathComponent("explicit-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let db = tree.appendingPathComponent("opencode.db")
        try Data().write(to: db, options: .atomic)
        let expected = db.standardizedFileURL.path
        do {
            _ = try scanReport(home: home, rootPath: tree.path)
            Issue.record("expected unreadableStore")
        } catch SessionScanError.unreadableStore(let path) {
            #expect(path == expected)
        }
    }
}

// The Linux gate has no SQLite3 clang module (see scanLinkerSettings in
// Package.swift): this fixture-backed test compiles only where SQLite3 imports.
#if canImport(SQLite3)
@Test func sessionScan_prepareFailed_throwsPrepareFailed() throws {
    try withTempScanHome { home, homeURL in
        let tree = homeURL.appendingPathComponent("explicit-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let db = tree.appendingPathComponent("opencode.db")
        try writeScanSQLiteDatabase(at: db, sql: "CREATE TABLE other (id TEXT);")
        let expected = db.standardizedFileURL.path
        do {
            _ = try scanReport(home: home, rootPath: tree.path)
            Issue.record("expected prepareFailed")
        } catch SessionScanError.prepareFailed(let path) {
            #expect(path == expected)
        }
    }
}
#endif

@Test func scanCommand_doesNotContainPipelineLoops() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RVCLI/Commands/ScanCommand.swift")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("SessionScan()"))
    #expect(text.contains("SessionScanRequest("))
    #expect(text.contains("ScanRun.Request") == false)
    #expect(text.contains("DirectoryWalker") == false)
    #expect(text.contains("ScanClassify") == false)
    #expect(text.contains("ScanDedupe") == false)
    #expect(text.contains(".extract(") == false)
}

@Test func scanRobot_defaultRedaction_usesSchemaAndEllipsis() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try scanReport(home: home)
        let json = try renderScanSessionsRobot(from: report, showCommand: false)
        let object = try decodedJSON(json)
        #expect(object["schema"] as? String == "rv.scan.sessions.v1")
        #expect(RobotSchema.scanSessions == "rv.scan.sessions.v1")
        let findings = try #require(object["findings"] as? [[String: Any]])
        let row = try #require(findings.first)
        #expect(row["command_redacted"] as? String == "git …")
        #expect(row["command"] == nil || row["command"] is NSNull)
        #expect(row["rule_id"] as? String == "core.git:reset-hard")
        #expect((object["command"] as? String) == nil)
    }
}

@Test func scanRobot_showCommand_includesFullMatchingView() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try scanReport(home: home)
        let json = try renderScanSessionsRobot(from: report, showCommand: true)
        let object = try decodedJSON(json)
        let findings = try #require(object["findings"] as? [[String: Any]])
        let row = try #require(findings.first)
        #expect(row["command"] as? String == "git reset --hard")
        #expect(row["command_redacted"] as? String == "git …")
    }
}

@Test func scanRobot_pathEscapesLineAndBidiScalars() throws {
    try withTempScanHome { home, homeURL in
        let marker = "p\u{1B}[2J\u{2028}\u{2029}\u{202E}ok"
        let projects = homeURL.appendingPathComponent(".claude/projects/\(marker)", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let reset = try scanFixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
        let destination = projects.appendingPathComponent("ac001-reset-hard.jsonl")
        try FileManager.default.copyItem(at: reset, to: destination)
        let report = try scanReport(home: home)
        let json = try renderScanSessionsRobot(from: report, showCommand: false)
        #expect(json.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(json.contains("\\u001b"))
        #expect(json.contains("\\u2028"))
        #expect(json.contains("\\u2029"))
        #expect(json.contains("\\u202e"))
        let object = try decodedJSON(json)
        let findings = try #require(object["findings"] as? [[String: Any]])
        #expect(findings.first?["path"] as? String == destination.path)
    }
}

@Test func scanPretty_defaultRedaction_hidesFullArgv() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try scanReport(home: home)
        let outcome = try ScanRun.render(
            report: report,
            showCommand: false,
            appearance: .pretty(colorOffPalette),
            probe: ThemeProbe(
                terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
                forbid: OutputForbid(
                    json: false,
                    robot: false,
                    plain: true,
                    ci: false,
                    noColor: .init(flag: false, env: false, termDumb: false)
                )
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("git …"))
        #expect(outcome.stdout.contains("git reset --hard") == false)
        #expect(outcome.stdout.contains("core.git:reset-hard"))
    }
}

@Test func scanPrettyAndRobot_shareFindingCountAfterDedupe() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let reset = try scanFixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
        let projects = homeURL
            .appendingPathComponent(".claude/projects/-tmp-rv-scan-fixture", isDirectory: true)
        try FileManager.default.copyItem(
            at: reset,
            to: projects.appendingPathComponent("dup-reset-hard.jsonl")
        )

        let report = try scanReport(home: home)

        let pretty = try ScanRun.render(
            report: report,
            showCommand: false,
            appearance: .pretty(colorOffPalette),
            probe: ThemeProbe(
                terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
                forbid: OutputForbid(
                    json: false,
                    robot: false,
                    plain: true,
                    ci: false,
                    noColor: .init(flag: false, env: false, termDumb: false)
                )
            )
        )
        let robot = try renderScanSessionsRobot(from: report, showCommand: false)
        let object = try decodedJSON(robot)
        let findings = try #require(object["findings"] as? [[String: Any]])
        #expect(findings.count == 1)
        #expect(findings.first?["count"] as? Int == 2)
        #expect(pretty.stdout.contains("×2"))
    }
}

private enum ScanFixtureError: Error {
    case missing(String)
}

#if canImport(SQLite3)
private enum ScanSQLiteFixtureError: Error {
    case openFailed
    case execFailed
}

private func writeScanSQLiteDatabase(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw ScanSQLiteFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw ScanSQLiteFixtureError.execFailed
    }
}
#endif
