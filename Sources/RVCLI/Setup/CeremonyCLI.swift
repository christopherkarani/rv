import ArgumentParser
import Foundation

/// Shared TTY appearance + outcome emission for paced setup / uninstall shows.
enum CeremonyCLI {
    static func appearance(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> (appearance: CLIAppearance, animate: Bool) {
        let appearance = CommandContext.resolveAppearance(
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        let animate: Bool
        if case .pretty = appearance {
            animate = CLIProcess.stdoutIsTTY()
        } else {
            animate = false
        }
        return (appearance, animate)
    }

    static func stdoutWriter() -> (String) -> Void {
        { chunk in
            CommandContext.writeStdout(chunk)
        }
    }

    static func emit(_ outcome: SetupOutcome) throws -> Never {
        write(outcome)
        throw ExitCode(outcome.exitCode)
    }

    /// The outcome's text, without exiting: a step that follows setup
    /// (the keys step) prints after it.
    static func write(_ outcome: SetupOutcome) {
        if outcome.emitted == false, outcome.stdout.isEmpty == false {
            CommandContext.writeStdout(outcome.stdout)
        }
        if outcome.stderr.isEmpty == false {
            CommandContext.writeStderr(outcome.stderr)
        }
    }
}
