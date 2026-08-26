import Foundation
import Testing
import RVDomain
import RVPresentation
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

@Test func scanConfiguration_sessionsOnly_noRepoSubcommand() {
    #expect(ScanSessions.configuration.commandName == "sessions")
    #expect(Scan.configuration.defaultSubcommand == ScanSessions.self)
    let subcommandNames = Scan.configuration.subcommands.map { $0.configuration.commandName }
    #expect(subcommandNames == ["sessions"])
    #expect(subcommandNames.contains("repo") == false)
}

@Test func scanRun_autoMode_findsClaudeDenyInTempHome() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try ScanRun.run(
            .fixture(home: home)
        )
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.ruleID.rawValue == "core.git:reset-hard")
        #expect(report.eventsExtracted == 1)
    }
}

@Test func scanRun_autoMode_doesNotReadOutsideRegisteredRoots() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let outside = homeURL.appendingPathComponent("outside-reset-hard.jsonl")
        let payload = """
        {"type":"assistant","sessionId":"x","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git reset --hard"}}]}}
        """
        try payload.write(to: outside, atomically: true, encoding: .utf8)

        let report = try ScanRun.run(
            .fixture(home: home)
        )

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.sourcePath.contains("outside-reset-hard.jsonl") == false)
        #expect(report.findings.first?.sourcePath.contains(".claude/projects") == true)
    }
}

@Test func scanRun_hostFilterPi_ignoresClaudeFixture() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        try installPiFixture(into: homeURL)

        let report = try ScanRun.run(
            .fixture(home: home, hostFilter: .pi)
        )

        #expect(report.findings.allSatisfy { $0.host == .pi })
        #expect(report.findings.contains { $0.ruleID.rawValue == "core.git:reset-hard" })
        #expect(report.findings.contains { $0.host == .claude } == false)
    }
}

@Test func scanRun_includeGlobWithoutPath_failsClosedWithoutWalkingHome() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        do {
            _ = try ScanRun.run(
                .fixture(home: home, includeGlobs: ["**/*.jsonl"])
            )
            Issue.record("expected includeGlobRequiresPath without walking HOME")
        } catch ScanRun.Error.includeGlobRequiresPath {
            // usage error; registered roots under HOME must not be walked
        }
    }
}

@Test func scanRun_missingPath_failsClosed() throws {
    let missing = "/tmp/rv-scan-missing-\(UUID().uuidString)"
    do {
        _ = try ScanRun.run(
            .fixture(
                rootPath: missing,
                home: try #require(ScanHome(validating: "/tmp"))
            )
        )
        Issue.record("expected pathNotFound for missing path")
    } catch ScanRun.Error.pathNotFound(let path) {
        #expect(path == missing)
    }
}

@Test func scanRobot_defaultRedaction_usesSchemaAndEllipsis() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try ScanRun.run(
            .fixture(home: home)
        )
        let json = renderScanSessionsRobot(from: report, showCommand: false)
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
        let report = try ScanRun.run(
            .fixture(home: home)
        )
        let json = renderScanSessionsRobot(from: report, showCommand: true)
        let object = try decodedJSON(json)
        let findings = try #require(object["findings"] as? [[String: Any]])
        let row = try #require(findings.first)
        #expect(row["command"] as? String == "git reset --hard")
        #expect(row["command_redacted"] as? String == "git …")
    }
}

@Test func scanPretty_defaultRedaction_hidesFullArgv() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let report = try ScanRun.run(
            .fixture(home: home)
        )
        let outcome = ScanRun.render(
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

        let report = try ScanRun.run(
            .fixture(home: home)
        )

        let pretty = ScanRun.render(
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
        let robot = renderScanSessionsRobot(from: report, showCommand: false)
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
