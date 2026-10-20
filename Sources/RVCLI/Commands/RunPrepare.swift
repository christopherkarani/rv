import Foundation
import RVDomain
import RVIsolation

/// Validated `rv run` launch. `RunCommand.swift` is a thin frontend and must
/// not import RVIsolation, so validation that needs isolation types lives
/// here and exposes plain strings across the file boundary.
struct RunPreparedCommand: Sendable {
    var executable: String
    var arguments: [String]
}

enum RunLaunchError: Error, Sendable, Equatable {
    case emptyCommand
    case executableMustBeAbsolute(String)
    case executableUnavailable(String)
    case workspaceMustBeAbsolute
    case command(IsolationApplyError)

    var message: String {
        switch self {
        case .emptyCommand:
            "rv run needs a command after --"
        case .executableMustBeAbsolute(let name):
            "command \(DisplayedText.field(name)) contains a path separator; give an absolute path or a bare name to find on PATH."
        case .executableUnavailable(let name):
            "command \(DisplayedText.field(name)) is not available; give an absolute path or a name on an absolute PATH directory."
        case .workspaceMustBeAbsolute:
            "--workspace must be an absolute path without NUL bytes."
        case .command(let error):
            "invalid command: \(error)."
        }
    }
}

extension RunRun {
    static func prepare(
        command: [String],
        workspace: String,
        environment: [String: String]
    ) -> Result<RunPreparedCommand, RunLaunchError> {
        guard let head = command.first else { return .failure(.emptyCommand) }
        let resolved: Result<String, OpenCodeLaunchError>
        if head.hasPrefix("/") {
            resolved = OpenCodeRun.resolveExecutable(head, named: "", environment: environment)
        } else if head.contains("/") {
            return .failure(.executableMustBeAbsolute(head))
        } else {
            resolved = OpenCodeRun.resolveExecutable(nil, named: head, environment: environment)
        }
        let path: String
        switch resolved {
        case .success(let found): path = found
        case .failure(.executableMustBeAbsolute): return .failure(.executableMustBeAbsolute(head))
        case .failure: return .failure(.executableUnavailable(head))
        }
        guard workspace.hasPrefix("/"), workspace.contains("\0") == false,
            WorkingDirectory(validating: workspace) != nil
        else {
            return .failure(.workspaceMustBeAbsolute)
        }
        switch IsolatedCommand.make(executable: path, arguments: Array(command.dropFirst())) {
        case .success(let validated):
            return .success(RunPreparedCommand(executable: validated.executable, arguments: validated.arguments))
        case .failure(let error): return .failure(.command(error))
        }
    }

    /// Dotenv-bound secrets in the live configuration, or nil when a
    /// configuration exists but cannot be read. A profile-less run takes
    /// no lease, so an unreadable configuration must not read as zero
    /// bindings (that would degrade fail-closed to a warning).
    static func dotenvBoundCount(environment: [String: String]) -> Int? {
        guard let home = environment["HOME"], home.hasPrefix("/"), home.contains("\0") == false else { return 0 }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
        guard case .success(let configuration) = SecretsConfiguration.load(configDirectory: directory) else { return nil }
        return dotenvBoundCount(in: configuration)
    }

    static func dotenvBoundCount(in configuration: SecretsConfiguration) -> Int {
        configuration.secrets.count { $0.source.kind == "dotenv" }
    }
}
