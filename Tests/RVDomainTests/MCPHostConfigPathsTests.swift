import Foundation
import Testing
@testable import RVDomain

@Suite("MCP host config paths")
struct MCPHostConfigPathsTests {
    static let home = "/Users/me"

    #if os(macOS)
    static let platformFiles = [
        "/Users/me/Library/Application Support/Claude/claude_desktop_config.json",
        "/Users/me/Library/Application Support/Code/User/mcp.json",
        "/Library/Application Support/ClaudeCode/managed-mcp.json",
        "/Library/Application Support/ClaudeCode/managed-settings.json",
        "/Library/Application Support/ClaudeCode/managed-settings.d/10-team.json",
    ]
    #else
    static let platformFiles = [
        "/Users/me/.config/Claude/claude_desktop_config.json",
        "/Users/me/.config/Code/User/mcp.json",
        "/etc/claude-code/managed-mcp.json",
        "/etc/claude-code/managed-settings.json",
        "/etc/claude-code/managed-settings.d/10-team.json",
    ]
    #endif

    @Test("every host MCP config the inventory reads is guarded", arguments: [
        "/Users/me/.claude.json",
        "~/.claude.json",
        "$HOME/.claude.json",
        "${HOME}/.claude.json",
        "/Users/me/.cursor/mcp.json",
        "/Users/me/.codex/config.toml",
        "/Users/me/.config/opencode/opencode.json",
        "/Users/me/.config/opencode/opencode.jsonc",
        "/Users/me/.gemini/settings.json",
        "/Users/me/.gemini/antigravity/mcp_config.json",
        "/Users/me/.codeium/windsurf/mcp_config.json",
        "/Users/me/.config/muse/settings.json",
        "/Users/me/.claude/plugins/installed_plugins.json",
        "/Users/me/.claude/plugins/cache/market/tool/1.0.0/.mcp.json",
        "/Users/me/.claude/plugins/cache/market/tool/1.0.0/servers.json",
        "/work/repo/.mcp.json",
        "/work/repo/sub/.mcp.json",
        "/work/repo/.cursor/mcp.json",
        "/work/repo/.vscode/mcp.json",
        "/work/repo/opencode.json",
        "/work/repo/.gemini/settings.json",
        "/work/repo/.claude/skills/tool/.claude-plugin/plugin.json",
    ] + platformFiles)
    func guarded(_ path: String) {
        #expect(MCPHostConfigPaths.isGuarded(path, home: Self.home), "\(path)")
    }

    @Test("unrelated files stay unguarded", arguments: [
        "/tmp/claude.json",
        "/Users/me/claude.json",
        "/work/repo/claude.json",
        "/work/repo/.claude.json",
        "/work/repo/mcp.json",
        "/work/repo/settings.json",
        "/work/repo/.vscode/settings.json",
        "/work/repo/.cursor/rules/style.mdc",
        "/Users/me/.cursor/rules.md",
        "/Users/me/.claude/plugins-notes.md",
        "/Users/me/.claude/skills/tool/SKILL.md",
        "/Users/other/.cursor/mcp.json.bak",
        "/Users/me",
    ])
    func unguarded(_ path: String) {
        #expect(MCPHostConfigPaths.isGuarded(path, home: Self.home) == false, "\(path)")
    }

    #if canImport(Darwin)
    @Test func caseFoldsOnDarwin() {
        #expect(MCPHostConfigPaths.isGuarded("/Users/me/.CLAUDE.json", home: Self.home))
        #expect(MCPHostConfigPaths.isGuarded("/work/repo/.Cursor/MCP.json", home: Self.home))
    }
    #endif

    @Test("directories that hold a guarded file", arguments: [
        "/Users/me/.cursor",
        "/Users/me/.config/opencode",
        "/Users/me/.codeium",
        "/Users/me/.claude",
        "~/.gemini",
        "/work/repo/.cursor",
        "/work/repo/.vscode",
        "/work/repo/.gemini",
        "/work/repo/tool/.claude-plugin",
    ])
    func containers(_ path: String) {
        #expect(MCPHostConfigPaths.isGuardedContainer(path, home: Self.home), "\(path)")
    }

    @Test("ordinary directories are not containers", arguments: [
        "/Users/me",
        "/work/repo",
        "/work/repo/src",
        "/Users/me/projects",
        "/tmp",
    ])
    func notContainers(_ path: String) {
        #expect(MCPHostConfigPaths.isGuardedContainer(path, home: Self.home) == false, "\(path)")
    }

    @Test func mentionsNameEveryGuardedFile() {
        for word in [
            "/Users/me/.claude.json", "~/.claude.json", ".mcp.json", "x/.cursor/mcp.json",
            "claude_desktop_config.json", "mcp_config.json", "opencode.jsonc", "managed-mcp.json",
            "~/.claude/plugins/cache", ".gemini/settings.json", "muse/settings.json", ".codex/config.toml",
            "plugin/.claude-plugin/plugin.json", "managed-settings.json", "managed-settings.d/a.json",
            "open('/Users/me/.CLAUDE.JSON','w')",
        ] {
            #expect(MCPHostConfigPaths.mentions(word), "\(word)")
        }
        for word in ["claude.json", "settings.json", "config.toml", "README.md", "src/mcp_client.py", "plugins"] {
            #expect(MCPHostConfigPaths.mentions(word) == false, "\(word)")
        }
    }

    @Test func fixedFilesAreGuardedAbsolutePaths() {
        let files = MCPHostConfigPaths.fixedFiles(home: Self.home)
        #expect(files.contains("/Users/me/.claude.json"))
        #expect(files.contains("/Users/me/.cursor/mcp.json"))
        for file in files {
            #expect(file.hasPrefix("/"))
            #expect(MCPHostConfigPaths.isGuarded(file, home: Self.home), "\(file)")
        }
    }

    @Test func everyLocationIsGuardedAtItsOwnPath() {
        for location in MCPHostConfigLocation.allCases {
            guard let path = location.path(home: Self.home, codexHome: nil, project: "/work/repo") else {
                Issue.record("\(location) has no path")
                continue
            }
            #expect(MCPHostConfigPaths.isGuarded(path, home: Self.home), "\(location)")
            #expect(MCPHostConfigPaths.mentions(path), "\(location)")
        }
    }

    @Test func filesystemContextCarriesTheGuardThroughCodable() throws {
        let guarded = FilesystemAnalysisContext(
            homeDirectory: HomePath(validating: Self.home),
            mcpHostConfigGuard: MCPHostConfigGuard(resolvedAliases: ["/Users/me/dotfiles/claude.json"]))
        let data = try JSONEncoder().encode(guarded)
        #expect(try JSONDecoder().decode(FilesystemAnalysisContext.self, from: data) == guarded)
        let legacy = try JSONDecoder().decode(FilesystemAnalysisContext.self, from: Data(#"{"facts":[]}"#.utf8))
        #expect(legacy.mcpHostConfigGuard == nil)
    }

    @Test func ruleIsNotAPinnedPack() {
        #expect(MCPHostConfigPaths.ruleID.pack == .coreMCP)
        #expect(MCPHostConfigPaths.ruleID.pack != .coreSecrets)
    }
}
