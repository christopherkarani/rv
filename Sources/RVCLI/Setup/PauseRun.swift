#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHistory
import RVPolicy

/// `rv pause 10m` (H4, v3 Everyday Magic "Pause, with a seatbelt."): the
/// owner, at a terminal, with the owner check, watches every host instead
/// of blocking for up to an hour; rv comes back on its own.
///
/// The pause is one `guard.pause` window in `config.json` (`HostModeStore`,
/// shared with F3's temporary blocks). Nothing it covers is overwritten, so
/// coming back needs no write and no rvd: every reader resolves the window
/// against the clock (`GuardModeResolution.resolve`), and a window past
/// `GuardWindow.pauseLimit` or with a clock set back before it reads as
/// closed. Agents can never pause: without a terminal no owner check is
/// even shown, and the check itself is what an agent cannot pass.
/// Ending a pause early tightens, so it needs no check.
enum PauseRun {
    /// Shortest and longest pause.
    static let shortest: TimeInterval = 60
    static let longest: TimeInterval = GuardWindow.pauseLimit

    /// `10m`, `30min`, `1h`: whole minutes or hours, 1 minute to 1 hour.
    static func duration(_ text: String) -> TimeInterval? {
        let lowered = text.lowercased()
        let units: [(suffix: String, seconds: TimeInterval)] = [("min", 60), ("m", 60), ("h", 3600)]
        guard let unit = units.first(where: { lowered.hasSuffix($0.suffix) }),
              let count = Int(lowered.dropLast(unit.suffix.count)), count > 0
        else { return nil }
        let seconds = TimeInterval(count) * unit.seconds
        return (shortest...longest).contains(seconds) ? seconds : nil
    }

    /// "10 min" or "1 hour", as the owner check names it.
    static func spoken(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? "1 hour" : "\(Int(seconds / 60)) min"
    }

    struct StatusDocument: Encodable, Equatable {
        let paused: Bool
        let schema = "rv.pause.v1"
        var until: String? = nil
    }

    /// The countdown line: `◐ Paused until 14:22 · 8 min left`.
    static func pausedLine(_ window: GuardWindow, now: Date, timeZone: TimeZone) -> String {
        "\(CommandVocabulary.Glyph.watched.rawValue) Paused until "
            + "\(ClockText.hourMinute(window.until, timeZone: timeZone)) · "
            + ClockText.minutesLeft(window.secondsLeft(at: now))
    }

    private static var endCommand: String { "\(CommandVocabulary.Command.pause.invocation) --end" }
    private static var pauseCommand: String { "\(CommandVocabulary.Command.pause.invocation) 10m" }
    private static var next: String { CommandVocabulary.Glyph.next.rawValue }
    private static var rvGlyph: String { CommandVocabulary.Glyph.rv.rawValue }

    /// Pauses for `seconds`. `authenticate` is the owner check (it returns
    /// how the owner was checked, for the audit event); it runs only at a
    /// terminal and only after every refusal that needs no owner.
    static func pause(
        for seconds: TimeInterval,
        env: SetupEnvironment,
        requester: HostModeRequester,
        now: () -> Date = Date.init,
        timeZone: TimeZone = .current,
        authenticate: (String) async throws -> String
    ) async -> SetupOutcome {
        do {
            try SetupRun.requireInstalledCopy(env)
        } catch {
            return failure("rv pause failed: run the installed rv (\(env.rvPath)), not this copy\n", exitCode: EX_USAGE)
        }
        if env.managedEnforce(env.home) {
            return failure("rv pause failed: organization policy keeps rv guarding this Mac\n", exitCode: EX_NOPERM)
        }
        guard requester.atTerminal else {
            return failure(
                "rv pause needs you at your terminal with Touch ID or your password; an agent can't pause rv\n",
                exitCode: EX_NOPERM)
        }
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: env.home))
        // Refuse a file no writer may rewrite before asking the owner.
        guard store.readGuardConfig() != nil else {
            return failure(ConfigUnreadableRefusal.message(prefix: "rv pause failed"), exitCode: ConfigUnreadableRefusal.exitCode)
        }
        let authorization: String
        do {
            authorization = try await authenticate("pause rv for \(spoken(seconds))")
        } catch {
            return failure("rv pause failed: device-owner authentication required; rv was not paused\n", exitCode: EX_NOPERM)
        }
        // The window starts after the owner answered, so a slow prompt
        // never eats into the pause.
        let window = GuardWindow(startingAt: now(), lasting: seconds)
        do {
            try ConfigChangeAudit.$authorization.withValue(authorization) {
                try store.savePause(window)
            }
        } catch {
            return writeFailure(error)
        }
        return SetupOutcome(
            stdout: [
                "\(CommandVocabulary.Glyph.watched.rawValue) Paused until \(ClockText.hourMinute(window.until, timeZone: timeZone)).",
                "  still stopped   rm -rf ~ and /, rv's own files",
                "  rv comes back on its own. To come back now:",
                "\(next) \(endCommand)",
            ].joined(separator: "\n") + "\n",
            exitCode: 0)
    }

    /// Bare `rv pause`: a question, not a change. The countdown while
    /// paused, else that rv is guarding.
    static func status(_ env: SetupEnvironment, json: Bool, now: Date = Date(), timeZone: TimeZone = .current) -> SetupOutcome {
        let config = GuardConfig.read(home: env.home)
        let open = config.activePause(at: now)
        if json {
            let document = StatusDocument(paused: open != nil, until: open.map { ClockText.iso($0.until) })
            return SetupOutcome(stdout: ((try? RobotJSON.encode(document)) ?? "") + "\n", exitCode: 0)
        }
        if let open {
            return SetupOutcome(
                stdout: pausedLine(open, now: now, timeZone: timeZone) + "\n"
                    + "  rv comes back on its own. To come back now:\n"
                    + "\(next) \(endCommand)\n",
                exitCode: 0)
        }
        if let ended = config.pause, ended.until <= now, ended.isOpen(at: ended.from, limit: GuardWindow.pauseLimit) {
            return SetupOutcome(
                stdout: "\(rvGlyph) rv is back. It was paused until \(ClockText.hourMinute(ended.until, timeZone: timeZone)).\n",
                exitCode: 0)
        }
        return SetupOutcome(
            stdout: "\(rvGlyph) rv is guarding.\n  To pause it for ten minutes, you type:\n\(next) \(pauseCommand)\n",
            exitCode: 0)
    }

    /// `rv pause --end`: back now. A tightening, so no owner check; any
    /// pause record, open or not, is removed.
    static func end(_ env: SetupEnvironment, now: Date = Date()) -> SetupOutcome {
        let store = HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: env.home))
        guard let config = store.readGuardConfig() else {
            return failure(ConfigUnreadableRefusal.message(prefix: "rv pause failed"), exitCode: ConfigUnreadableRefusal.exitCode)
        }
        guard config.pause != nil else {
            return SetupOutcome(stdout: "\(rvGlyph) rv is guarding.\n", exitCode: 0)
        }
        do {
            try ConfigChangeAudit.$authorization.withValue(nil) {
                try store.clearPause()
            }
        } catch {
            return writeFailure(error)
        }
        return SetupOutcome(stdout: "\(CommandVocabulary.Glyph.done.rawValue) \(rvGlyph) rv is back.\n", exitCode: 0)
    }

    private static func writeFailure(_ error: Error) -> SetupOutcome {
        switch error {
        case OwnerConfigWriteError.unreadable:
            return failure(ConfigUnreadableRefusal.message(prefix: "rv pause failed"), exitCode: ConfigUnreadableRefusal.exitCode)
        case let unrecorded as ConfigChangeUnrecorded:
            return failure(ConfigChangeRefusal.message(command: "pause", unrecorded), exitCode: ConfigChangeRefusal.exitCode)
        default:
            return failure("rv pause failed: unable to write config.json\n", exitCode: EX_CANTCREAT)
        }
    }

    private static func failure(_ stderr: String, exitCode: Int32) -> SetupOutcome {
        SetupOutcome(stdout: "", stderr: stderr, exitCode: exitCode)
    }
}
