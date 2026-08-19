import Foundation
import Testing
@testable import RVCLI

private func withTempHome(_ body: (URL, HostLayout, RecordingLaunchctl) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-setup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let launchctl = RecordingLaunchctl()
    try body(root, HostLayout(home: root.path), launchctl)
}

private func env(
    home: URL,
    launchctl: RecordingLaunchctl,
    pathEntries: [String] = [],
    rvPath: String = "/tmp/rv-bin/rv",
    rvdPath: String = "/tmp/rv-bin/rvd",
    touchLaunchd: Bool = true
) -> SetupEnvironment {
    SetupEnvironment(
        home: home.path,
        pathEntries: pathEntries,
        rvPath: rvPath,
        rvdPath: rvdPath,
        fileManager: .default,
        launchctl: launchctl,
        touchLaunchd: touchLaunchd
    )
}

private func realGrokHookURL() -> URL? {
    guard let login = LoginHome.path() else { return nil }
    return URL(fileURLWithPath: login + "/.grok/hooks/rv.json")
}

@Test func setup_hostless_createsNoHostTrees_andPrintsSetupLine() throws {
    let realBefore = realGrokHookURL().flatMap { try? Data(contentsOf: $0) }
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == SetupRun.hostlessLine + "\n")
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.piDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.openCodeDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory))
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
        let plist = try String(contentsOfFile: layout.launchAgent, encoding: .utf8)
        #expect(plist.contains("/tmp/rv-bin/rvd"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("<false/>"))
        #expect(launchctl.bootstraps.count == 1)
    }
    let realAfter = realGrokHookURL().flatMap { try? Data(contentsOf: $0) }
    #expect(realBefore == realAfter)
}

@Test func setup_grokOnly_writesBashMatcherHook() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == SetupRun.grokRestartLine + "\n")
        let body = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(body.contains("PreToolUse"))
        #expect(body.contains("\"matcher\": \"Bash\""))
        #expect(body.contains("/tmp/rv-bin/rv hook --host grok"))
        #expect(FileManager.default.fileExists(atPath: layout.piExtension) == false)
        let extras = try FileManager.default.contentsOfDirectory(atPath: layout.grokDirectory)
        #expect(extras == ["hooks"])
        let hooks = try FileManager.default.contentsOfDirectory(atPath: layout.grokDirectory + "/hooks")
        #expect(hooks == ["rv.json"])
        #expect(launchctl.bootstraps.isEmpty == false)
    }
}

@Test func setup_piOnly_writesGuardAndNoSettings() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        let body = try String(contentsOfFile: layout.piExtension, encoding: .utf8)
        #expect(body.contains("tool_call"))
        #expect(body.contains("const RV_BINARY = \"/tmp/rv-bin/rv\""))
        #expect(body.contains("[\"hook\", \"--host\", host]"))
        #expect(body.contains("spawnRvHook(\"pi\""))
        #expect(FileManager.default.fileExists(atPath: layout.piDirectory + "/settings.json") == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

@Test func setup_openCodeOnly_writesToolExecuteBefore() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.openCodeDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        let body = try String(contentsOfFile: layout.openCodePlugin, encoding: .utf8)
        #expect(body.contains("tool.execute.before"))
        #expect(body.contains("const RV_BINARY = \"/tmp/rv-bin/rv\""))
        #expect(body.contains("[\"hook\", \"--host\", host]"))
        #expect(body.contains("spawnRvHook(\"opencode\""))
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

@Test func setup_occupiedOwnedName_skipsAndLeavesBytes() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory + "/hooks", withIntermediateDirectories: true)
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Skipped occupied grok hook."))
        let after = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(after == foreign)
    }
}

@Test func setup_foreignSibling_untouched_andWritesOwnedHook() throws {
    try withTempHome { home, layout, launchctl in
        let hooks = layout.grokDirectory + "/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let sibling = hooks + "/other.json"
        try "{\"foreign\":true}\n".write(toFile: sibling, atomically: true, encoding: .utf8)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook))
        let siblingAfter = try String(contentsOfFile: sibling, encoding: .utf8)
        #expect(siblingAfter == "{\"foreign\":true}\n")
    }
}

@Test func setup_idempotent_secondRunIsQuietAndDoesNotDuplicate() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let first = SetupRun.setup(env(home: home, launchctl: launchctl))
        let firstBody = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        let second = SetupRun.setup(env(home: home, launchctl: launchctl))
        let secondBody = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(first.exitCode == 0)
        #expect(second.exitCode == 0)
        #expect(second.stdout == "")
        #expect(firstBody == secondBody)
        #expect(secondBody.components(separatedBy: "PreToolUse").count == 2)
    }
}

@Test func setup_rewritesMovedBinaryPath() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
        _ = SetupRun.setup(env(home: home, launchctl: launchctl, rvPath: "/old/rv"))
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, rvPath: "/new/rv"))
        let grok = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        let pi = try String(contentsOfFile: layout.piExtension, encoding: .utf8)
        #expect(outcome.exitCode == 0)
        #expect(grok.contains("/new/rv hook --host grok"))
        #expect(grok.contains("/old/rv") == false)
        #expect(pi.contains("const RV_BINARY = \"/new/rv\""))
        #expect(pi.contains("/old/rv") == false)
    }
}

@Test func uninstall_removesOwnedFiles_leavesForeignSibling() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory + "/hooks", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
        try "{\"foreign\":true}\n".write(
            toFile: layout.grokDirectory + "/hooks/other.json",
            atomically: true,
            encoding: .utf8
        )
        _ = SetupRun.setup(env(home: home, launchctl: launchctl))
        try FileManager.default.createDirectory(
            atPath: (layout.localRv as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "bin".write(toFile: layout.localRv, atomically: true, encoding: .utf8)
        try "bin".write(toFile: layout.localRvd, atomically: true, encoding: .utf8)
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
        #expect(FileManager.default.fileExists(atPath: layout.piExtension) == false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.localRv) == false)
        #expect(FileManager.default.fileExists(atPath: layout.localRvd) == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory + "/hooks/other.json"))
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory))
        #expect(launchctl.bootouts.contains(SetupRun.launchAgentLabel))
    }
}

@Test func uninstall_isIdempotentWhenAlreadyGone() throws {
    try withTempHome { home, _, launchctl in
        let first = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        let second = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        #expect(first.exitCode == 0)
        #expect(second.exitCode == 0)
    }
}

@Test func setup_doesNotTouchLaunchdWhenHomeIsNotLogin() throws {
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, touchLaunchd: false))
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
        #expect(launchctl.bootstraps.isEmpty)
    }
}

@Test func setup_detectsGrokOnPathWithoutPrecreatedTree() throws {
    try withTempHome { home, layout, launchctl in
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let grok = bin.appendingPathComponent("grok")
        try "#!/bin/sh\n".write(to: grok, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grok.path)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, pathEntries: [bin.path]))
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook))
    }
}
