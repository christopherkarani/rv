import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Shared TTY appearance + outcome emission for paced setup / uninstall shows.
enum CeremonyCLI {
    static func appearance(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> (appearance: CLIAppearance, animate: Bool) {
        let appearance = CLIAppearance.resolve(
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        let animate: Bool
        if case .pretty = appearance {
            animate = isatty(STDOUT_FILENO) != 0
        } else {
            animate = false
        }
        return (appearance, animate)
    }

    static func stdoutWriter() -> (String) -> Void {
        { chunk in
            FileHandle.standardOutput.write(Data(chunk.utf8))
        }
    }

    static func emit(_ outcome: SetupOutcome) throws -> Never {
        if outcome.emitted == false, outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if outcome.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }
}
