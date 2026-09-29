import ArgumentParser
import Foundation
import RVDomain

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

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed unchanged to OpenCode.")
    var agentArguments: [String] = []

    func run() throws {
        guard Task.isCancelled == false else { throw ExitCode(130) }
        let arguments = agentArguments.first == "--" ? Array(agentArguments.dropFirst()) : agentArguments
        FileHandle.standardError.write(Data(OpenCodeRun.isolationNotice.utf8))
        let project = workspace ?? CLIProcess.workspacePath()
        let command: OpenCodePreparedCommand
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
            hook: .opencode,
            rows: nil,
            columns: nil,
            resourceProfileID: resourceProfile
        )
        #endif
    }
}
