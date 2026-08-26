import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import RVTheme
import Testing
@testable import RVCLI

private func scanFixtureURL(_ relativePath: String) throws -> URL {
    let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../RVScanTests/Fixtures", isDirectory: true)
        .standardizedFileURL
    let url = base.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("missing fixture \(relativePath) at \(url.path)")
        throw ScanNudgeFixtureError.missing(relativePath)
    }
    return url
}

private func withTempScanHome(_ body: (ScanHome, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-scan-nudge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = try #require(ScanHome(validating: root.path))
    try body(home, root)
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

private func wirePiAdapter(homeURL: URL) throws {
    let paths = OwnedPaths(home: try #require(HomeDirectory(validating: homeURL.path)))
    let owned = paths.hostAdapter(for: .pi)
    let executable = homeURL.appendingPathComponent("bin/rv")
    try makeExecutable(executable)
    let body = try HookHost.pi.adapterResource().rendered(rvPath: executable.path)
    try FileManager.default.createDirectory(
        atPath: (owned.destination as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try body.write(toFile: owned.destination, atomically: true, encoding: .utf8)
}

private func prettyProbe() -> ThemeProbe {
    ThemeProbe(
        terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
        forbid: OutputForbid(
            json: false,
            robot: false,
            plain: true,
            ci: false,
            noColor: .init(flag: false, env: false, termDumb: false)
        )
    )
}

private func robotProbe() -> ThemeProbe {
    ThemeProbe(
        terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
        forbid: OutputForbid(
            json: false,
            robot: true,
            plain: false,
            ci: false,
            noColor: .init(flag: false, env: false, termDumb: false)
        )
    )
}

private func runPiScan(home: ScanHome) throws -> ScanRunResult {
    try ScanRun.execute(
        ScanRun.Request(
            rootPath: nil,
            home: home,
            hostFilter: .pi,
            timeWindow: .all,
            packIDs: dayOnePackIDs,
            allEvents: false,
            includeGlobs: [],
            bounds: .default,
            now: Date(),
            fileManager: .default
        )
    )
}

@Test func scanFailOnFindings_withoutFlag_exitsZeroWithFindings() throws {
    try withTempScanHome { home, homeURL in
        try installPiFixture(into: homeURL)
        let result = try runPiScan(home: home)
        #expect(result.report.findings.isEmpty == false)

        let outcome = ScanRun.render(
            report: result.report,
            showCommand: false,
            failOnFindings: false,
            appearance: .pretty(colorOffPalette),
            probe: prettyProbe()
        )
        #expect(outcome.exitCode == 0)
    }
}

@Test func scanFailOnFindings_withFlag_exitsTwoWhenFindingsExist() throws {
    try withTempScanHome { home, homeURL in
        try installPiFixture(into: homeURL)
        let result = try runPiScan(home: home)
        #expect(result.report.findings.isEmpty == false)

        let outcome = ScanRun.render(
            report: result.report,
            showCommand: false,
            failOnFindings: true,
            appearance: .robot,
            probe: robotProbe()
        )
        #expect(outcome.exitCode == 2)
    }
}

@Test func scanFailOnFindings_withFlag_exitsZeroWhenFindingsEmpty() throws {
    try withTempScanHome { home, _ in
        let result = try ScanRun.execute(
            ScanRun.Request(
                rootPath: nil,
                home: home,
                hostFilter: .pi,
                timeWindow: .all,
                packIDs: dayOnePackIDs,
                allEvents: false,
                includeGlobs: [],
                bounds: .default,
                now: Date(),
                fileManager: .default
            )
        )
        #expect(result.report.findings.isEmpty)

        let outcome = ScanRun.render(
            report: result.report,
            showCommand: false,
            failOnFindings: true,
            appearance: .robot,
            probe: robotProbe()
        )
        #expect(outcome.exitCode == 0)
    }
}

@Test func scanSetupNudge_unwiredHostThatProducedEvents_emitsOnePrettyLine() throws {
    try withTempScanHome { home, homeURL in
        try installPiFixture(into: homeURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: homeURL.path)

        let result = try runPiScan(home: home)
        let nudge = scanSetupNudgeRecommended(
            hosts: result.eventHosts,
            home: home,
            pathEntries: [],
            fileManager: .default
        )
        #expect(nudge)
        #expect(result.report.eventsExtracted > 0)

        let outcome = ScanRun.render(
            report: result.report,
            showCommand: false,
            setupNudgeRecommended: nudge,
            appearance: .pretty(colorOffPalette),
            probe: prettyProbe()
        )
        let nudgeLines = outcome.stdout.split(separator: "\n").filter {
            $0.contains("rv setup") || $0.contains("rv doctor")
        }
        #expect(nudgeLines.count == 1)
        #expect(outcome.stdout.contains("Some hosts are not wired"))

        let after = try FileManager.default.contentsOfDirectory(atPath: homeURL.path)
        #expect(after == before)
        #expect(
            FileManager.default.fileExists(
                atPath: homeURL.appendingPathComponent(".pi/agent/extensions/rv-guard.ts").path
            ) == false
        )
    }
}

@Test func scanSetupNudge_wiredHost_doesNotRecommend() throws {
    try withTempScanHome { home, homeURL in
        try installPiFixture(into: homeURL)
        try wirePiAdapter(homeURL: homeURL)

        let result = try runPiScan(home: home)
        let nudge = scanSetupNudgeRecommended(
            hosts: result.eventHosts,
            home: home,
            pathEntries: [],
            fileManager: .default
        )
        #expect(nudge == false)

        let outcome = ScanRun.render(
            report: result.report,
            showCommand: false,
            setupNudgeRecommended: nudge,
            appearance: .pretty(colorOffPalette),
            probe: prettyProbe()
        )
        #expect(outcome.stdout.contains("rv setup") == false)
        #expect(outcome.stdout.contains("Some hosts are not wired") == false)
    }
}

@Test func scanSetupNudge_claudeUnwired_recommends() throws {
    try withTempScanHome { home, homeURL in
        try installClaudeFixture(into: homeURL)
        let result = try ScanRun.execute(
            ScanRun.Request(
                rootPath: nil,
                home: home,
                hostFilter: .claude,
                timeWindow: .all,
                packIDs: dayOnePackIDs,
                allEvents: false,
                includeGlobs: [],
                bounds: .default,
                now: Date(),
                fileManager: .default
            )
        )
        #expect(result.eventHosts.contains(.claude))
        let nudge = scanSetupNudgeRecommended(
            hosts: result.eventHosts,
            home: home,
            pathEntries: [],
            fileManager: .default
        )
        #expect(nudge)
    }
}

@Test func scanSessionsFlags_exposesFailOnFindings() throws {
    let flags = try ScanSessionsFlags.parse([])
    #expect(flags.failOnFindings == false)
    let gated = try ScanSessionsFlags.parse(["--fail-on-findings"])
    #expect(gated.failOnFindings)
}

@Test func scanRobot_setupNudgeFieldFollowsCLI() throws {
    try withTempScanHome { home, _ in
        let result = try ScanRun.execute(.fixture(home: home))
        let off = try JSONSerialization.jsonObject(
            with: Data(renderScanSessionsRobot(
                from: result.report,
                showCommand: false,
                setupNudge: false
            ).utf8)
        ) as? [String: Any]
        #expect(off?["setup_nudge"] as? Bool == false)
        let on = try JSONSerialization.jsonObject(
            with: Data(renderScanSessionsRobot(
                from: result.report,
                showCommand: false,
                setupNudge: true
            ).utf8)
        ) as? [String: Any]
        #expect(on?["setup_nudge"] as? Bool == true)
    }
}

private enum ScanNudgeFixtureError: Error {
    case missing(String)
}
