import Foundation
import Testing
@testable import RVCLI

@Test func codexHooksMerge_createsPreToolUseBashEntry() throws {
    let adapter = "/tmp/home/.codex/hooks/rv-guard.py"
    let merged = try CodexHooksMerge.merge(existingData: nil, adapterPath: adapter)
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooksRoot["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 1)
    #expect(pre[0]["matcher"] as? String == "Bash")
    let inner = try #require(pre[0]["hooks"] as? [[String: Any]])
    #expect(inner.count == 1)
    #expect(inner[0]["type"] as? String == "command")
    #expect(inner[0]["command"] as? String == "python3 \(adapter)")
    #expect(inner[0]["timeout"] as? Int == 5)
    #expect(inner[0]["statusMessage"] as? String == "RV")
}

@Test func codexHooksMerge_preservesForeignPreToolUse() throws {
    let existing = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "other-guard evaluate", "timeout": 10 }
            ]
          }
        ]
      }
    }
    """
    let adapter = "/opt/rv-home/.codex/hooks/rv-guard.py"
    let merged = try CodexHooksMerge.merge(
        existingData: Data(existing.utf8),
        adapterPath: adapter
    )
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooksRoot["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 2)
    let foreign = try #require(pre[0]["hooks"] as? [[String: Any]])
    #expect(foreign[0]["command"] as? String == "other-guard evaluate")
    let rv = try #require(pre[1]["hooks"] as? [[String: Any]])
    #expect(rv[0]["command"] as? String == "python3 \(adapter)")
}

@Test func codexHooksMerge_uninstallStripsFingerprintAndKeepsForeign() throws {
    let existing = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "other-guard evaluate", "timeout": 10 }
            ]
          },
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "python3 /tmp/.codex/hooks/rv-guard.py", "timeout": 5 }
            ]
          }
        ]
      }
    }
    """
    let next = try #require(try CodexHooksMerge.uninstall(existingData: Data(existing.utf8)))
    let root = try #require(JSONSerialization.jsonObject(with: next) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooksRoot["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 1)
    let foreign = try #require(pre[0]["hooks"] as? [[String: Any]])
    #expect(foreign[0]["command"] as? String == "other-guard evaluate")
}

@Test func codexHooksMerge_uninstallEmptyReturnsNil() throws {
    let existing = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "python3 /tmp/.codex/hooks/rv-guard.py", "timeout": 5 }
            ]
          }
        ]
      }
    }
    """
    #expect(try CodexHooksMerge.uninstall(existingData: Data(existing.utf8)) == nil)
}

@Test func codexHooksMerge_unreadableThrows() {
    #expect(throws: CodexHooksMergeError.unreadable) {
        _ = try CodexHooksMerge.merge(existingData: Data("[]".utf8), adapterPath: "/x")
    }
}
