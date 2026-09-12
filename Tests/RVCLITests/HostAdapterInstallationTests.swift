import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import Testing
@testable import RVCLI

private func withInstallationHome(
    _ body: (URL, OwnedPaths) throws -> Void
) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-host-inspection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home, OwnedPaths(home: try #require(HomeDirectory(validating: home.path))))
}

private func writeWiredAdapter(
    host: HookHost,
    destination: String,
    rvPath: String
) throws {
    try FileManager.default.createDirectory(
        atPath: (destination as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    if host == .claude {
        let merged = try ClaudeSettingsMerge.merge(
            existingData: nil,
            rvPath: rvPath,
            adapterPath: ClaudeSettingsMerge.adapterPath(settingsPath: destination),
            force: false
        )
        try merged.data.write(to: URL(fileURLWithPath: destination))
    } else {
        let body = try host.adapterResource().rendered(rvPath: rvPath)
        try body.write(toFile: destination, atomically: true, encoding: .utf8)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_missingIsReadOnly(_ host: HookHost) throws {
    try withInstallationHome { home, paths in
        let before = try FileManager.default.contentsOfDirectory(atPath: home.path)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == before)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_detectedWithoutOwnedFileIsAbsentFile(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        try FileManager.default.createDirectory(
            atPath: owned.detectionDirectory,
            withIntermediateDirectories: true
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .absentFile)
        #expect(FileManager.default.fileExists(atPath: owned.destination) == false)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_foreignOwnedBytesAreOccupiedAndUnchanged(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        let foreign = Data([0xFF, 0x00, 0x41])
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try foreign.write(to: URL(fileURLWithPath: owned.destination))

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .occupied)
        #expect(try Data(contentsOf: URL(fileURLWithPath: owned.destination)) == foreign)
    }
}

@Test func hostInstallation_claudeStaleLegacyCommandIsBrokenNotOccupied() throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: .claude)
        let stale = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "/old/rv hook --host claude", "timeout": 10 }
                ]
              }
            ]
          }
        }
        """
        try FileManager.default.createDirectory(
            atPath: owned.detectionDirectory,
            withIntermediateDirectories: true
        )
        try stale.write(toFile: owned.destination, atomically: true, encoding: .utf8)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .claude) == .broken)
        #expect(snapshot.state(for: .claude) != .occupied)
        #expect(try String(contentsOfFile: owned.destination, encoding: .utf8) == stale)
    }
}

@Test func hostInstallation_claudeForeignGuardIsOccupied() throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: .claude)
        let occupied = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "python3 /opt/other/rv-guard.py", "timeout": 10 }
                ]
              }
            ]
          }
        }
        """
        try FileManager.default.createDirectory(
            atPath: owned.detectionDirectory,
            withIntermediateDirectories: true
        )
        try occupied.write(toFile: owned.destination, atomically: true, encoding: .utf8)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .claude) == .occupied)
        #expect(try String(contentsOfFile: owned.destination, encoding: .utf8) == occupied)
    }
}

@Test func hostInstallation_claudeForeignJSONWithoutFingerprintIsAbsentFile() throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: .claude)
        let foreign = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "other-guard evaluate", "timeout": 5 }
                ]
              }
            ]
          }
        }
        """
        try FileManager.default.createDirectory(
            atPath: owned.detectionDirectory,
            withIntermediateDirectories: true
        )
        try foreign.write(toFile: owned.destination, atomically: true, encoding: .utf8)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .claude) == .absentFile)
        #expect(try String(contentsOfFile: owned.destination, encoding: .utf8) == foreign)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_symlinkAtOwnedNameIsOccupiedWithoutFollowing(_ host: HookHost) throws {
    try withInstallationHome { home, paths in
        let owned = paths.hostAdapter(for: host)
        let target = home.appendingPathComponent("foreign-adapter")
        try "foreign".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: owned.destination,
            withDestinationPath: target.path
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .occupied)
        #expect(try String(contentsOf: target, encoding: .utf8) == "foreign")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: owned.destination) == target.path)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_danglingSymlinkAtOwnedNameIsOccupied(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: owned.destination,
            withDestinationPath: "/nonexistent/foreign-adapter"
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .occupied)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: owned.destination)
                == "/nonexistent/foreign-adapter"
        )
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_currentResourceWithMissingExecutableIsBroken(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        try writeWiredAdapter(host: host, destination: owned.destination, rvPath: "/nonexistent/rv")

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .broken)
        #expect(snapshot.state(for: host) != .wired)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_currentResourceWithExecutableIsWired(_ host: HookHost) throws {
    try withInstallationHome { home, paths in
        let owned = paths.hostAdapter(for: host)
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try FileManager.default.createDirectory(
            atPath: owned.detectionDirectory,
            withIntermediateDirectories: true
        )
        try writeWiredAdapter(host: host, destination: owned.destination, rvPath: executable.path)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .wired)
    }
}

@Test func hostInstallation_fileToolsNotApplicableWhenMissing() throws {
    try withInstallationHome { _, paths in
        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )
        #expect(snapshot.fileTools(for: .grok) == .notApplicable)
        #expect(snapshot.fileTools(for: .claude) == .notApplicable)
        #expect(snapshot.fileTools(for: .cursor) == .notApplicable)
        #expect(snapshot.fileTools(for: .pi) == .notApplicable)
    }
}

@Test func hostInstallation_wiredGrokTemplateIsFileToolWired() throws {
    try withInstallationHome { home, paths in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try FileManager.default.createDirectory(
            atPath: paths.grokDirectory,
            withIntermediateDirectories: true
        )
        try writeWiredAdapter(
            host: .grok,
            destination: paths.hostAdapter(for: .grok).destination,
            rvPath: executable.path
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .grok) == .wired)
        #expect(snapshot.fileTools(for: .grok) == .wired)
        #expect(snapshot.fileTools(for: .pi) == .notApplicable)
    }
}

@Test func grokHookInspect_openPreToolUseIsFileToolDoor() throws {
    let rendered = try HookHost.grok.adapterResource().rendered(rvPath: "/usr/local/bin/rv")
    #expect(GrokHookInspect.hasFileToolDoor(in: Data(rendered.utf8)))
}

@Test func grokHookInspect_matcherIsNotFileToolDoor() throws {
    let body = try grokBodyWithMatcher(rvPath: "/usr/local/bin/rv", matcher: "Bash")
    #expect(GrokHookInspect.hasFileToolDoor(in: Data(body.utf8)) == false)
}

@Test func hostInstallation_wiredGrokBytesWithMatcherAreShellOnly() throws {
    try withInstallationHome { _, paths in
        let body = try grokBodyWithMatcher(rvPath: "/usr/local/bin/rv", matcher: "Bash")
        let installation = HostAdapterInstallation.wired(
            path: paths.hostAdapter(for: .grok),
            existingData: Data(body.utf8)
        )
        #expect(installation.fileTools() == .shellOnly)
    }
}

@Test func hostInstallation_wiredClaudeMergeIsFileToolWired() throws {
    try withInstallationHome { home, paths in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try FileManager.default.createDirectory(
            atPath: paths.claudeDirectory,
            withIntermediateDirectories: true
        )
        try writeWiredAdapter(
            host: .claude,
            destination: paths.hostAdapter(for: .claude).destination,
            rvPath: executable.path
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .claude) == .wired)
        #expect(snapshot.fileTools(for: .claude) == .wired)
    }
}

@Test func hostInstallation_wiredCursorAdapterWithoutHooksJSONIsShellOnly() throws {
    try withInstallationHome { home, paths in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try FileManager.default.createDirectory(
            atPath: paths.cursorDirectory,
            withIntermediateDirectories: true
        )
        try writeWiredAdapter(
            host: .cursor,
            destination: paths.hostAdapter(for: .cursor).destination,
            rvPath: executable.path
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .cursor) == .wired)
        #expect(snapshot.fileTools(for: .cursor) == .shellOnly)
    }
}

@Test func hostInstallation_wiredCursorWithPreToolUseIsFileToolWired() throws {
    try withInstallationHome { home, paths in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try FileManager.default.createDirectory(
            atPath: paths.cursorDirectory,
            withIntermediateDirectories: true
        )
        try writeWiredAdapter(
            host: .cursor,
            destination: paths.hostAdapter(for: .cursor).destination,
            rvPath: executable.path
        )
        let merged = try CursorHooksMerge.merge(
            existingData: nil,
            adapterPath: paths.cursorHook
        )
        try merged.data.write(to: URL(fileURLWithPath: paths.cursorHooksJSON))

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: .cursor) == .wired)
        #expect(snapshot.fileTools(for: .cursor) == .wired)
    }
}

private func grokBodyWithMatcher(rvPath: String, matcher: String) throws -> String {
    let rendered = try HookHost.grok.adapterResource().rendered(rvPath: rvPath)
    let needle = "      {\n        \"hooks\":"
    let insert = "      {\n        \"matcher\": \"\(matcher)\",\n        \"hooks\":"
    let replaced = rendered.replacingOccurrences(of: needle, with: insert)
    try #require(replaced != rendered)
    return replaced
}
