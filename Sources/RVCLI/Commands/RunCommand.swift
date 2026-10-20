import ArgumentParser
import Foundation
import RVDomain

enum RunRun {
    /// Dev-tier frontend: resolves the command, attaches to the persistent
    /// workspace host, and streams one terminal. The profile's secrets
    /// (including dotenv sources) stage through the normal lease path.
    static let isolationNotice =
        "rv run: runs on the persistent workspace host. Writes stay in the workspace. Reads include that workspace and the system locations needed to start programs. Public HTTPS goes through the RV proxy; direct public and LAN connections are denied. Signals to processes outside the sandbox are denied. On Linux this launch is refused until the kernel backend enforces those limits. Limits: \(AcceptedRuntimeLimits.line)\n"

    static let missingProfileWarning =
        "rv run: no --resource-profile selected; no secrets or credentials are staged. Pass --resource-profile <id> to stage them (profile IDs are defined in ~/.config/rv/runtime-resources.json). Run `rv init` in the project to generate one.\n"

    /// Profile-less runs stage nothing. With dotenv bindings that would be
    /// silent non-injection, so it fails closed and loud instead.
    static func missingProfileRefusal(dotenvBoundCount: Int) -> String {
        "rv run: no --resource-profile selected; \(dotenvBoundCount) dotenv-bound secret\(dotenvBoundCount == 1 ? "" : "s") would not stage. "
            + "Pass --resource-profile <id> to stage them (profile IDs are defined in ~/.config/rv/runtime-resources.json). "
            + "Run `rv init --dotenv` in the project to generate one.\n"
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command on the workspace host with the profile's secrets staged.",
        discussion: """
            Examples:
              rv run --resource-profile main -- python main.py
              rv run --workspace /path/to/repo --resource-profile main -- npm test

            The command is found on PATH (absolute directories only) or given
            as an absolute path. Secrets stage only for the named profile;
            agent-tagged secrets do not stage here because `rv run` passes no
            agent tag. Without --resource-profile, nothing stages: with
            dotenv-bound secrets that is an error, not a warning.
            """
    )

    @Option(help: "Project path; default is the current directory.")
    var workspace: String?

    @Option(name: .long, help: "Owner-authorized runtime resource profile ID. No profile is selected by executable name.")
    var resourceProfile: String?

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments, after --.")
    var command: [String] = []

    func run() throws {
        guard Task.isCancelled == false else { throw ExitCode(130) }
        let arguments = command.first == "--" ? Array(command.dropFirst()) : command
        guard arguments.isEmpty == false else {
            throw ValidationError("rv run needs a command: rv run --resource-profile <id> -- <command> [args...]")
        }
        FileHandle.standardError.write(Data(RunRun.isolationNotice.utf8))
        let project = workspace ?? CLIProcess.workspacePath()
        let prepared: RunPreparedCommand
        switch RunRun.prepare(command: arguments, workspace: project, environment: CLIProcess.environment()) {
        case .success(let built):
            prepared = built
        case .failure(let error):
            throw ValidationError(error.message)
        }
        if resourceProfile == nil {
            guard let dotenvBound = RunRun.dotenvBoundCount(environment: CLIProcess.environment()) else {
                FileHandle.standardOutput.write(Data((
                    "rv run: secrets.json could not be read, so dotenv bindings cannot be checked. "
                        + "Fix ~/.config/rv/secrets.json or pass --resource-profile <id> (the lease will report the error).\n"
                ).utf8))
                throw ExitCode(1)
            }
            if dotenvBound > 0 {
                FileHandle.standardOutput.write(Data(RunRun.missingProfileRefusal(dotenvBoundCount: dotenvBound).utf8))
                throw ExitCode(1)
            }
            FileHandle.standardError.write(Data(RunRun.missingProfileWarning.utf8))
        }
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        try WorkspaceCommandRun.runInteractive(
            project: WorkspaceCommandRun.requireProject(
                workspace,
                currentDirectory: FileManager.default.currentDirectoryPath,
                environment: CLIProcess.environment()
            ),
            executable: prepared.executable,
            arguments: prepared.arguments,
            hook: nil,
            rows: nil,
            columns: nil,
            resourceProfileID: resourceProfile
        )
        #endif
    }
}
