import Foundation
import RVDomain
import RVIsolation

/// Validated `rv opencode` launch. `OpenCodeCommand.swift` is a thin
/// frontend and must not import RVIsolation (see `WorkspaceOwnershipTests`),
/// so validation that needs isolation types lives here and exposes plain
/// strings across the file boundary.
struct OpenCodePreparedCommand: Sendable {
    var executable: String
    var arguments: [String]
}

enum OpenCodeLaunchError: Error, Sendable, Equatable {
    case executableMustBeAbsolute
    case executableUnavailable
    case workspaceMustBeAbsolute
    case command(IsolationApplyError)

    var message: String {
        switch self {
        case .executableMustBeAbsolute:
            "--executable must be an absolute path without NUL bytes."
        case .executableUnavailable:
            "OpenCode executable unavailable; supply --executable or an absolute PATH directory."
        case .workspaceMustBeAbsolute:
            "--workspace must be an absolute path without NUL bytes."
        case .command(let error):
            "invalid agent command: \(error)."
        }
    }
}

extension OpenCodeRun {
    static func prepare(
        executable: String?,
        arguments: [String],
        workspace: String,
        environment: [String: String]
    ) -> Result<OpenCodePreparedCommand, OpenCodeLaunchError> {
        let path: String
        switch resolveExecutable(executable, environment: environment) {
        case .success(let resolved): path = resolved
        case .failure(let error): return .failure(error)
        }
        guard workspace.hasPrefix("/"), workspace.contains("\0") == false,
            WorkingDirectory(validating: workspace) != nil
        else {
            return .failure(.workspaceMustBeAbsolute)
        }
        switch IsolatedCommand.make(executable: path, arguments: arguments) {
        case .success(let validated):
            return .success(OpenCodePreparedCommand(
                executable: validated.executable,
                arguments: validated.arguments
            ))
        case .failure(let error): return .failure(.command(error))
        }
    }
}
