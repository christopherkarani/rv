import Foundation
import Testing
@testable import RVCLI

@Test func cursorHooksMerge_createsBeforeShellExecutionFailClosed() throws {
    let adapter = "/tmp/home/.cursor/hooks/rv-guard.py"
    let merged = try CursorHooksMerge.merge(existingData: nil, adapterPath: adapter)
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    #expect(root["version"] as? Int == 1)
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let before = try #require(hooksRoot["beforeShellExecution"] as? [[String: Any]])
    #expect(before.count == 1)
    #expect(before[0]["command"] as? String == "python3 \(adapter)")
    #expect(before[0]["timeout"] as? Int == 5)
    #expect(before[0]["failClosed"] as? Bool == true)
    #expect(before[0]["matcher"] == nil)
    #expect(hooksRoot["PreToolUse"] == nil)
}

@Test func cursorHooksMerge_preservesForeignBeforeShell() throws {
    let existing = """
    {
      "version": 1,
      "hooks": {
        "beforeShellExecution": [
          { "command": "other-guard evaluate", "timeout": 10 }
        ]
      }
    }
    """
    let adapter = "/opt/rv-home/.cursor/hooks/rv-guard.py"
    let merged = try CursorHooksMerge.merge(
        existingData: Data(existing.utf8),
        adapterPath: adapter
    )
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let before = try #require(hooksRoot["beforeShellExecution"] as? [[String: Any]])
    #expect(before.count == 2)
    #expect(before[0]["command"] as? String == "other-guard evaluate")
    #expect(before[1]["command"] as? String == "python3 \(adapter)")
    #expect(before[1]["failClosed"] as? Bool == true)
}

@Test func cursorHooksMerge_uninstallStripsFingerprintAndKeepsForeign() throws {
    let existing = """
    {
      "version": 1,
      "hooks": {
        "beforeShellExecution": [
          { "command": "other-guard evaluate", "timeout": 10 },
          { "command": "python3 /tmp/.cursor/hooks/rv-guard.py", "failClosed": true, "timeout": 5 }
        ]
      }
    }
    """
    let next = try #require(try CursorHooksMerge.uninstall(existingData: Data(existing.utf8)))
    let root = try #require(JSONSerialization.jsonObject(with: next) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let before = try #require(hooksRoot["beforeShellExecution"] as? [[String: Any]])
    #expect(before.count == 1)
    #expect(before[0]["command"] as? String == "other-guard evaluate")
}

@Test func cursorHooksMerge_uninstallEmptyReturnsNil() throws {
    let existing = """
    {
      "version": 1,
      "hooks": {
        "beforeShellExecution": [
          { "command": "python3 /tmp/.cursor/hooks/rv-guard.py", "failClosed": true, "timeout": 5 }
        ]
      }
    }
    """
    #expect(try CursorHooksMerge.uninstall(existingData: Data(existing.utf8)) == nil)
}

@Test func cursorHooksMerge_unreadableThrows() {
    #expect(throws: CursorHooksMergeError.unreadable) {
        _ = try CursorHooksMerge.merge(existingData: Data("[]".utf8), adapterPath: "/x")
    }
}
