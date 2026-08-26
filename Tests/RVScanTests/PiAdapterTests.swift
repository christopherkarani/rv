import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func piAdapter_hostAndRoots() throws {
    let adapter = PiStoreAdapter()
    #expect(adapter.host == .pi)
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-pi-home"))
    let roots = adapter.roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].path.hasSuffix("/.pi/agent/sessions"))
}

@Test func piAdapter_extractsBashToolCallCommand() throws {
    let adapter = PiStoreAdapter()
    let fixture = try fixtureURL("pi/session.jsonl")
    #expect(adapter.recognizes(fileURL: fixture))
    let data = try Data(contentsOf: fixture)
    let events = try adapter.extract(fileURL: fixture, data: data)
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.host == .pi })
    #expect(events.allSatisfy { $0.sessionID == "pi-sess-fixture-1" })
    #expect(events.allSatisfy { $0.sourcePath == fixture.path })
}

@Test func piAdapter_skipsUnrecognizedExtension() throws {
    let adapter = PiStoreAdapter()
    let other = URL(fileURLWithPath: "/tmp/notes.txt")
    #expect(adapter.recognizes(fileURL: other) == false)
}

@Test func piAdapter_hostFilterIgnoresGrokFixture() throws {
    let adapter = PiStoreAdapter()
    let grok = try fixtureURL("grok/chat_history.jsonl")
    #expect(adapter.recognizes(fileURL: grok))
    let data = try Data(contentsOf: grok)
    let events = try adapter.extract(fileURL: grok, data: data)
    #expect(events.isEmpty)
}

@Test func piAdapter_tempTreeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        let sessions = homeURL
            .appendingPathComponent(".pi/agent/sessions/--tmp--", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let dest = sessions.appendingPathComponent("session.jsonl")
        try Data(contentsOf: fixtureURL("pi/session.jsonl")).write(to: dest)

        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = PiStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(root.path.hasPrefix(live) == false)
        }
        let data = try Data(contentsOf: dest)
        let events = try adapter.extract(fileURL: dest, data: data)
        #expect(events.count == 2)
    }
}
