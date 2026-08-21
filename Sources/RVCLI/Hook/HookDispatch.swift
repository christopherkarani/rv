import ArgumentParser
import Darwin
import Foundation
import RVDomain

/// Fast-path for `rv hook` that skips the full ArgumentParser command tree.
public enum HookDispatch {
    /// True when the first token is `hook` and HelpDispatch does not treat the
    /// argv as a help path (`-h` / `--help`).
    public static func matches(_ arguments: [String]) -> Bool {
        arguments.first == "hook" && HelpDispatch.topic(arguments: arguments) == nil
    }

    /// Parse `--host` / `--host=` the same way `Hook` does (default `.grok`),
    /// read stdin, evaluate through `Hook` + `ServiceClient`, write the wire,
    /// and exit with the codec `exitCode`. Invalid host is a nonzero exit and
    /// does not evaluate.
    public static func run(arguments: [String]) async {
        let hook = Hook.parseOrExit(arguments)
        do {
            try await hook.run()
            exit(0)
        } catch let code as ExitCode {
            exit(code.rawValue)
        } catch {
            exit(1)
        }
    }

    /// Parses hook options without constructing the `RV` command tree.
    static func parse(_ arguments: [String]) throws -> Hook {
        try Hook.parse(arguments)
    }

    /// In-process hook run for tests: same host parse, injected evaluate, no process exit.
    static func run(
        arguments: [String],
        stdin: String,
        evaluate: @Sendable (ShellCommand, String?) async -> EvaluationResult
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let hook = try parse(arguments)
        return await hook.run(stdin: stdin, evaluate: evaluate)
    }
}
