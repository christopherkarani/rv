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
}
