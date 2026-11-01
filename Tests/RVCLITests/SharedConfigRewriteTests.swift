import Foundation
import Testing
@testable import RVCLI

// Shared user configs (settings.json, hooks.json, opencode.json) are the
// user's files: rv rewrites must keep their numbers and key order, and keep
// a backup of every version rv replaced.

private let claudeAdapter = "/tmp/home/.claude/hooks/rv-guard.py"

private let userClaudeSettings = """
{
  "zeta": 1,
  "big": 12345678901234567890,
  "ratio": 1.0,
  "precise": 0.30000000000000000001,
  "alpha": {"z": 2, "a": [3, {"y": 1e2, "b": -0}]}
}
"""

private func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

private func offsets(of needles: [String], in haystack: String) -> [String.Index] {
    needles.compactMap { haystack.range(of: $0)?.lowerBound }
}

@Test func sharedConfig_claudeMergeKeepsNumbersExactly() throws {
    let merged = try ClaudeSettingsMerge.merge(
        existingData: Data(userClaudeSettings.utf8),
        rvPath: "/usr/local/bin/rv",
        adapterPath: claudeAdapter,
        force: false
    )
    let output = text(merged.data)
    #expect(output.contains("\"big\": 12345678901234567890"))
    #expect(output.contains("\"ratio\": 1.0"))
    #expect(output.contains("\"precise\": 0.30000000000000000001"))
    #expect(output.contains("\"y\": 1e2"))
    #expect(output.contains("\"b\": -0"))
}

@Test func sharedConfig_claudeMergeKeepsUserKeyOrder() throws {
    let merged = try ClaudeSettingsMerge.merge(
        existingData: Data(userClaudeSettings.utf8),
        rvPath: "/usr/local/bin/rv",
        adapterPath: claudeAdapter,
        force: false
    )
    let output = text(merged.data)
    let order = ["\"zeta\"", "\"big\"", "\"ratio\"", "\"precise\"", "\"alpha\"", "\"z\"", "\"a\"", "\"y\"", "\"b\"", "\"hooks\""]
    let found = offsets(of: order, in: output)
    #expect(found.count == order.count)
    #expect(found == found.sorted())
}

@Test func sharedConfig_claudeRemergeIsNoOp() throws {
    let first = try ClaudeSettingsMerge.merge(
        existingData: Data(userClaudeSettings.utf8),
        rvPath: "/usr/local/bin/rv",
        adapterPath: claudeAdapter,
        force: false
    )
    let second = try ClaudeSettingsMerge.merge(
        existingData: first.data,
        rvPath: "/usr/local/bin/rv",
        adapterPath: claudeAdapter,
        force: false
    )
    #expect(second.wrote == false)
    #expect(second.data == first.data)
}

@Test func sharedConfig_claudeUninstallKeepsUserLayout() throws {
    let merged = try ClaudeSettingsMerge.merge(
        existingData: Data(userClaudeSettings.utf8),
        rvPath: "/usr/local/bin/rv",
        adapterPath: claudeAdapter,
        force: false
    )
    let stripped = try #require(try ClaudeSettingsMerge.uninstall(existingData: merged.data))
    let output = text(stripped)
    #expect(output.contains("hooks") == false)
    #expect(output.contains("\"big\": 12345678901234567890"))
    let found = offsets(of: ["\"zeta\"", "\"big\"", "\"ratio\"", "\"alpha\""], in: output)
    #expect(found.count == 4)
    #expect(found == found.sorted())
}

@Test func sharedConfig_openCodeMergeKeepsNumbersAndKeyOrder() throws {
    let existing = #"{"$schema":"https://opencode.ai/config.json","model":"x","limit":9007199254740993,"plugin":["a"],"agent":{"b":1,"a":2}}"#
    let merged = try OpenCodeConfigMerge.merge(existingData: Data(existing.utf8), pluginPath: "/tmp/rv-ask")
    #expect(merged.wrote)
    let output = text(merged.data)
    #expect(output.contains("\"limit\": 9007199254740993"))
    let order = ["\"$schema\"", "\"model\"", "\"limit\"", "\"plugin\"", "\"agent\"", "\"b\"", "\"a\": 2"]
    let found = offsets(of: order, in: output)
    #expect(found.count == order.count)
    #expect(found == found.sorted())
    let again = try OpenCodeConfigMerge.merge(existingData: merged.data, pluginPath: "/tmp/rv-ask")
    #expect(again.wrote == false)
}

@Test func sharedConfig_markerPrefixedStringIsUnreadable() {
    // A NUL-prefixed string would collide with the exact-number marker.
    let existing = Data(#"{"k":"\u0000123"}"#.utf8)
    #expect(throws: (any Error).self) {
        try ClaudeSettingsMerge.merge(
            existingData: existing,
            rvPath: "/usr/local/bin/rv",
            adapterPath: claudeAdapter,
            force: false
        )
    }
}

// MARK: - Backups

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-shared-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func backups(of path: String) throws -> [String] {
    let directory = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    return try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix(name + ".rv-backup-") }
        .sorted()
        .map { directory + "/" + $0 }
}

@Test func sharedConfig_rewriteKeepsEveryPriorVersion() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("settings.json").path
    let files = FileOps(fileManager: .default)

    let firstBackup = try files.writeData(Data("v1".utf8), to: path)
    #expect(firstBackup == nil)
    #expect(try backups(of: path).isEmpty)

    let secondBackup = try #require(try files.writeData(Data("v2".utf8), to: path))
    let thirdBackup = try #require(try files.writeData(Data("v3".utf8), to: path))
    #expect(secondBackup != thirdBackup)
    #expect(try backups(of: path) == [secondBackup, thirdBackup].sorted())
    #expect(FileManager.default.contents(atPath: secondBackup) == Data("v1".utf8))
    #expect(FileManager.default.contents(atPath: thirdBackup) == Data("v2".utf8))
    #expect(FileManager.default.contents(atPath: path) == Data("v3".utf8))
}

@Test func sharedConfig_identicalRewriteMakesNoBackup() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("hooks.json").path
    let files = FileOps(fileManager: .default)
    try files.writeData(Data("same".utf8), to: path)
    let backup = try files.writeData(Data("same".utf8), to: path)
    #expect(backup == nil)
    #expect(try backups(of: path).isEmpty)
}

@Test func sharedConfig_backupKeepsOriginalMode() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.json").path
    let files = FileOps(fileManager: .default)
    try files.writeData(Data("v1".utf8), to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
    let backup = try #require(try files.writeData(Data("v2".utf8), to: path))
    let backupMode = try FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions] as? NSNumber
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    #expect(backupMode?.intValue == 0o640)
    #expect(mode?.intValue == 0o640)
}
