import ArgumentParser
import Foundation
import RVPolicy
import RVTheme

/// What a command parsed, before the context door builds the prologue.
/// Mirrors `SetupIntent`: commands pass what they parsed (failure name plus
/// format flags) and the context owns the rest.
struct CommandIntent: Sendable {
    let command: String
    let json: Bool
    let robot: Bool
    let plain: Bool
    let noColor: Bool

    init(command: String, json: Bool = false, robot: Bool = false, plain: Bool = false, noColor: Bool = false) {
        self.command = command
        self.json = json
        self.robot = robot
        self.plain = plain
        self.noColor = noColor
    }

    init(command: String, format: FormatFlags) {
        self.init(command: command, json: format.json, robot: format.robot, plain: format.plain, noColor: format.noColor)
    }
}

/// One deep command context per invocation: home, appearance, emit, exit.
///
/// Depth: commands receive a context rather than construct the per-command
/// prologue. The home-missing stanza, the requested-mode derivation
/// (absorbed from `OutputModeResolver`), the CI-aware appearance algorithm,
/// and the stdout/stderr/exit convention each live here exactly once; the
/// leverage is that commands keep only argv shape plus unique run/render
/// logic, and the locality is that prologue drift has one place to fix.
///
/// Two robot/pretty semantics survive behind this one seam, because they are
/// contractually different bytes (CON-001): `appearance` is CI/TTY-aware
/// (CI or a non-TTY stdout renders robot), while `explicitRobot` honors the
/// operator's `--json`/`--robot` flags only. Appearance-rendered commands
/// (scan, doctor, service) branch on `appearance`; JSON-or-plain-text
/// commands (policy, packs, allowlist, allow-once, blocks, policy draft)
/// branch on `explicitRobot`, exactly as their historical
/// `format.json || format.robot` checks did.
struct CommandContext: Sendable {
    /// Failure prefix after `rv `, e.g. `policy show`.
    let commandName: String
    let probe: ThemeProbe
    let requested: RequestedMode
    /// CI-aware resolved appearance. Prefer this for rendered output.
    let appearance: CLIAppearance
    /// The operator passed `--json`/`--robot`. CI/TTY-independent.
    let explicitRobot: Bool
    let home: HomeDirectory?
    let tty: TTYCapability

    /// Production door; builds the full prologue once per invocation.
    static func current(_ intent: CommandIntent) -> CommandContext {
        current(
            command: intent.command,
            json: intent.json,
            robot: intent.robot,
            plain: intent.plain,
            noColor: intent.noColor
        )
    }

    static func current(command: String, format: FormatFlags) -> CommandContext {
        current(
            command: command,
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
    }

    static func current(command: String, json: Bool, robot: Bool, plain: Bool, noColor: Bool) -> CommandContext {
        CommandContext(
            command: command,
            probe: ThemeProbeFactory.live(
                jsonFlag: json,
                robotFlag: robot,
                plainFlag: plain,
                noColorFlag: noColor
            ),
            requested: requested(json: json, robot: robot),
            explicitRobot: json || robot,
            home: CLIProcess.home()
        )
    }

    /// Seam for bespoke probes: help dispatch builds its own probe (fixed
    /// flags, custom TTY/environment merge) but resolves appearance here.
    init(
        command: String,
        probe: ThemeProbe,
        requested: RequestedMode,
        explicitRobot: Bool,
        home: HomeDirectory? = nil
    ) {
        self.commandName = command
        self.probe = probe
        self.requested = requested
        self.appearance = Self.resolveAppearance(probe: probe, requested: requested)
        self.explicitRobot = explicitRobot
        self.home = home
        self.tty = TTYCapability(
            stdinIsTTY: probe.terminal.stdinIsTTY,
            stdoutIsTTY: probe.terminal.stdoutIsTTY,
            ci: probe.forbid.ci
        )
    }

    /// CI-aware robot check for appearance-rendered commands.
    var isRobot: Bool { appearance == .robot }

    // MARK: - Output resolution (the single robot/pretty path)

    /// Requested-mode derivation, absorbed from `OutputModeResolver`.
    static func requested(json: Bool, robot: Bool) -> RequestedMode {
        if json || robot { return .robot }
        return .automatic
    }

    /// The single appearance algorithm: CI forces robot, else the probe and
    /// requested mode decide. `CLIAppearance.resolve` delegates here.
    static func resolveAppearance(probe: ThemeProbe, requested: RequestedMode) -> CLIAppearance {
        if probe.ci { return .robot }
        let mode = OutputMode(probe: probe, requested: requested)
        switch mode {
        case .robot:
            return .robot
        case .pretty:
            return .pretty(Palette(for: ColorCapability(probe: probe, mode: mode)))
        }
    }

    /// Live convenience: probe plus requested mode plus the algorithm.
    static func resolveAppearance(json: Bool, robot: Bool, plain: Bool, noColor: Bool) -> CLIAppearance {
        resolveAppearance(
            probe: ThemeProbeFactory.live(
                jsonFlag: json,
                robotFlag: robot,
                plainFlag: plain,
                noColorFlag: noColor
            ),
            requested: requested(json: json, robot: robot)
        )
    }

    // MARK: - Home (the single home-missing site, AC-004)

    /// The one home-missing stderr line. Setup flows embed this text in an
    /// outcome instead of writing it; every other command throws it via
    /// `requireHome`/`failHomeMissing`.
    static func homeMissingText(command: String) -> String {
        "rv \(command): HOME is not set\n"
    }

    static func failHomeMissing(command: String) throws -> Never {
        writeStderr(homeMissingText(command: command))
        throw ExitCode(1)
    }

    func failHomeMissing() throws -> Never {
        try Self.failHomeMissing(command: commandName)
    }

    /// Flagless commands (no `FormatFlags` to build a context from) require
    /// home through here; same line and exit code as `requireHome()`.
    static func requireHome(command: String) throws -> HomeDirectory {
        guard let home = CLIProcess.home() else {
            try failHomeMissing(command: command)
        }
        return home
    }

    @discardableResult
    func requireHome() throws -> HomeDirectory {
        guard let home else {
            try failHomeMissing()
        }
        return home
    }

    // MARK: - Emission (the single stdout/stderr/exit convention)

    static func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    func writeStdout(_ text: String) {
        Self.writeStdout(text)
    }

    func writeStderr(_ text: String) {
        Self.writeStderr(text)
    }

    static func fail(_ message: String, exitCode: Int32 = 1) throws -> Never {
        writeStderr(message)
        throw ExitCode(exitCode)
    }

    func fail(_ message: String, exitCode: Int32 = 1) throws -> Never {
        try Self.fail(message, exitCode: exitCode)
    }

    static func emit(stdout: String, stderr: String = "", exitCode: Int32) throws -> Never {
        if stdout.isEmpty == false {
            writeStdout(stdout)
        }
        if stderr.isEmpty == false {
            writeStderr(stderr)
        }
        throw ExitCode(exitCode)
    }

    func emit(stdout: String, stderr: String = "", exitCode: Int32) throws -> Never {
        try Self.emit(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
