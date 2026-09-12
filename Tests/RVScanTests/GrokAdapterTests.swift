import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func grokAdapter_hostAndRoots() throws {
    let adapter = GrokStoreAdapter()
    #expect(adapter.host == .grok)
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-grok-home"))
    let roots = adapter.roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].path.hasSuffix("/.grok/sessions"))
}

@Test func grokAdapter_extractsShellToolCallCommand() throws {
    let adapter = GrokStoreAdapter()
    let fixture = try fixtureURL("grok/chat_history.jsonl")
    #expect(adapter.recognizes(fileURL: fixture))
    let data = try Data(contentsOf: fixture)
    let fileURL = URL(fileURLWithPath: "/tmp/sess-grok-1/chat_history.jsonl")
    let events = try adapter.extract(fileURL: fileURL, data: data)
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.host == .grok })
    #expect(events.allSatisfy { $0.sessionID == "sess-grok-1" })
    // No `.grok/sessions/<cwd>/` layout — recovery would guess. Leave nil.
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func grokAdapter_percentEncodedAbsoluteSlug_fillsWorkingDirectory() throws {
    let adapter = GrokStoreAdapter()
    let data = try Data(contentsOf: fixtureURL("grok/chat_history.jsonl"))
    let fileURL = URL(fileURLWithPath: "/tmp/rv-scan-grok-home")
        .appendingPathComponent(".grok/sessions/%2Ftmp%2Frv-ws/sess-enc/chat_history.jsonl")
    let events = try adapter.extract(fileURL: fileURL, data: data)
    #expect(events.isEmpty == false)
    #expect(events.allSatisfy { $0.sessionID == "sess-enc" })
    #expect(events.allSatisfy { $0.workingDirectory?.rawValue == "/tmp/rv-ws" })
}

@Test func grokAdapter_ambiguousRelativeSlug_leavesWorkingDirectoryNil() throws {
    let adapter = GrokStoreAdapter()
    let data = try Data(contentsOf: fixtureURL("grok/chat_history.jsonl"))
    let fileURL = URL(fileURLWithPath: "/tmp/rv-scan-grok-home")
        .appendingPathComponent(".grok/sessions/my-project/sess-rel/chat_history.jsonl")
    let events = try adapter.extract(fileURL: fileURL, data: data)
    #expect(events.isEmpty == false)
    #expect(events.allSatisfy { $0.sessionID == "sess-rel" })
    // Relative layout slug is not a filesystem path without live I/O. Do not guess.
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func grokAdapter_recognizesOnlyChatHistory() throws {
    let adapter = GrokStoreAdapter()
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/chat_history.jsonl")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/updates.jsonl")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/session.jsonl")) == false)
}

@Test func grokAdapter_hostFilterIgnoresPiFixture() throws {
    let adapter = GrokStoreAdapter()
    let pi = try fixtureURL("pi/session.jsonl")
    #expect(adapter.recognizes(fileURL: pi) == false)
}

@Test func grokAdapter_tempTreeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        let sessionDir = homeURL
            .appendingPathComponent(".grok/sessions/%2Ftmp/sess-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let dest = sessionDir.appendingPathComponent("chat_history.jsonl")
        try Data(contentsOf: fixtureURL("grok/chat_history.jsonl")).write(to: dest)

        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = GrokStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(root.path.hasPrefix(live) == false)
        }
        let data = try Data(contentsOf: dest)
        let events = try adapter.extract(fileURL: dest, data: data)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.sessionID == "sess-a" })
        #expect(events.allSatisfy { $0.workingDirectory?.rawValue == "/tmp" })
    }
}
