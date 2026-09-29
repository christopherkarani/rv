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
    /// Compatibility frontend: this command owns no workspace and no
    /// runtime. It resolves the agent executable, attaches to the
    /// persistent workspace host for the project, and streams one
    /// host-owned terminal until the runtime exits.
    static let isolationNotice =
        "rv opencode: runs on the persistent workspace host. Writes stay in the workspace. Reads include that workspace and the system locations needed to start programs. Public HTTPS goes through the RV proxy; direct public and LAN connections are denied. Signals to processes outside the sandbox are denied. On Linux this launch is refused until the kernel backend enforces those limits.\n"

    /// No profile is implicit: without one the host stages no credentials
    /// and provider auth fails inside the cage. Warn instead of failing so
    /// keyless runs (local models, `--help`) keep working.
    static let missingProfileWarning =
        "rv opencode: no --resource-profile selected; provider credentials are unstaged and agent auth will fail. Pass --resource-profile <id> to stage them.\n"

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

    static func resolveExecutable(
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
        abstract: "Launch OpenCode on the persistent workspace host."
    )

    @Option(help: "Absolute OpenCode executable; otherwise search absolute PATH directories.")
    var executable: String?

    @Option(help: "Project path; default is the current directory.")
    var workspace: String?

    @Option(name: .long, help: "Owner-authorized runtime resource profile ID. No profile is selected by executable name.")
    var resourceProfile: String?

    @Option(name: .long, help: "Launch agent tag for credential staging. Hook protocol applies only when the tag names a hook host.")
    var hook: String = "opencode"

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed unchanged to OpenCode.")
    var agentArguments: [String] = []

    func run() throws {
        guard Task.isCancelled == false else { throw ExitCode(130) }
        let arguments = agentArguments.first == "--" ? Array(agentArguments.dropFirst()) : agentArguments
        FileHandle.standardError.write(Data(OpenCodeRun.isolationNotice.utf8))
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
        if resourceProfile == nil {
            FileHandle.standardError.write(Data(OpenCodeRun.missingProfileWarning.utf8))
        }
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        try WorkspaceCommandRun.runInteractive(
            project: WorkspaceCommandRun.requireProject(
                workspace,
                currentDirectory: FileManager.default.currentDirectoryPath,
                environment: CLIProcess.environment()
            ),
            executable: command.executable,
            arguments: command.arguments,
            hook: hook,
            rows: nil,
            columns: nil,
            resourceProfileID: resourceProfile
        )
        #endif
    }
}
