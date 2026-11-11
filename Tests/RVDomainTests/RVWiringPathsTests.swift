import Foundation
import Testing
@testable import RVDomain

@Suite("rv wiring paths")
struct RVWiringPathsTests {
    static let home = "/Users/me"

    @Test("hook configs, adapters, binaries and units are wiring", arguments: [
        "/Users/me/.claude/settings.json",
        "~/.claude/settings.json",
        "$HOME/.claude/hooks/rv-guard.py",
        "/Users/me/.codex/hooks.json",
        "/Users/me/.codex/hooks/rv-guard.py",
        "/Users/me/.cursor/hooks.json",
        "/Users/me/.cursor/hooks/rv-guard.py",
        "/Users/me/.gemini/config/hooks.json",
        "/Users/me/.gemini/config/hooks/rv-guard.py",
        "/Users/me/.grok/hooks/rv.json",
        "/Users/me/.pi/agent/extensions/rv-guard.ts",
        "/Users/me/.config/opencode/plugins/rv-guard.js",
        "/Users/me/.config/opencode/plugins/rv-guard-tui.js",
        "/Users/me/.config/opencode/rv-guard-tui-ask/package.json",
        "/Users/me/.config/opencode/opencode.json",
        "/Users/me/.openclaw/extensions/rv-guard/index.js",
        "/Users/me/.hermes/plugins/rv-guard/__init__.py",
        "/Users/me/.config/muse/settings.json",
        "/Users/me/.config/muse/rv-hooks.json",
        "/Users/me/.local/bin/rv",
        "/Users/me/.local/bin/rv-cli",
        "/Users/me/.local/bin/rvd",
        "/Users/me/.local/bin/rv-workspace-host",
        "/Users/me/.local/bin/rv-isolation-exec",
        "/Users/me/.local/bin/rv-pty-claim",
        "/Users/me/.local/bin/rv-macvm-agent",
        "/Users/me/.local/bin/rv_RVPacks.bundle/Contents/Resources/packs/core.git.json",
        "/Users/me/.local/bin/libswiftCompatibilitySpan.dylib",
        // Linux Swift runtime install.sh stages beside rv-cli/rvd ($ORIGIN).
        "/Users/me/.local/bin/libswiftCore.so",
        "/Users/me/.local/bin/libFoundation.so",
        "/Users/me/.local/bin/libicuucswift.so.76",
        "/Users/me/.local/bin/.rv-swiftlibs",
        "/Users/me/.local/bin/.rvd.installing",
        "/Users/me/.config/environment.d/50-rv.conf",
        "/Users/me/.config/systemd/user.conf",
        "/Users/me/.config/systemd/user.conf.d/env.conf",
        "/Users/me/.config/systemd/user/service.d/env.conf",
        "/Users/me/.config/systemd/user/default.target.wants/dev.rv.evaluate.service",
        "/Users/me/Library/LaunchAgents/dev.rv.evaluate.plist",
        "/Users/me/Library/LaunchAgents/dev.rv.mcp-custodian.plist",
        "/Users/me/.config/systemd/user/dev.rv.evaluate.service",
        "/Users/me/.config/systemd/user/dev.rv.evaluate.service.d/override.conf",
        "/Users/me/Applications/RVApprovals.app/Contents/MacOS/rv-mcp-custodian",
    ])
    func wiring(path: String) {
        #expect(RVWiringPaths.matches(path, home: Self.home), "\(path)")
    }

    #if canImport(Darwin)
    @Test("wiring paths match case variants on Darwin")
    func wiringFoldsCase() {
        #expect(RVWiringPaths.matches("/Users/me/.CLAUDE/Settings.json", home: "/Users/me"))
        #expect(RVWiringPaths.matches("/users/ME/.local/BIN/RVD", home: "/Users/me"))
    }
    #endif

    @Test("everything else is not", arguments: [
        "/Users/me/.claude/CLAUDE.md",
        "/Users/me/.claude/projects/x/memory.md",
        "/Users/me/.cursor/mcp.json",
        "/Users/me/.local/bin/node",
        "/Users/me/.local/bin/rvm",
        "/Users/me/Library/LaunchAgents/com.example.agent.plist",
        "/Users/me/.config/systemd/user/syncthing.service",
        "/Users/me/src/app/.claude/settings.json",
        "/Users/other/.claude/settings.json",
        "/tmp/.claude/settings.json",
        "relative/.claude/settings.json",
    ])
    func notWiring(path: String) {
        #expect(RVWiringPaths.matches(path, home: Self.home) == false, "\(path)")
    }

    @Test("adapter matching is exact: other rv-guard names are not wiring", arguments: [
        "/Users/me/rv-guard-notes.txt",
        "/Users/me/src/rv-guard/main.swift",
        "/Users/me/.claude/rv-guard-backup.md",
        "/Users/me/.claude/hooks/rv-guard-old.py",
        "/Users/me/Downloads/rv-guard.py",
    ])
    func adapterNamesExact(path: String) {
        #expect(RVWiringPaths.matches(path, home: Self.home) == false, "\(path)")
    }

    @Test("proper ancestors of wiring entries, below home, are ancestors", arguments: [
        "/Users/me/.claude", "~/.claude", "/Users/me/.claude/hooks", "/Users/me/.local", "/Users/me/.local/bin",
        "/Users/me/Library", "/Users/me/Library/LaunchAgents", "/Users/me/.config", "/Users/me/.config/systemd",
        "/Users/me/.config/systemd/user", "/Users/me/.config/opencode", "/Users/me/.config/opencode/plugins",
        "/Users/me/.codex", "/Users/me/.gemini/config", "/Users/me/Applications",
    ])
    func ancestors(path: String) {
        #expect(RVWiringPaths.matchesAncestor(path, home: Self.home), "\(path)")
    }

    @Test("home itself, siblings and other trees are not ancestors", arguments: [
        "/Users/me", "/Users/me/src", "/Users/me/.claude/projects", "/tmp/.claude", "/Users/me/.config/gh",
        "/Users/other/.claude",
    ])
    func notAncestors(path: String) {
        #expect(RVWiringPaths.matchesAncestor(path, home: Self.home) == false, "\(path)")
    }

    @Test("host settings files that can disable hooks match at any scope", arguments: [
        "/Users/me/src/app/.claude/settings.json",
        "/Users/me/src/app/.claude/settings.local.json",
        "/Users/me/.claude/settings.local.json",
        "/tmp/x/.codex/hooks.json",
        "/Users/me/src/app/.codex/config.toml",
        "/Users/me/.codex/config.toml",
        "/Users/me/src/app/.cursor/hooks.json",
        "/Users/me/src/app/.gemini/settings.json",
        "relative/.gemini/config/hooks.json",
    ])
    func hostSettings(path: String) {
        #expect(RVWiringPaths.isHostSettingsFile(path), "\(path)")
    }

    @Test("other host files are not host settings", arguments: [
        "/Users/me/src/app/.claude/CLAUDE.md",
        "/Users/me/src/app/.claude/commands/x.md",
        "/Users/me/src/app/settings.json",
        "/Users/me/.cursor/mcp.json",
    ])
    func notHostSettings(path: String) {
        #expect(RVWiringPaths.isHostSettingsFile(path) == false, "\(path)")
    }

    @Test("~user expands through the user database; an unknown user does not")
    func tildeUser() throws {
        let user = NSUserName()
        let home = try #require(FileManager.default.homeDirectory(forUser: user)).path
        #expect(expandTildeUser("~\(user)/.claude") == .expanded(home + "/.claude"))
        #expect(expandTildeUser("~\(user)") == .expanded(home))
        #expect(expandTildeUser("~no-such-user-rv-test/x") == .unknownUser)
        #expect(expandTildeUser("~/x") == .notTildeUser)
        #expect(expandTildeUser("~") == .notTildeUser)
        #expect(expandTildeUser("a/~b") == .notTildeUser)
    }
}
