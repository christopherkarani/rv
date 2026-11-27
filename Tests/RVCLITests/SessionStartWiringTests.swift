import Foundation
import Testing
@testable import RVCLI

/// B4: setup also registers rv's adapter for SessionStart (Claude Code,
/// Codex) so the agent hears the house rules; uninstall strips it again.
struct SessionStartWiringTests {
    enum Host: CaseIterable { case claude, codex }

    private func merge(_ host: Host, _ existing: Data?) throws -> Data {
        switch host {
        case .claude:
            try ClaudeSettingsMerge.merge(
                existingData: existing, rvPath: "/opt/rv/bin/rv", interpreter: "/usr/bin/python3",
                adapterPath: "/tmp/home/.claude/hooks/rv-guard.py", force: false
            ).data
        case .codex:
            try CodexHooksMerge.merge(
                existingData: existing, interpreter: "/usr/bin/python3",
                adapterPath: "/tmp/home/.codex/hooks/rv-guard.py"
            ).data
        }
    }

    private func uninstall(_ host: Host, _ data: Data) throws -> Data? {
        switch host {
        case .claude: try ClaudeSettingsMerge.uninstall(existingData: data)
        case .codex: try CodexHooksMerge.uninstall(existingData: data)
        }
    }

    private func sessionStart(_ data: Data) throws -> [[String: Any]] {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        return try #require(hooks["SessionStart"] as? [[String: Any]])
    }

    @Test(arguments: Host.allCases)
    func merge_addsOneMatcherlessSessionStartGroupWithTheAdapter(_ host: Host) throws {
        let merged = try merge(host, nil)
        let groups = try sessionStart(merged)
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] == nil)
        let inner = try #require(groups[0]["hooks"] as? [[String: Any]])
        #expect(inner.count == 1)
        let command = try #require(inner[0]["command"] as? String)
        #expect(command.contains("rv-guard.py"))
        #expect(inner[0]["type"] as? String == "command")
    }

    /// Re-running setup replaces rv's group; it never piles up.
    @Test(arguments: Host.allCases)
    func merge_isIdempotent(_ host: Host) throws {
        let once = try merge(host, nil)
        let twice = try merge(host, once)
        #expect(try sessionStart(twice).count == 1)
        #expect(once == twice)
    }

    @Test(arguments: Host.allCases)
    func foreignSessionStartHooks_survivesMergeAndUninstall(_ host: Host) throws {
        let existing = Data("""
            {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi","timeout":5}]}]}}
            """.utf8)
        let merged = try merge(host, existing)
        #expect(try sessionStart(merged).count == 2)
        let removed = try #require(try uninstall(host, merged))
        let left = try sessionStart(removed)
        #expect(left.count == 1)
        let inner = try #require(left[0]["hooks"] as? [[String: Any]])
        #expect(inner[0]["command"] as? String == "echo hi")
    }

    @Test(arguments: Host.allCases)
    func uninstall_removesEverythingSetupWrote(_ host: Host) throws {
        #expect(try uninstall(host, try merge(host, nil)) == nil)
    }

    /// Inspection still reads the pre-tool list only: a SessionStart hook
    /// cannot make a host look wired.
    @Test func claudeInspection_ignoresSessionStartAlone() {
        let data = Data("""
            {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"RV_BINARY=/opt/rv/bin/rv /usr/bin/python3 -I -S /tmp/home/.claude/hooks/rv-guard.py","timeout":90}]}]}}
            """.utf8)
        #expect(ClaudeSettingsMerge.inspectionState(of: data) != .wired(bakedPath: "/opt/rv/bin/rv"))
    }
}
