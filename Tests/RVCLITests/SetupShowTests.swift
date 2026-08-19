import Foundation
import Testing
import RVTheme
@testable import RVCLI

@Test func setup_pretty_hostless_paintsSlotsAndHostlessCloser() throws {
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == """
        ○ Grok
        ○ Pi
        ○ OpenCode
        looking for hosts
        No hosts yet
        Next  rv setup

        """)
        #expect(FileManager.default.fileExists(atPath: layout.grokDirectory) == false)
        #expect(outcome.stdout.contains("\u{001B}") == false)
    }
}

@Test func setup_pretty_grokWired_circleShowAndTestCloser() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == """
        ● Grok  reload /hooks
        ○ Pi
        ○ OpenCode
        wiring Grok
        Setup complete
        Next  rv test 'git reset --hard'

        """)
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
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == """
        ○ Grok  skipped occupied
        ● Pi
        ○ OpenCode
        wiring Pi
        Setup complete
        Next  rv test 'git reset --hard'

        """)
        let grokAfter = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(grokAfter == foreign)
    }
}

@Test func setup_pretty_occupiedGrokOnly_neverClaimsComplete() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Setup complete") == false)
        #expect(outcome.stdout.contains("rv test") == false)
        #expect(outcome.stdout == """
        ○ Grok  skipped occupied
        ○ Pi
        ○ OpenCode
        looking for hosts
        No hosts yet
        Next  rv setup

        """)
        let grokAfter = try String(contentsOfFile: layout.grokHook, encoding: .utf8)
        #expect(grokAfter == foreign)
        #expect(FileManager.default.fileExists(atPath: layout.piDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: layout.openCodeDirectory) == false)
    }
}

@Test func setupAppearance_ciForcesRobot_prettyWithoutCIStaysPretty() {
    #expect(SetupAppearance.resolved(mode: .pretty, ci: true, palette: colorOffPalette) == .robot)
    #expect(SetupAppearance.resolved(mode: .browse, ci: true, palette: colorOffPalette) == .robot)
    #expect(SetupAppearance.resolved(mode: .pretty, ci: false, palette: colorOffPalette) == .pretty(colorOffPalette))
}

@Test func setup_pretty_secondRunIsQuiet() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory,
            withIntermediateDirectories: true
        )
        _ = SetupRun.setup(env(home: home, launchctl: launchctl), appearance: .pretty(colorOffPalette))
        let second = SetupRun.setup(
            env(home: home, launchctl: launchctl),
            appearance: .pretty(colorOffPalette)
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
        #expect(outcome.stdout.contains("○") == false)
        #expect(outcome.stdout.contains("●") == false)
    }
}

@Test func setupHelp_jsonAndRobotAreOneLineNotJSON() {
    let help = Setup.helpText()
    #expect(help.contains("Robot JSON") == false)
    #expect(help.contains("One line, no circles"))
}
