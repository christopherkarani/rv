import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func cursorAdapter_hostAndRoots() throws {
    let adapter = CursorStoreAdapter()
    #expect(adapter.host == .cursor)
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-cursor-home"))
    let roots = adapter.roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].path.hasSuffix("/.cursor/projects"))
}

@Test func cursorAdapter_recognizesAgentTranscriptsJsonlOnly() {
    let adapter = CursorStoreAdapter()
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/agent-transcripts/sess.jsonl")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/sessions/sess.jsonl")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/agent-transcripts/sess.json")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/noise.txt")) == false)
}

@Test func cursorAdapter_extractsBeforeShellExecution() throws {
    let fixture = try fixtureURL("cursor/before-shell.jsonl")
    let data = try Data(contentsOf: fixture)
    let events = try CursorStoreAdapter().extract(fileURL: fixture, data: data)
    #expect(events.map(\.command.rawValue) == ["git reset --hard"])
    #expect(events.allSatisfy { $0.host == .cursor })
    #expect(events.allSatisfy { $0.sessionID == "sess_cursor_1" })
    #expect(events.allSatisfy { $0.sourcePath == fixture.path })
}

@Test func cursorAdapter_extractsPreToolUseShell() throws {
    let fixture = try fixtureURL("cursor/pretool-shell.jsonl")
    let data = try Data(contentsOf: fixture)
    let events = try CursorStoreAdapter().extract(fileURL: fixture, data: data)
    #expect(events.map(\.command.rawValue) == ["git status"])
    #expect(events.allSatisfy { $0.sessionID == "sess_hook" })
}

@Test func cursorAdapter_emptyOrUnreadableThrows() throws {
    let adapter = CursorStoreAdapter()
    let source = URL(fileURLWithPath: "/tmp/cursor-unreadable.jsonl")
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data())
    }
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data([0xFF, 0xFE]))
    }
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("not-json\n".utf8))
    }
}

@Test func cursorAdapter_skipsMalformedLinesAndNonShell() throws {
    let payload = """
    {"conversation_id":"s","hook_event_name":"beforeShellExecution","command":"git reset --hard"}
    not-json
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"path":"x"}}
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"git status"}}
    """
    let url = URL(fileURLWithPath: "/tmp/inline-cursor.jsonl")
    let events = try CursorStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
}

@Test func cursorAdapter_tempTreeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = CursorStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(root.path.hasPrefix(live) == false)
        }
    }
}

@Test func cursorAdapter_extractUsesProvidedDataNotPath() throws {
    try withTempHome { homeURL in
        let store = homeURL
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("ws", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let fileURL = store.appendingPathComponent("sess.jsonl")
        let fixture = try fixtureURL("cursor/before-shell.jsonl")
        let diskBytes = try Data(contentsOf: fixture)
        try diskBytes.write(to: fileURL)

        let adapter = CursorStoreAdapter()
        #expect(throws: CursorStoreError.unreadable(sourcePath: fileURL.path)) {
            _ = try adapter.extract(fileURL: fileURL, data: Data("not-json\n".utf8))
        }

        try FileManager.default.removeItem(at: fileURL)
        try Data("different-on-disk\n".utf8).write(to: fileURL)
        let events = try adapter.extract(fileURL: fileURL, data: diskBytes)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .cursor })
        #expect(events.allSatisfy { $0.sessionID == "sess_cursor_1" })
        #expect(events.allSatisfy { $0.sourcePath == fileURL.path })
    }
}
