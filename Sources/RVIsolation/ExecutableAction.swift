import Foundation
import RVDomain

public enum ExecutableCompileError: Error, Sendable, Equatable {
    case fileActionUnsupported
    case missingCommand
    case commandNotSimpleArgv
    case executableNotResolved
    case workingDirectoryRequired
    case workspaceMismatch
}

/// Capability plus compiled argv plus isolation intent. Not a spawn.
///
/// Production construction is `compileExecutable`. The memberwise
/// initializer is a `@testable` seam, like `AllowedAction`.
public struct ExecutableAction: Sendable, Equatable {
    public let allowed: AllowedAction
    public let command: IsolatedCommand
    public let plan: IsolationPlan

    init(allowed: AllowedAction, command: IsolatedCommand, plan: IsolationPlan) {
        self.allowed = allowed
        self.command = command
        self.plan = plan
    }
}

/// Compiles an authorized proposal into argv. Does not decide and does not spawn.
public func compileExecutable(
    allowed: AllowedAction,
    plan: IsolationPlan
) -> Result<ExecutableAction, ExecutableCompileError> {
    switch allowed.action {
    case .file:
        return .failure(.fileActionUnsupported)
    case .shell(let shell):
        switch compileSimpleArgv(shell.supportingCommand) {
        case .failure(let error):
            return .failure(error)
        case .success(let command):
            return bindWorkspace(allowed: allowed, command: command, plan: plan)
        }
    }
}

private let simpleArgvMetacharacters: Set<Character> = [
    "|", "&", ";", "<", ">", "(", ")", "$", "`", "\"", "'", "\\", "\n", "*", "?", "[", "]",
]

private let safeExecutableDirectories = ["/usr/bin", "/bin"]

private func compileSimpleArgv(
    _ supportingCommand: ShellCommand?
) -> Result<IsolatedCommand, ExecutableCompileError> {
    guard let raw = supportingCommand?.rawValue, raw.isEmpty == false else {
        return .failure(.missingCommand)
    }
    if raw.contains(where: { simpleArgvMetacharacters.contains($0) }) {
        return .failure(.commandNotSimpleArgv)
    }
    let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let first = tokens.first, first.isEmpty == false else {
        return .failure(.missingCommand)
    }
    let arguments = Array(tokens.dropFirst())
    switch resolveExecutable(first) {
    case .failure(let error):
        return .failure(error)
    case .success(let executable):
        switch IsolatedCommand.make(executable: executable, arguments: arguments) {
        case .success(let command):
            return .success(command)
        case .failure:
            return .failure(.executableNotResolved)
        }
    }
}

private func resolveExecutable(_ token: String) -> Result<String, ExecutableCompileError> {
    if token.hasPrefix("/") {
        guard FileManager.default.fileExists(atPath: token) else {
            return .failure(.executableNotResolved)
        }
        return .success(token)
    }
    if token.contains("/") {
        return .failure(.executableNotResolved)
    }
    for directory in safeExecutableDirectories {
        let candidate = "\(directory)/\(token)"
        if isRegularFile(at: candidate) {
            return .success(candidate)
        }
    }
    return .failure(.executableNotResolved)
}

private func isRegularFile(at path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue == false
}

private func bindWorkspace(
    allowed: AllowedAction,
    command: IsolatedCommand,
    plan: IsolationPlan
) -> Result<ExecutableAction, ExecutableCompileError> {
    guard let actionCwd = allowed.action.scope.workingDirectory, let planWorkspace = plan.workspace
    else {
        return .failure(.workingDirectoryRequired)
    }
    guard actionCwd == planWorkspace else {
        return .failure(.workspaceMismatch)
    }
    return .success(ExecutableAction(allowed: allowed, command: command, plan: plan))
}
