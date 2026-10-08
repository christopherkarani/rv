import ArgumentParser
import Testing
import RVPolicy
import RVTheme
@testable import RVCLI

struct CommandContextTests {
    @Test func requested_absorbsOutputModeResolver() {
        #expect(CommandContext.requested(json: false, robot: false) == .automatic)
        #expect(CommandContext.requested(json: true, robot: false) == .robot)
        #expect(CommandContext.requested(json: false, robot: true) == .robot)
        #expect(CommandContext.requested(json: true, robot: true) == .robot)
    }

    @Test func homeMissingText_matchesHistoricalStanza() {
        #expect(CommandContext.homeMissingText(command: "blocks") == "rv blocks: HOME is not set\n")
        #expect(CommandContext.homeMissingText(command: "policy show") == "rv policy show: HOME is not set\n")
        #expect(CommandContext.homeMissingText(command: "setup") == "rv setup: HOME is not set\n")
        #expect(CommandContext.homeMissingText(command: "uninstall") == "rv uninstall: HOME is not set\n")
    }

    @Test func requireHome_throwsExit1WhenMissing() throws {
        let ctx = CommandContext(
            command: "blocks",
            probe: ThemeProbe(
                terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
                forbid: OutputForbid(
                    json: false, robot: false, plain: false, ci: false,
                    noColor: OutputForbid.NoColor(flag: false, env: false, termDumb: false)
                )
            ),
            requested: .automatic,
            explicitRobot: false,
            home: nil
        )
        #expect(throws: ExitCode(1)) {
            try ctx.requireHome()
        }
        #expect(throws: ExitCode(1)) {
            try ctx.failHomeMissing()
        }
    }

    @Test func current_flowsHomeTTYAndFlags() throws {
        let home = try isolatedHome()
        let ctx = try withCLIProcess(
            home: home,
            environment: ["CI": "1"],
            stdinIsTTY: true,
            stdoutIsTTY: true
        ) {
            CommandContext.current(command: "allow-once", json: false, robot: false, plain: false, noColor: false)
        }
        #expect(ctx.home == home)
        #expect(ctx.tty == TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: true))
        #expect(ctx.requested == .automatic)
        // Preserved contract split: CI forces the appearance to robot, while
        // the explicit-flags bit stays false (historical `format.json ||
        // format.robot` behavior for JSON-or-plain-text commands).
        #expect(ctx.appearance == .robot)
        #expect(ctx.isRobot)
        #expect(ctx.explicitRobot == false)
    }

    @Test func current_explicitRobotFollowsFlagsOnly() throws {
        let ctx = try withCLIProcess(stdinIsTTY: true, stdoutIsTTY: true) {
            CommandContext.current(command: "policy show", json: true, robot: false, plain: false, noColor: false)
        }
        #expect(ctx.explicitRobot)
        #expect(ctx.requested == .robot)
        #expect(ctx.appearance == .robot)
    }

    @Test func resolveAppearance_matchesCLIAppearanceResolve() throws {
        try withCLIProcess(environment: ["CI": "1"]) {
            #expect(
                CommandContext.resolveAppearance(json: false, robot: false, plain: false, noColor: false)
                    == CLIAppearance.resolve(json: false, robot: false, plain: false, noColor: false)
            )
        }
        try withCLIProcess(environment: [:], stdoutIsTTY: false) {
            #expect(
                CommandContext.resolveAppearance(json: true, robot: false, plain: false, noColor: false)
                    == CLIAppearance.resolve(json: true, robot: false, plain: false, noColor: false)
            )
        }
    }

    @Test func failAndEmit_throwGivenExitCode() throws {
        let ctx = try withCLIProcess {
            CommandContext.current(command: "scan", json: false, robot: false, plain: false, noColor: false)
        }
        #expect(throws: ExitCode(2)) {
            try ctx.fail("boom\n", exitCode: 2)
        }
        #expect(throws: ExitCode(3)) {
            try ctx.emit(stdout: "out\n", stderr: "err\n", exitCode: 3)
        }
        #expect(throws: ExitCode(1)) {
            try withCLIProcess(environment: [:]) {
                try CommandContext.requireHome(command: "scan")
            }
        }
    }

    @Test func intent_carriesCommandAndFormat() {
        let intent = CommandIntent(command: "blocks", json: true, robot: false, plain: true, noColor: false)
        #expect(intent.command == "blocks")
        #expect(intent.json)
        #expect(intent.plain)
        let ctx = CommandContext.current(intent)
        #expect(ctx.commandName == "blocks")
        #expect(ctx.explicitRobot)
        #expect(ctx.requested == .robot)
    }
}
