import Foundation
import Testing
@testable import RVCLI

private let antigravityRvPath = "/usr/local/bin/rv"
private let antigravityAdapter = "/tmp/home/.gemini/config/hooks/rv-guard.py"

private func antigravityMerged(_ existing: String? = nil, force: Bool = false) throws -> Data {
    let data = existing.map { Data($0.utf8) }
    return try AntigravitySettingsMerge.merge(
        existingData: data,
        rvPath: antigravityRvPath,
        adapterPath: antigravityAdapter,
        force: force
    ).data
}

private func antigravityGroup(_ root: [String: Any]) throws -> [String: Any] {
    try #require(root[AntigravitySettingsMerge.hookName] as? [String: Any])
}

@Test func antigravityMerge_createsGroupedPreToolUseEntries() throws {
    let merged = try AntigravitySettingsMerge.merge(
        existingData: nil,
        rvPath: antigravityRvPath,
        adapterPath: antigravityAdapter,
        force: false
    )
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let group = try antigravityGroup(root)
    #expect(group["enabled"] as? Bool == true)
    let pre = try #require(group["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 5)
    #expect(pre.map { $0["matcher"] as? String } == AntigravitySettingsMerge.matchers)
    for entry in pre {
        let inner = try #require(entry["hooks"] as? [[String: Any]])
        #expect(inner.count == 1)
        #expect(inner[0]["type"] as? String == "command")
        #expect(inner[0]["command"] as? String == "RV_BINARY=\(antigravityRvPath) python3 \(antigravityAdapter)")
        #expect(inner[0]["timeout"] as? Int == 10)
    }
}

@Test func antigravityMerge_preservesForeignNamedHook() throws {
    let existing = """
    {
      "other-hook": {
        "enabled": true,
        "PreToolUse": [
          {
            "matcher": "run_command",
            "hooks": [
              { "type": "command", "command": "other-guard evaluate", "timeout": 10 }
            ]
          }
        ]
      }
    }
    """
    let merged = try AntigravitySettingsMerge.merge(
        existingData: Data(existing.utf8),
        rvPath: antigravityRvPath,
        adapterPath: antigravityAdapter,
        force: false
    )
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let foreign = try #require(root["other-hook"] as? [String: Any])
    let foreignPre = try #require(foreign["PreToolUse"] as? [[String: Any]])
    #expect(foreignPre.count == 1)
    let foreignInner = try #require(foreignPre[0]["hooks"] as? [[String: Any]])
    #expect(foreignInner[0]["command"] as? String == "other-guard evaluate")
    let group = try antigravityGroup(root)
    let pre = try #require(group["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 5)
}

@Test func antigravityMerge_isIdempotent() throws {
    let first = try antigravityMerged()
    let second = try AntigravitySettingsMerge.merge(
        existingData: first,
        rvPath: antigravityRvPath,
        adapterPath: antigravityAdapter,
        force: false
    )
    #expect(second.wrote == false)
    #expect(second.data == first)
}

@Test func antigravityMerge_uninstallStripsFingerprintAndKeepsForeign() throws {
    let existing = """
    {
      "other-hook": {
        "PreToolUse": [
          {
            "matcher": "run_command",
            "hooks": [
              { "type": "command", "command": "other-guard evaluate", "timeout": 10 }
            ]
          }
        ]
      },
      "rv-guard": {
        "enabled": true,
        "PreToolUse": [
          {
            "matcher": "run_command",
            "hooks": [
              { "type": "command", "command": "RV_BINARY=/r python3 /c/hooks/rv-guard.py", "timeout": 10 }
            ]
          }
        ]
      }
    }
    """
    let next = try #require(try AntigravitySettingsMerge.uninstall(existingData: Data(existing.utf8)))
    let root = try #require(JSONSerialization.jsonObject(with: next) as? [String: Any])
    #expect(root["rv-guard"] == nil)
    #expect(root["other-hook"] as? [String: Any] != nil)
}

@Test func antigravityMerge_uninstallEmptyReturnsNil() throws {
    let existing = """
    {
      "rv-guard": {
        "enabled": true,
        "PreToolUse": [
          {
            "matcher": "run_command",
            "hooks": [
              { "type": "command", "command": "RV_BINARY=/r python3 /c/hooks/rv-guard.py", "timeout": 10 }
            ]
          }
        ]
      }
    }
    """
    #expect(try AntigravitySettingsMerge.uninstall(existingData: Data(existing.utf8)) == nil)
}

@Test func antigravityMerge_unreadableThrows() {
    #expect(throws: AntigravitySettingsMergeError.unreadable) {
        _ = try AntigravitySettingsMerge.merge(
            existingData: Data("[]".utf8),
            rvPath: "/r",
            adapterPath: "/c/hooks/rv-guard.py",
            force: false
        )
    }
    #expect(throws: AntigravitySettingsMergeError.unreadable) {
        _ = try AntigravitySettingsMerge.uninstall(existingData: Data("[]".utf8))
    }
}

@Test func antigravityMerge_inspectionStates() {
    #expect(AntigravitySettingsMerge.inspectionState(of: nil) == .absentFile)
    #expect(AntigravitySettingsMerge.inspectionState(of: Data("not json{".utf8)) == .occupied)
    #expect(AntigravitySettingsMerge.inspectionState(of: Data("[]".utf8)) == .occupied)
    let foreign = Data(
        """
        {"other-hook":{"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"other","timeout":1}]}]}}
        """.utf8
    )
    #expect(AntigravitySettingsMerge.inspectionState(of: foreign) == .absentFile)
    let shellOnly = Data(
        """
        {"rv-guard":{"enabled":true,"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"RV_BINARY=/r python3 /c/hooks/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(AntigravitySettingsMerge.inspectionState(of: shellOnly) == .outdated)
    let guardForeign = Data(
        """
        {"rv-guard":{"enabled":true,"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"python3 /opt/other/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(AntigravitySettingsMerge.inspectionState(of: guardForeign) == .occupied)
}

@Test func antigravityMerge_wiredReportsBakedPath() throws {
    let merged = try antigravityMerged()
    #expect(
        AntigravitySettingsMerge.inspectionState(of: merged)
            == .wired(bakedPath: antigravityRvPath)
    )
}

@Test func antigravityMerge_forceRewritesOccupied() throws {
    let occupied = Data(
        """
        {"rv-guard":{"enabled":true,"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"python3 /opt/other/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(AntigravitySettingsMerge.inspectionState(of: occupied) == .occupied)
    let merged = try AntigravitySettingsMerge.merge(
        existingData: occupied,
        rvPath: antigravityRvPath,
        adapterPath: antigravityAdapter,
        force: true
    )
    #expect(merged.wrote)
    #expect(
        AntigravitySettingsMerge.inspectionState(of: merged.data)
            == .wired(bakedPath: antigravityRvPath)
    )
}

@Test func antigravityMerge_outdatedRewritesWithoutForce() throws {
    let shellOnly = Data(
        """
        {"rv-guard":{"enabled":true,"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"RV_BINARY=/r python3 /c/hooks/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(AntigravitySettingsMerge.inspectionState(of: shellOnly) == .outdated)
    let merged = try AntigravitySettingsMerge.merge(
        existingData: shellOnly,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(merged.wrote)
    #expect(AntigravitySettingsMerge.inspectionState(of: merged.data) == .wired(bakedPath: "/r"))
}

@Test func antigravityMerge_mergedBytesHaveFileToolMatchers() throws {
    let merged = try antigravityMerged()
    let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
    #expect(AntigravitySettingsMerge.hasFileToolMatchers(in: root))
    #expect(AntigravitySettingsMerge.adapterPath(hooksPath: "/h/.gemini/config/hooks.json") == "/h/.gemini/config/hooks/rv-guard.py")
}

@Test func antigravityWiring_applyReportsWiredFileTools() throws {
    let applied = try HostWiring.applyAntigravity(
        existing: nil,
        rvPath: antigravityRvPath,
        adapterPath: antigravityAdapter
    )
    #expect(applied.wrote)
    #expect(applied.fileTools == .wired)
    #expect(
        HostWiring.fileTools(host: .antigravity, adapterBytes: applied.data, companionJSON: nil)
            == .wired
    )
}

@Test func antigravityWiring_shellOnlyWithoutFileMatchers() {
    let shellOnly = Data(
        """
        {"rv-guard":{"enabled":true,"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"RV_BINARY=/r python3 /c/hooks/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(
        HostWiring.fileTools(host: .antigravity, adapterBytes: shellOnly, companionJSON: nil)
            == .shellOnly
    )
    #expect(
        HostWiring.fileTools(host: .antigravity, adapterBytes: nil, companionJSON: nil)
            == .notApplicable
    )
}
