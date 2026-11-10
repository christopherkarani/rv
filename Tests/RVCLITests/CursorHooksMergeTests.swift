import Foundation
import Testing
@testable import RVCLI

@Test func cursorHooksMerge_createsBeforeShellExecutionFailClosed() throws {
    let adapter = "/tmp/home/.cursor/hooks/rv-guard.py"
    let merged = try CursorHooksMerge.merge(existingData: nil, interpreter: "/usr/bin/python3", adapterPath: adapter)
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    #expect(root["version"] as? Int == 1)
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let before = try #require(hooksRoot["beforeShellExecution"] as? [[String: Any]])
    #expect(before.count == 1)
    #expect(before[0]["command"] as? String == "/usr/bin/python3 -I -S \(adapter)")
    #expect(before[0]["timeout"] as? Int == 18)
    #expect(before[0]["failClosed"] as? Bool == true)
    #expect(before[0]["matcher"] == nil)
    #expect(hooksRoot["PreToolUse"] == nil)
    let preToolUse = try #require(hooksRoot["preToolUse"] as? [[String: Any]])
    #expect(preToolUse.count == 1)
    #expect(preToolUse[0]["command"] as? String == "/usr/bin/python3 -I -S \(adapter)")
    #expect(preToolUse[0]["timeout"] as? Int == 18)
    #expect(preToolUse[0]["failClosed"] as? Bool == true)
    #expect(preToolUse[0]["matcher"] == nil)
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
        interpreter: "/usr/bin/python3",
        adapterPath: adapter
    )
    #expect(merged.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let before = try #require(hooksRoot["beforeShellExecution"] as? [[String: Any]])
    #expect(before.count == 2)
    #expect(before[0]["command"] as? String == "other-guard evaluate")
    #expect(before[1]["command"] as? String == "/usr/bin/python3 -I -S \(adapter)")
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
        _ = try CursorHooksMerge.merge(existingData: Data("[]".utf8), interpreter: "/usr/bin/python3", adapterPath: "/x")
    }
}

@Test func cursorHooksMerge_registersBeforeReadFile() throws {
    let adapter = "/tmp/home/.cursor/hooks/rv-guard.py"
    let merged = try CursorHooksMerge.merge(existingData: nil, interpreter: "/usr/bin/python3", adapterPath: adapter)
    let root = try #require(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    let reads = try #require(hooksRoot["beforeReadFile"] as? [[String: Any]])
    #expect(reads.count == 1)
    #expect(reads[0]["command"] as? String == "/usr/bin/python3 -I -S \(adapter)")
    #expect(reads[0]["failClosed"] as? Bool == true)
    #expect(reads[0]["matcher"] == nil)
}

@Test func cursorHooksMerge_migratesOldInstallToBeforeReadFileIdempotently() throws {
    let adapter = "/tmp/home/.cursor/hooks/rv-guard.py"
    let old = """
    {
      "version": 1,
      "hooks": {
        "beforeShellExecution": [
          { "command": "python3 \(adapter)", "failClosed": true, "timeout": 5 }
        ],
        "preToolUse": [
          { "command": "python3 \(adapter)", "failClosed": true, "timeout": 5 }
        ]
      }
    }
    """
    let first = try CursorHooksMerge.merge(existingData: Data(old.utf8), interpreter: "/usr/bin/python3", adapterPath: adapter)
    #expect(first.wrote)
    let root = try #require(JSONSerialization.jsonObject(with: first.data) as? [String: Any])
    let hooksRoot = try #require(root["hooks"] as? [String: Any])
    #expect((hooksRoot["beforeReadFile"] as? [[String: Any]])?.count == 1)
    #expect((hooksRoot["beforeShellExecution"] as? [[String: Any]])?.count == 1)
    #expect((hooksRoot["preToolUse"] as? [[String: Any]])?.count == 1)
    let second = try CursorHooksMerge.merge(existingData: first.data, interpreter: "/usr/bin/python3", adapterPath: adapter)
    #expect(second.wrote == false)
    #expect(second.data == first.data)
}
