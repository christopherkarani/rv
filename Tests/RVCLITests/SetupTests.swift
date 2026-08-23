import Foundation
import Testing
import RVAnalytics
import RVHooks
import RVPolicy
import RVPresentation
@testable import RVCLI

final class FailingLaunchctl: LaunchctlApplying {
    func bootstrap(domain _: String, plist _: URL) throws {
        throw LaunchctlError.nonZeroExit(1)
    }

    func bootout(domain _: String, label _: String) throws {
        throw LaunchctlError.nonZeroExit(1)
    }
}

func withTempHome(_ body: (URL, OwnedPaths, RecordingLaunchctl) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-setup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dummyRvd = root.appendingPathComponent("rvd")
    try "#!/bin/sh\n".write(to: dummyRvd, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyRvd.path)
    let launchctl = RecordingLaunchctl()
    try body(root, OwnedPaths(home: root.path), launchctl)
}

func env(
    home: URL,
    launchctl: any LaunchctlApplying,
    pathEntries: [String] = [],
    rvPath: String = "/tmp/rv-bin/rv",
    rvdPath: String? = nil,
    touchLaunchd: Bool = true,
    installAnalytics: any InstallAnalyticsCapturing = SilentInstallAnalytics()
) -> SetupEnvironment {
    SetupEnvironment(
        home: home.path,
        pathEntries: pathEntries,
        rvPath: rvPath,
        rvdPath: rvdPath ?? home.appendingPathComponent("rvd").path,
        fileManager: .default,
        launchctl: launchctl,
        touchLaunchd: touchLaunchd,
        installAnalytics: installAnalytics
    )
}

func makeExecutable(_ url: URL, contents: String = "#!/bin/sh\n") throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func fixtureLoginHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-setup-login-\(UUID().uuidString)", isDirectory: true)
    let hook = root.appendingPathComponent(".grok/hooks/rv.json")
    try FileManager.default.createDirectory(
        at: hook.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "{\"hooks\":[]}\n".write(to: hook, atomically: true, encoding: .utf8)
    return root
}

@Test func setup_hostless_createsNoHostTrees_andPrintsSetupLine() throws {
    let foreignHome = try fixtureLoginHome()
    defer { try? FileManager.default.removeItem(at: foreignHome) }
    let foreignHook = foreignHome.appendingPathComponent(".grok/hooks/rv.json")
    let before = try Data(contentsOf: foreignHook)
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == setupRobotHostlessLine + "\n")
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.piDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.openCodeDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory))
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
        let plist = try String(contentsOfFile: layout.launchAgent, encoding: .utf8)
        #expect(plist.contains(home.appendingPathComponent("rvd").path))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("<false/>"))
        #expect(launchctl.bootstraps.count == 1)
        let analytics = AnalyticsPaths(
            configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        )
        #expect(FileManager.default.fileExists(atPath: analytics.identityFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: analytics.hostsFile.path) == false)
    }
    let after = try Data(contentsOf: foreignHook)
    #expect(before == after)
}

@Test func setup_grokOnly_writesOwnedPayloadWithBakedPath() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == setupRobotCompleteLine + "\n")
        let body = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(body == (try SetupHostKind.grok.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv")))
        #expect(FileManager.default.fileExists(atPath: layout.piExtension) == false)
        let extras = try FileManager.default.contentsOfDirectory(atPath: layout.grokDirectory)
        #expect(extras == ["hooks"])
        let hooks = try FileManager.default.contentsOfDirectory(atPath: layout.grokDirectory + "/hooks")
        #expect(hooks == ["rv.json"])
        #expect(launchctl.bootstraps.isEmpty == false)
    }
}

@Test func setup_piOnly_writesOwnedPayloadAndNoSettings() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        let body = try String(contentsOfFile: layout.piExtension, encoding: .utf8)
        #expect(body == (try SetupHostKind.pi.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv")))
        #expect(FileManager.default.fileExists(atPath: layout.piDirectory + "/settings.json") == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

@Test func setup_openCodeOnly_writesOwnedPayloadWithBakedPath() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.openCodeDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        let body = try String(contentsOfFile: layout.openCodePlugin, encoding: .utf8)
        #expect(body == (try SetupHostKind.openCode.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv")))
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

@Test func setup_force_replacesOccupiedOwnedNameAndKeepsBackup() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl), force: true)

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Skipped occupied grok hook.") == false)
        let wired = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(wired == (try SetupHostKind.grok.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv")))
        let backup = try String(contentsOfFile: layout.grokHook + ".bak", encoding: .utf8)
        #expect(backup == foreign)
    }
}

@Test func setup_force_replacesOccupiedSymlinkWithoutLeavingLink() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: layout.grokHook,
            withDestinationPath: "/nonexistent/foreign-adapter"
        )

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl), force: true)

        #expect(outcome.exitCode == 0)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: layout.grokHook)) == nil)
        let wired = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(wired == (try SetupHostKind.grok.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv")))
        #expect(FileManager.default.fileExists(atPath: layout.grokHook + ".bak") == false)
    }
}

@Test func setup_force_leavesForeignSiblingUntouched() throws {
    try withTempHome { home, layout, launchctl in
        let hooks = layout.grokDirectory + "/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let sibling = hooks + "/other.json"
        try "{\"foreign\":true}\n".write(toFile: sibling, atomically: true, encoding: .utf8)
        try "{\"hooks\":[]}\n".write(toFile: layout.grokHook, atomically: true, encoding: .utf8)

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl), force: true)

        #expect(outcome.exitCode == 0)
        #expect(try String(contentsOfFile: sibling, encoding: .utf8) == "{\"foreign\":true}\n")
        #expect(
            try String(contentsOfFile: layout.grokHook, encoding: .utf8)
                == (try SetupHostKind.grok.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv"))
        )
    }
}

@Test func setup_danglingSymlinkAtOwnedNameIsOccupiedAndPreserved() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let target = "/nonexistent/foreign-adapter"
        try FileManager.default.createSymbolicLink(
            atPath: layout.grokHook,
            withDestinationPath: target
        )

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Skipped occupied grok hook."))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.grokHook) == target)
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
        #expect(grok.contains("/new/rv"))
        #expect(grok.contains("/old/rv") == false)
        #expect(pi.contains("/new/rv"))
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
        try "bin".write(toFile: layout.localRvCli, atomically: true, encoding: .utf8)
        try "bin".write(toFile: layout.localRvd, atomically: true, encoding: .utf8)
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
        #expect(FileManager.default.fileExists(atPath: layout.piExtension) == false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.localRv) == false)
        #expect(FileManager.default.fileExists(atPath: layout.localRvCli) == false)
        #expect(FileManager.default.fileExists(atPath: layout.localRvd) == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory + "/hooks/other.json"))
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory))
        #expect(launchctl.bootouts.contains(SetupRun.launchAgentLabel))
    }
}

@Test func uninstall_removesPolicyArtifactsAndLocks() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.configDirectory,
            withIntermediateDirectories: true
        )
        let configDir = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        for artifact in RVPolicyPaths.uninstallArtifacts(inConfigDir: configDir) {
            try "x".write(to: artifact, atomically: true, encoding: .utf8)
        }
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        for artifact in RVPolicyPaths.uninstallArtifacts(inConfigDir: configDir) {
            #expect(FileManager.default.fileExists(atPath: artifact.path) == false)
        }
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory) == false)
    }
}

@Test func uninstall_removesAnalyticsConfigJson() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.configDirectory,
            withIntermediateDirectories: true
        )
        let configDir = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        let analytics = AnalyticsPaths(configDirectory: configDir)
        for artifact in analytics.uninstallArtifacts {
            try "x".write(to: artifact, atomically: true, encoding: .utf8)
        }
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        for artifact in analytics.uninstallArtifacts {
            #expect(FileManager.default.fileExists(atPath: artifact.path) == false)
        }
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory) == false)
    }
}

@Test func uninstall_preservesForeignContentInPreexistingConfigDirectory() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.configDirectory,
            withIntermediateDirectories: true
        )
        let foreignPath = layout.configDirectory + "/user-settings"
        let sentinel = "keep me\n"
        try sentinel.write(toFile: foreignPath, atomically: true, encoding: .utf8)

        _ = SetupRun.setup(env(home: home, launchctl: launchctl))
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))

        #expect(outcome.exitCode == 0)
        #expect(try String(contentsOfFile: foreignPath, encoding: .utf8) == sentinel)
        #expect(FileManager.default.fileExists(atPath: layout.configDirectory))
    }
}

@Test func uninstall_preservesOccupiedAdapterAtOwnedName() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)

        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))

        #expect(outcome.exitCode == 0)
        #expect(try String(contentsOfFile: layout.grokHook, encoding: .utf8) == foreign)
    }
}

@Test func uninstall_preservesOccupiedDanglingSymlinkAtOwnedName() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let target = "/nonexistent/foreign-adapter"
        try FileManager.default.createSymbolicLink(
            atPath: layout.grokHook,
            withDestinationPath: target
        )

        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))

        #expect(outcome.exitCode == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.grokHook) == target)
    }
}

@Test func uninstall_isIdempotentWhenAlreadyGone() throws {
    try withTempHome { home, _, launchctl in
        let first = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        let second = SetupRun.uninstall(env(home: home, launchctl: launchctl))
        #expect(first.exitCode == 0)
        #expect(second.exitCode == 0)
        #expect(first.stdout == uninstallRobotAlreadyCleanLine + "\n")
        #expect(second.stdout == uninstallRobotAlreadyCleanLine + "\n")
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

@Test func setup_launchAgentTemplate_rendersEmbeddedResource() throws {
    let plist = try LaunchAgentTemplate.rendered(rvdPath: "/opt/rvd")
    #expect(plist.contains("/opt/rvd"))
    #expect(plist.contains("@RVD_PATH@") == false)
    #expect(plist.contains("<false/>"))
}

@Test func setup_bakesCHookPathNotRvCli() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: layout.openCodeDirectory,
            withIntermediateDirectories: true
        )
        let rvPath = layout.localRv
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, rvPath: rvPath))
        #expect(outcome.exitCode == 0)
        let grok = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        let pi = try String(contentsOfFile: layout.piExtension, encoding: .utf8)
        let openCode = try String(contentsOfFile: layout.openCodePlugin, encoding: .utf8)
        #expect(grok.contains("\(rvPath) hook --host grok"))
        #expect(pi.contains(rvPath))
        #expect(pi.contains("\"hook\""))
        #expect(pi.contains("\"--host\""))
        #expect(openCode.contains(rvPath))
        #expect(openCode.contains("\"hook\""))
        #expect(openCode.contains("\"--host\""))
        #expect(grok.contains("rv-cli") == false)
        #expect(pi.contains("rv-cli") == false)
        #expect(openCode.contains("rv-cli") == false)
        #expect(layout.localRvCli.hasSuffix("/.local/bin/rv-cli"))
    }
}

@Test func setup_resolveRv_ignoresPATH_bakesHomeLocalBin() throws {
    try withTempHome { home, layout, _ in
        let decoyDir = home.appendingPathComponent("cellar/bin", isDirectory: true)
        try makeExecutable(decoyDir.appendingPathComponent("rv"), contents: "decoy-rv")
        let resolved = SetupEnvironment.resolveRv(home: home.path)
        #expect(resolved == home.path + "/.local/bin/rv")
        #expect(layout.localRvCli == home.path + "/.local/bin/rv-cli")
    }
}

@Test func setup_resolveRvd_prefersSiblingOverHomeLocalBin() throws {
    try withTempHome { home, _, _ in
        let running = home.appendingPathComponent("running", isDirectory: true)
        let siblingRv = running.appendingPathComponent("rv")
        let siblingRvd = running.appendingPathComponent("rvd")
        try makeExecutable(siblingRv, contents: "sibling-rv")
        try makeExecutable(siblingRvd, contents: "sibling-rvd")
        let decoy = home.appendingPathComponent(".local/bin/rvd")
        try makeExecutable(decoy, contents: "decoy-rvd")
        let resolved = SetupEnvironment.resolveRvd(
            nextTo: siblingRv.path,
            home: home.path
        )
        #expect(resolved == siblingRvd.path)
    }
}

@Test func setup_launchAgentProgramArguments_isSiblingRvdNotDecoy() throws {
    try withTempHome { home, layout, launchctl in
        let running = home.appendingPathComponent("running", isDirectory: true)
        let siblingRvd = running.appendingPathComponent("rvd")
        try makeExecutable(siblingRvd, contents: "sibling-rvd")
        let decoy = home.appendingPathComponent(".local/bin/rvd")
        try makeExecutable(decoy, contents: "decoy-rvd")
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, rvdPath: siblingRvd.path))
        #expect(outcome.exitCode == 0)
        let plist = try String(contentsOfFile: layout.launchAgent, encoding: .utf8)
        #expect(plist.contains(siblingRvd.path))
        #expect(plist.contains(decoy.path) == false)
        #expect(launchctl.bootstraps.isEmpty == false)
    }
}

@Test func setup_skipsLaunchAgentWhenRvdIsNotExecutable_stillWritesHosts() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("missing-rvd").path
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, rvdPath: missing))
        #expect(outcome.exitCode == 0)
        #expect(launchctl.bootstraps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook))
        #expect(outcome.stdout.contains(setupRobotCompleteLine))
    }
}

@Test func setup_occupiedGrokHookWithExtraHook_leavesBytesUnchanged() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        _ = SetupRun.setup(env(home: home, launchctl: launchctl))
        let rendered = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        let extra = rendered + "\nextra"
        try extra.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: URL(fileURLWithPath: layout.grokHook))
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Skipped occupied grok hook."))
        let after = try Data(contentsOf: URL(fileURLWithPath: layout.grokHook))
        #expect(after == before)
    }
}

@Test func setup_occupiedNonUTF8GrokHook_leavesBytesUnchanged() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let bytes = Data([0xFF, 0xFE, 0x00, 0x80, 0x81])
        try bytes.write(to: URL(fileURLWithPath: layout.grokHook))
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Skipped occupied grok hook."))
        let after = try Data(contentsOf: URL(fileURLWithPath: layout.grokHook))
        #expect(after == bytes)
    }
}

@Test func setup_live_usesHOME() {
    let home = "/tmp/rv-setup-live-\(UUID().uuidString)"
    let env = SetupEnvironment.live(environment: ["HOME": home, "PATH": "/usr/bin:/bin"])
    #expect(env?.home == home)
    #expect(env?.pathEntries == ["/usr/bin", "/bin"])
}

@Test func setup_live_emptyHOME_isNil() {
    #expect(SetupEnvironment.live(environment: ["HOME": ""]) == nil)
    #expect(SetupEnvironment.live(environment: [:]) == nil)
}

@Test func setup_live_touchLaunchdFalseWhenHomeIsNotLogin() {
    let home = "/tmp/rv-setup-not-login-\(UUID().uuidString)"
    let env = SetupEnvironment.live(environment: ["HOME": home, "PATH": ""])
    #expect(env?.touchLaunchd == false)
}

@Test func setup_occupiedGrok_writesPi_joinsSkipOntoOneSuccessLine() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.split(separator: "\n").count == 1)
        #expect(outcome.stdout == setupRobotCompleteLine + ", Skipped occupied grok hook.\n")
        let grokAfter = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(grokAfter == foreign)
        #expect(FileManager.default.fileExists(atPath: layout.piExtension))
        let pi = try String(contentsOfFile: layout.piExtension, encoding: .utf8)
        #expect(pi == (try SetupHostKind.pi.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv")))
    }
}

@Test func setupError_bridgesAdapterResourceFailureToHostKind() {
    #expect(SetupError(adapterResourceFailure: .missingTemplate(.grok)) == .adapterTemplateMissing(.grok))
    #expect(SetupError(adapterResourceFailure: .missingTemplate(.pi)) == .adapterTemplateMissing(.pi))
    #expect(SetupError(adapterResourceFailure: .missingTemplate(.opencode)) == .adapterTemplateMissing(.openCode))
}

@Test func setupFailureOutput_mapsEveryCaseToStderrLineAndExitCode() {
    let expected: [(SetupError, SetupFailureCommand, Int32, String)] = [
        (
            .adapterTemplateMissing(.pi),
            .setup,
            EX_DATAERR,
            "rv setup failed: missing pi adapter template\n"
        ),
        (
            .launchAgentTemplateMissing,
            .setup,
            EX_DATAERR,
            "rv setup failed: missing LaunchAgent template\n"
        ),
        (
            .configDirectoryCreateFailed,
            .setup,
            EX_CANTCREAT,
            "rv setup failed: unable to create config directory\n"
        ),
        (
            .hostHookClearFailed(.grok),
            .setup,
            EX_CANTCREAT,
            "rv setup failed: unable to clear occupied grok hook\n"
        ),
        (
            .hostHookWriteFailed(.openCode),
            .setup,
            EX_CANTCREAT,
            "rv setup failed: unable to write opencode hook\n"
        ),
        (
            .launchAgentWriteFailed,
            .setup,
            EX_CANTCREAT,
            "rv setup failed: unable to write LaunchAgent\n"
        ),
        (
            .launchctlApplyFailed(.bootstrap),
            .setup,
            EX_UNAVAILABLE,
            "rv setup failed: unable to load LaunchAgent\n"
        ),
        (
            .launchctlApplyFailed(.bootout),
            .uninstall,
            EX_UNAVAILABLE,
            "rv uninstall failed: unable to unload LaunchAgent\n"
        ),
        (
            .ownedPathStillExists,
            .uninstall,
            EX_SOFTWARE,
            "rv uninstall failed: owned path still exists\n"
        ),
        (
            .inspectionFailed,
            .uninstall,
            EX_SOFTWARE,
            "rv uninstall failed: unable to inspect Host adapters\n"
        ),
    ]
    for (error, command, exitCode, stderr) in expected {
        let output = setupFailureOutput(error, command: command)
        #expect(output.stderr == stderr)
        #expect(output.exitCode == exitCode)
    }
}

@Test func setup_launchctlBootstrapFails_mapsToUnavailableExitAndKindLine() throws {
    try withTempHome { home, _, _ in
        let outcome = SetupRun.setup(env(home: home, launchctl: FailingLaunchctl()))
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == "rv setup failed: unable to load LaunchAgent\n")
        #expect(outcome.exitCode == EX_UNAVAILABLE)
    }
}

@Test func uninstall_launchctlBootoutFails_mapsToUnavailableExitAndKindLine() throws {
    try withTempHome { home, _, _ in
        let outcome = SetupRun.uninstall(env(home: home, launchctl: FailingLaunchctl()))
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == "rv uninstall failed: unable to unload LaunchAgent\n")
        #expect(outcome.exitCode == EX_UNAVAILABLE)
    }
}

@Test func setup_configDirectoryBlockedByFile_mapsToCannotCreateExit() throws {
    try withTempHome { home, layout, launchctl in
        let configParent = home.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: configParent, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: layout.configDirectory))

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))

        #expect(outcome.stderr == "rv setup failed: unable to create config directory\n")
        #expect(outcome.exitCode == EX_CANTCREAT)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
    }
}

@Test func setup_force_clearFailureInReadOnlyHooksDir_mapsToCannotCreateExit() throws {
    try withTempHome { home, layout, launchctl in
        let hooks = layout.grokDirectory + "/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "{\"hooks\":[]}\n".write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hooks)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks)
        }

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl), force: true)

        #expect(outcome.stderr == "rv setup failed: unable to clear occupied grok hook\n")
        #expect(outcome.exitCode == EX_CANTCREAT)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook))
        #expect(launchctl.bootstraps.isEmpty == false)
    }
}

@Test func setup_writeFailureInReadOnlyHooksDir_mapsToCannotCreateExit() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        let hooks = layout.grokDirectory + "/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hooks)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks)
        }

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))

        #expect(outcome.stderr == "rv setup failed: unable to write grok hook\n")
        #expect(outcome.exitCode == EX_CANTCREAT)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

@Test func setup_plistWriteFailureInReadOnlyLaunchAgentsDir_mapsToCannotCreateExit() throws {
    try withTempHome { home, layout, launchctl in
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: agents.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.path)
        }

        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))

        #expect(outcome.stderr == "rv setup failed: unable to write LaunchAgent\n")
        #expect(outcome.exitCode == EX_CANTCREAT)
        #expect(launchctl.bootstraps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

final class DomainRecordingLaunchctl: LaunchctlApplying {
    private(set) var bootstrapDomains: [String] = []
    private(set) var bootoutDomains: [String] = []

    func bootstrap(domain: String, plist _: URL) throws {
        bootstrapDomains.append(domain)
    }

    func bootout(domain: String, label _: String) throws {
        bootoutDomains.append(domain)
    }
}

@Test func setupFlow_missingHOME_failsOnceThroughInjectedFactory_withoutFilesystemAccess() {
    var consultations = 0
    let flow = SetupFlow(makeEnvironment: {
        consultations += 1
        return nil
    })
    let outcome = flow.run(SetupIntent(kind: .install))
    #expect(consultations == 1)
    #expect(outcome.stdout.isEmpty)
    #expect(outcome.stderr == "rv setup: HOME is not set\n")
    #expect(outcome.exitCode == 1)
}

@Test func setupFlow_uninstallMissingHOME_prefixesUninstall() {
    let outcome = SetupFlow(makeEnvironment: { nil }).run(SetupIntent(kind: .uninstall))
    #expect(outcome.stderr == "rv uninstall: HOME is not set\n")
    #expect(outcome.exitCode == 1)
}

@Test func setupFlow_oneEntry_routesIntentsToSetupAndUninstallOrchestrations() throws {
    try withTempHome { home, _, launchctl in
        var consultations = 0
        let flow = SetupFlow(makeEnvironment: {
            consultations += 1
            return env(home: home, launchctl: launchctl)
        })
        let installed = flow.run(SetupIntent(kind: .install, appearance: .robot))
        #expect(installed.exitCode == 0)
        #expect(installed.stdout == setupRobotHostlessLine + "\n")
        let removed = flow.run(SetupIntent(kind: .uninstall, appearance: .robot))
        #expect(removed.exitCode == 0)
        #expect(removed.stdout == uninstallRobotCompleteLine + "\n")
        #expect(consultations == 2)
    }
}

@Test func setupFlow_injectedUID_bakesGuiDomainForBootstrapAndBootout() throws {
    try withTempHome { home, layout, _ in
        let launchctl = DomainRecordingLaunchctl()
        var environment = env(home: home, launchctl: launchctl)
        environment.uid = { 4242 }
        let flow = SetupFlow(makeEnvironment: { environment })
        let installed = flow.run(SetupIntent(kind: .install, appearance: .robot))
        #expect(installed.exitCode == 0)
        #expect(launchctl.bootstrapDomains == ["gui/4242"])
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
        let removed = flow.run(SetupIntent(kind: .uninstall, appearance: .robot))
        #expect(removed.exitCode == 0)
        #expect(launchctl.bootoutDomains == ["gui/4242", "gui/4242"])
    }
}
