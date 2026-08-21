import Foundation
import Testing
import RVAnalytics
import RVPresentation
import RVTheme
@testable import RVCLI

@Test func setup_pretty_hostless_paintsSlotsAndHostlessCloser() throws {
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .setup
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("◦  Grok"))
        #expect(outcome.stdout.contains("◦  Pi"))
        #expect(outcome.stdout.contains("◦  OpenCode"))
        #expect(outcome.stdout.contains(setupCeremonyHostlessTitle))
        #expect(outcome.stdout.contains(setupCeremonyHostlessNext))
        #expect(outcome.stdout.contains("\u{001B}") == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory) == false)
    }
}

@Test func setup_pretty_grokWired_hooksWiredCloser() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .setup
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("•  Grok  reload /hooks"))
        #expect(outcome.stdout.contains(setupCeremonyHooksWired))
        #expect(outcome.stdout.contains("Setup complete") == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook))
    }
}

@Test func setup_pretty_install_wired_explainCloser() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .install
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains(setupCeremonyInstallCloser))
        #expect(outcome.stdout.contains("•  Grok"))
        #expect(FileManager.default.fileExists(atPath: layout.grokHook))
    }
}

@Test func setup_pretty_occupiedGrok_hollowSkipClause() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: layout.piDirectory,
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .setup
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("◦  Grok  skipped occupied"))
        #expect(outcome.stdout.contains("•  Pi"))
        #expect(outcome.stdout.contains(setupCeremonyHooksWired))
        let grokAfter = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(grokAfter == foreign)
    }
}

@Test func setup_pretty_occupiedGrokOnly_neverClaimsWired() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .setup
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains(setupCeremonyHooksWired) == false)
        #expect(outcome.stdout.contains(setupCeremonyInstallCloser) == false)
        #expect(outcome.stdout.contains(setupCeremonyHostlessTitle))
        #expect(outcome.stdout.contains("◦  Grok  skipped occupied"))
        let grokAfter = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(grokAfter == foreign)
        #expect(FileManager.default.fileExists(atPath: layout.piDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.openCodeDirectory) == false)
    }
}

@Test func setup_pretty_secondRunIsQuiet() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        _ = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .setup
        )
        let second = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette),
            ceremonyKind: .setup
        )
        #expect(second.exitCode == 0)
        #expect(second.stdout == "")
    }
}

@Test func setup_robot_wiredIsOneCompleteLine() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl), appearance: .robot)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == SetupRun.robotCompleteLine + "\n")
        #expect(outcome.stdout.contains("◦") == false)
        #expect(outcome.stdout.contains("•") == false)
    }
}

@Test func setup_ceremonyKind_fromInstallEnv() {
    #expect(SetupCeremonyKind.fromInstallEnvironment(environment: ["RV_FROM_INSTALL": "1"]) == .install)
    #expect(SetupCeremonyKind.fromInstallEnvironment(environment: [:]) == .setup)
}

@Test func setupHelp_jsonAndRobotAreOneLineNotJSON() {
    let help = Setup.helpText()
    #expect(help.contains("Robot JSON") == false)
    #expect(help.contains("One line, no circles"))
}

@Test func uninstall_pretty_removesWiredHostsAndCloser() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        _ = SetupRun.setup(env(home: home, launchctl: launchctl), appearance: .robot)
        let outcome = SetupRun.uninstall(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains(uninstallCeremonyCloser))
        #expect(outcome.stdout.contains(uninstallCeremonyHooksRemoved))
        #expect(outcome.stdout.contains("◦  Grok"))
        #expect(outcome.stdout.contains("•") == false)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

@Test func uninstall_pretty_occupiedLeftAlone() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let outcome = SetupRun.uninstall(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("◦  Grok  left occupied"))
        #expect(outcome.stdout.contains(uninstallCeremonyAlreadyClean))
        #expect(outcome.stdout.contains(uninstallCeremonyCloser) == false)
        #expect(try String(contentsOfFile: layout.grokHook, encoding: .utf8) == foreign)
    }
}

@Test func uninstall_pretty_configOnly_claimsComplete() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.configDirectory,
            withIntermediateDirectories: true
        )
        let configDir = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        let analytics = AnalyticsPaths(configDirectory: configDir)
        try "x".write(to: analytics.configFile, atomically: true, encoding: .utf8)
        let outcome = SetupRun.uninstall(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains(uninstallCeremonyCloser))
        #expect(outcome.stdout.contains(uninstallCeremonyAlreadyClean) == false)
        #expect(FileManager.default.fileExists(atPath: analytics.configFile.path) == false)
    }
}

@Test func uninstall_robot_alreadyCleanIsOneLine() throws {
    try withTempHome { home, _, launchctl in
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl), appearance: .robot)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == SetupRun.uninstallAlreadyCleanLine + "\n")
    }
}

@Test func uninstall_robot_afterSetupIsCompleteLine() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        _ = SetupRun.setup(env(home: home, launchctl: launchctl), appearance: .robot)
        let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl), appearance: .robot)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == SetupRun.uninstallCompleteLine + "\n")
    }
}

