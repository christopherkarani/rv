import Foundation
import Testing
import RVDomain
import RVPolicy

struct HostModeStoreTests {
    @Test func missingConfig_everyHostIsBlock() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        #expect(store.load().isEmpty)
        for host in HookHost.allCases {
            #expect(store.mode(for: host) == .block)
        }
    }

    @Test func save_roundTripsAndKeepsOtherKeys() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"guard":{"mode":"enforce"},"safety":{"level":"strict"}}"#.utf8).write(to: store.configFile)
        try store.save(.observe, for: .claude)
        try store.save(.off, for: .cursor)
        #expect(store.load() == [.claude: .observe, .cursor: .off])
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile)) as? [String: Any])
        let guardObject = try #require(root["guard"] as? [String: Any])
        #expect(guardObject["mode"] as? String == "enforce")
        #expect((guardObject["hosts"] as? [String: String]) == ["claude": "observe", "cursor": "off"])
        #expect((root["safety"] as? [String: String]) == ["level": "strict"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.configFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// An explicit `block` must outrank a global `guard.mode: observe`, so it
    /// is stored rather than removed.
    @Test func saveBlock_persistsAnExplicitEntry() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"guard":{"mode":"observe"}}"#.utf8).write(to: store.configFile)
        try store.save(.observe, for: .codex)
        try store.save(.block, for: .codex)
        #expect(store.load() == [.codex: .block])
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile)) as? [String: Any])
        let guardObject = try #require(root["guard"] as? [String: Any])
        #expect(guardObject["mode"] as? String == "observe")
        #expect((guardObject["hosts"] as? [String: String]) == ["codex": "block"])
    }

    @Test func unknownHostsAndValuesAreIgnored() {
        let config: [String: Any] = [
            "guard": ["hosts": ["claude": "OBSERVE", "nope": "off", "cursor": "loud", "codex": 3]],
        ]
        #expect(HostModeStore.modes(inConfig: config) == [.claude: .observe])
        #expect(HostModeStore.modes(inConfig: nil).isEmpty)
        #expect(HostModeStore.modes(inConfig: ["guard": "observe"]).isEmpty)
    }

    @Test func save_refusesToClobberAnUnreadableConfig() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.configFile)
        #expect(throws: HostModeStoreError.unreadableConfig) {
            try store.save(.observe, for: .claude)
        }
        #expect(try String(contentsOf: store.configFile, encoding: .utf8) == "{not json")
    }

    @Test(arguments: [
        #"[1, 2]"#,
        #""observe""#,
        #"{"guard":"observe","safety":{"level":"strict"}}"#,
        #"{"guard":null}"#,
        #"{"guard":{"mode":"observe","hosts":["claude"]}}"#,
        #"{"guard":{"hosts":"off"}}"#,
    ])
    func save_refusesToReplaceANonObjectGuardOrRoot(json: String) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.configFile)
        #expect(throws: HostModeStoreError.unreadableConfig) {
            try store.save(.block, for: .claude)
        }
        #expect(try String(contentsOf: store.configFile, encoding: .utf8) == json)
    }

    @Test func looserOrder() {
        #expect(HostMode.observe.isLooser(than: .block))
        #expect(HostMode.off.isLooser(than: .block))
        #expect(HostMode.off.isLooser(than: .observe))
        #expect(HostMode.block.isLooser(than: .off) == false)
        #expect(HostMode.observe.isLooser(than: .off) == false)
        #expect(HostMode.observe.isLooser(than: .observe) == false)
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-host-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
