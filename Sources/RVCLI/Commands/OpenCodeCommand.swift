import ArgumentParser
import Foundation
import RVDomain
import RVIsolation

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

enum OpenCodeRun {
    static let isolationNotice =
        "rv opencode: launching through the persistent workspace host; sandbox access follows workspace host policy.\n"

    static func prepare(
        executable: String?,
        arguments: [String],
        workspace: String,
        environment: [String: String]
    ) -> Result<IsolatedCommand, OpenCodeLaunchError> {
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
        case .success(let validated): return .success(validated)
        case .failure(let error): return .failure(.command(error))
        }
    }

    private static func resolveExecutable(
        _ explicit: String?,
        environment: [String: String]
    ) -> Result<String, OpenCodeLaunchError> {
        if let explicit {
            guard explicit.hasPrefix("/"), explicit.contains("\0") == false else {
                return .failure(.executableMustBeAbsolute)
            }
            return usableExecutable(explicit).map(Result.success) ?? .failure(.executableUnavailable)
        }
        for entry in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            guard entry.hasPrefix("/"), entry.contains("\0") == false else { continue }
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent("opencode").path
            if let path = usableExecutable(candidate) { return .success(path) }
        }
        return .failure(.executableUnavailable)
    }

    private static func usableExecutable(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue == false,
            FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

struct OpenCode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "opencode",
        abstract: "Launch OpenCode inside a workspace-scoped sandbox."
    )

    @Option(help: "Absolute OpenCode executable; otherwise search absolute PATH directories.")
    var executable: String?

    @Option(help: "Absolute writable workspace (default: current directory).")
    var workspace: String?

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed unchanged to OpenCode.")
    var agentArguments: [String] = []

    func run() throws {
        guard Task.isCancelled == false else { throw ExitCode(130) }
        let arguments = agentArguments.first == "--" ? Array(agentArguments.dropFirst()) : agentArguments
        let project = workspace ?? CLIProcess.workspacePath()
        let command: IsolatedCommand
        switch OpenCodeRun.prepare(
            executable: executable,
            arguments: arguments,
            workspace: project,
            environment: CLIProcess.environment()
        ) {
        case .success(let prepared):
            command = prepared
        case .failure(let error):
            throw ValidationError(error.message)
        }
        FileHandle.standardError.write(Data(OpenCodeRun.isolationNotice.utf8))
        try WorkspaceCommandRun.run(
            project,
            rows: nil,
            columns: nil,
            command: [command.executable] + command.arguments
        )
    }
}
