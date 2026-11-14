import Foundation
import RVDomain
import Testing
@testable import RVMCP

@Suite("MCP read-only sources")
struct MCPReadOnlySourcesTests {
    typealias FakeHome = MCPInventoryTests.FakeHome

    private func discover(_ fake: FakeHome, project: URL? = nil, environment: [String: String] = [:]) -> MCPInventory {
        MCPInventory.discover(
            home: fake.home, project: project, environment: environment,
            managedDirectory: fake.root.appendingPathComponent("managed").path)
    }

    @Test func setupTargetsCoverEveryWritableLocationOnce() {
        let home = URL(fileURLWithPath: "/Users/me")
        let project = URL(fileURLWithPath: "/work/repo")
        let files = MCPHostFile.all(home: home, project: project, environment: [:])
        for location in MCPHostConfigLocation.allCases {
            let path = location.path(home: home.path, codexHome: nil, project: project.path)
            let listed = files.contains { $0.path.path == path }
            #expect(listed == (MCPHostFile.setupFormat(location) != nil), "\(location)")
        }
        #expect(files.contains { $0.scope == .managed } == false)
    }

    @Test func managedFilesAreInventoried() throws {
        let fake = FakeHome()
        let managed = fake.root.appendingPathComponent("managed")
        try fake.write("managed-mcp.json", under: managed, #"{"mcpServers": {"org": {"command": "org-mcp"}}}"#)
        try fake.write(
            "managed-settings.json", under: managed,
            #"{"managedMcpServers": {"docs": {"type": "http", "url": "https://docs.example/mcp"}}}"#)
        try fake.write(
            "managed-settings.d/20-team.json", under: managed,
            #"{"managedMcpServers": {"team": {"type": "sse", "url": "https://team.example/sse"}}}"#)
        try fake.write("managed-settings.d/notes.txt", under: managed, "ignored")
        let inventory = discover(fake)
        let managedEntries = inventory.entries.filter { $0.scope == .managed }
        #expect(managedEntries.map(\.name).sorted() == ["docs", "org", "team"])
        #expect(managedEntries.allSatisfy { $0.host == .claudeCode })
        #expect(managedEntries.first { $0.name == "team" }?.remoteTransport == .sse)
        #expect(inventory.problems.isEmpty)
    }

    @Test func installedPluginsDeclareServers() throws {
        let fake = FakeHome()
        let plugin = fake.root.appendingPathComponent("home/.claude/plugins/cache/market/tools/1.0.0")
        let other = fake.root.appendingPathComponent("home/.claude/plugins/cache/market/extra/2.0.0")
        try fake.write(".claude/plugins/installed_plugins.json", #"""
        {"version": 2, "plugins": {
          "tools@market": [{"scope": "user", "installPath": "\#(plugin.path)", "version": "1.0.0"}],
          "extra@market": [{"scope": "user", "installPath": "\#(other.path)", "version": "2.0.0"}],
          "elsewhere@market": [{"scope": "project", "projectPath": "/somewhere/else", "installPath": "\#(other.path)"}]
        }}
        """#)
        try fake.write(".mcp.json", under: plugin, #"{"mcpServers": {"search": {"type": "http", "url": "https://s.example/mcp"}}}"#)
        try fake.write(
            ".claude-plugin/plugin.json", under: plugin,
            #"{"name": "tools", "mcpServers": [{"inline": {"command": "${CLAUDE_PLUGIN_ROOT}/bin/srv"}}, "./more.json", "../escape.json"]}"#)
        try fake.write("more.json", under: plugin, #"{"more": {"command": "more-mcp"}}"#)
        try fake.write("escape.json", under: plugin.deletingLastPathComponent(), #"{"escaped": {"command": "x"}}"#)
        try fake.write(
            ".claude-plugin/plugin.json", under: other, #"{"name": "extra", "mcpServers": {"x": {"command": "x-mcp"}}}"#)
        try fake.write(".claude/settings.json", #"{"enabledPlugins": {"extra@market": false}}"#)

        let inventory = discover(fake)
        let pluginEntries = inventory.entries.filter { if case .plugin = $0.scope { true } else { false } }
        #expect(Set(pluginEntries.map { "\($0.scope.label):\($0.name)" }) == [
            "plugin tools@market:search", "plugin tools@market:inline", "plugin tools@market:more",
            "plugin extra@market:x",
        ])
        #expect(pluginEntries.first { $0.name == "x" }?.isDisabled == true)
        #expect(pluginEntries.first { $0.name == "search" }?.isDisabled == false)
        #expect(inventory.problems.isEmpty)
    }

    @Test func pluginCacheDirectoryOverride() throws {
        let fake = FakeHome()
        let cache = fake.root.appendingPathComponent("alt-plugins")
        let plugin = cache.appendingPathComponent("cache/m/p/1")
        try fake.write(
            "installed_plugins.json", under: cache,
            #"{"version": 2, "plugins": {"p@m": [{"scope": "user", "installPath": "\#(plugin.path)"}]}}"#)
        try fake.write(".mcp.json", under: plugin, #"{"mcpServers": {"alt": {"command": "alt"}}}"#)
        let inventory = discover(fake, environment: ["CLAUDE_CODE_PLUGIN_CACHE_DIR": cache.path])
        #expect(inventory.entries.map(\.name) == ["alt"])
    }

    @Test func skillsDirectoryPluginsAreInventoried() throws {
        let fake = FakeHome()
        try fake.write(
            ".claude/skills/helper/.claude-plugin/plugin.json",
            #"{"name": "helper", "mcpServers": {"h": {"command": "h-mcp"}}}"#)
        try fake.write(".claude/skills/plain/SKILL.md", "no manifest")
        try fake.write(".claude/skills/team/.claude-plugin/plugin.json", under: fake.project, #"{"name": "team"}"#)
        try fake.write(".claude/skills/team/.mcp.json", under: fake.project, #"{"mcpServers": {"t": {"command": "t"}}}"#)
        let inventory = discover(fake, project: fake.project)
        let labels = Set(inventory.entries.filter { if case .plugin = $0.scope { true } else { false } }
            .map { "\($0.scope.label):\($0.name)" })
        #expect(labels == ["plugin helper@skills-dir:h", "plugin team@skills-dir:t"])
    }

    @Test func unreadablePluginRecordsAreAProblem() throws {
        let fake = FakeHome()
        try fake.write(".claude/plugins/installed_plugins.json", "{not json")
        let inventory = discover(fake)
        #expect(inventory.problems.map(\.message) == ["could not parse JSON"])
        #expect(inventory.problems.first?.path.hasSuffix("installed_plugins.json") == true)
    }
}
