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

    @Test func intent_initFromFormatFlags() throws {
        let format = try FormatFlags.parse(["--robot", "--no-color"])
        let intent = CommandIntent(command: "policy show", format: format)
        #expect(intent.command == "policy show")
        #expect(intent.json == false)
        #expect(intent.robot)
        #expect(intent.plain == false)
        #expect(intent.noColor)
    }

    @Test func resolveAppearance_prettyWhenTTYAndNoForbids() {
        let probe = ThemeProbe(
            stdinIsTTY: true,
            stdoutIsTTY: true,
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false,
            ci: false,
            noColorEnv: false,
            termDumb: false
        )
        #expect(
            CommandContext.resolveAppearance(probe: probe, requested: .automatic)
                == .pretty(Palette(for: ColorCapability(colorsEnabled: true)))
        )
        // Requested pretty wins even without a TTY.
        let headless = ThemeProbe(
            terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
            forbid: OutputForbid(
                json: false, robot: false, plain: false, ci: false,
                noColor: OutputForbid.NoColor(flag: false, env: false, termDumb: false)
            )
        )
        #expect(CommandContext.resolveAppearance(probe: headless, requested: .pretty) != .robot)
    }

    @Test func current_prettyWhenTTYAndNoFlags() throws {
        let ctx = try withCLIProcess(stdoutIsTTY: true) {
            CommandContext.current(command: "scan", json: false, robot: false, plain: false, noColor: false)
        }
        #expect(ctx.requested == .automatic)
        #expect(ctx.explicitRobot == false)
        #expect(ctx.isRobot == false)
        #expect(ctx.appearance == .pretty(Palette(for: ColorCapability(colorsEnabled: true))))
    }

    @Test func emit_skipsEmptyStreamsAndThrows() throws {
        let ctx = try withCLIProcess {
            CommandContext.current(command: "doctor", json: false, robot: false, plain: false, noColor: false)
        }
        #expect(throws: ExitCode(3)) {
            try ctx.emit(stdout: "", stderr: "", exitCode: 3)
        }
        #expect(throws: ExitCode(7)) {
            try CommandContext.emit(stdout: "", stderr: "", exitCode: 7)
        }
    }

    @Test func fail_defaultsToExitOne() throws {
        let ctx = try withCLIProcess {
            CommandContext.current(command: "packs", json: false, robot: false, plain: false, noColor: false)
        }
        #expect(throws: ExitCode(1)) {
            try ctx.fail("rv packs: bad\n")
        }
        #expect(throws: ExitCode(1)) {
            try CommandContext.fail("rv packs: bad\n")
        }
    }

    @Test func requireHome_returnsHomeWhenSet() throws {
        let home = try isolatedHome()
        let found = try withCLIProcess(home: home) {
            try CommandContext.requireHome(command: "scan")
        }
        #expect(found == home)
    }
}
