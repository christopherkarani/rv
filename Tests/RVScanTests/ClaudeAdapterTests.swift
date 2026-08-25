import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func claudeAdapter_hostIsClaude() {
    #expect(ClaudeSessionStoreAdapter().host == .claude)
}

@Test func claudeAdapter_rootsUnderDotClaudeProjects() throws {
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home-claude"))
    let roots = ClaudeSessionStoreAdapter().roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].lastPathComponent == "projects")
    #expect(roots[0].deletingLastPathComponent().lastPathComponent == ".claude")
}

@Test func claudeAdapter_recognizesJsonlOnly() {
    let adapter = ClaudeSessionStoreAdapter()
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/tmp/a.jsonl")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/tmp/a.JSONL")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/tmp/noise.txt")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/tmp/session.json")) == false)
}

@Test func claudeAdapter_extractsGitResetHardFromFixture() throws {
    let fixture = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
    let data = try Data(contentsOf: fixture)
    let events = try ClaudeSessionStoreAdapter().extract(fileURL: fixture, data: data)

    #expect(events.count == 1)
    #expect(events[0].host == .claude)
    #expect(events[0].command.rawValue == "git reset --hard")
    #expect(events[0].sessionID == "ac001-session")
    #expect(events[0].sourcePath == fixture.path)
    #expect(events[0].occurredAt != nil)
}

@Test func claudeAdapter_extractsGitStatusAllowCandidate() throws {
    let fixture = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/allow-status.jsonl")
    let data = try Data(contentsOf: fixture)
    let events = try ClaudeSessionStoreAdapter().extract(fileURL: fixture, data: data)
    #expect(events.map(\.command.rawValue) == ["git status"])
}

@Test func claudeAdapter_skipsUnrecognizedFilesInTempHomeTree() throws {
    try withTempHome { homeURL in
        let projects = homeURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-rv-scan-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let reset = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
        let noise = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/noise.txt")
        try FileManager.default.copyItem(
            at: reset,
            to: projects.appendingPathComponent("ac001-reset-hard.jsonl")
        )
        try FileManager.default.copyItem(
            at: noise,
            to: projects.appendingPathComponent("noise.txt")
        )
        try Data("{\"not\":\"jsonl-shape\"}\n".utf8).write(
            to: projects.appendingPathComponent("junk.dat")
        )

        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = ClaudeSessionStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        let walk = try DirectoryWalker(bounds: .default).walk(root: root)

        var extracted: [ExtractedEvent] = []
        for fileURL in walk.fileURLs {
            guard adapter.recognizes(fileURL: fileURL) else { continue }
            let data = try Data(contentsOf: fileURL)
            extracted.append(contentsOf: try adapter.extract(fileURL: fileURL, data: data))
        }

        #expect(walk.fileURLs.map(\.lastPathComponent).sorted() == [
            "ac001-reset-hard.jsonl",
            "junk.dat",
            "noise.txt",
        ])
        #expect(extracted.map(\.command.rawValue) == ["git reset --hard"])
    }
}

@Test func claudeAdapter_usesTempHomeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        #expect(homeURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(homeURL.path.hasPrefix(live) == false)
        }
        let home = try #require(ScanHome(validating: homeURL.path))
        let roots = ClaudeSessionStoreAdapter().roots(home: home)
        #expect(roots.allSatisfy { $0.path.hasPrefix(homeURL.path) })
    }
}

@Test func claudeAdapter_skipsMalformedLinesAndNonShellTools() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","timestamp":"2026-08-20T12:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"1","name":"Bash","input":{"command":"git reset --hard"}}]}}
    not-json
    {"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"x"}}]}}
    {"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":""}}]}}
    """
    let url = URL(fileURLWithPath: "/tmp/inline-claude.jsonl")
    let events = try ClaudeSessionStoreAdapter().extract(
        fileURL: url,
        data: Data(payload.utf8)
    )
    #expect(events.map(\.command.rawValue) == ["git reset --hard"])
}
