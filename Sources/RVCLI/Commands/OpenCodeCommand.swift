import ArgumentParser
import Foundation
import RVDomain
import RVEngine
import RVIsolation

enum OpenCodeLaunchError: Error, Sendable, Equatable {
    case executableMustBeAbsolute
    case executableUnavailable
    case workspaceMustBeAbsolute
    case command(IsolationApplyError)
    case launch(HostLaunchError)

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
        case .launch(let error):
            "contained agent launch failed: \(error)."
        }
    }
}

enum OpenCodeRun {
    /// This command still owns one runtime inside the invoking process so its
    /// exit status stays the agent status. Persistent attach is `rv workspace`.
    static let isolationNotice =
        "rv opencode: writes stay in the workspace. Reads include that workspace and the system locations needed to start programs. Network is denied. Signals to processes outside the sandbox are denied. On Linux this launch is refused until the kernel backend enforces those limits.\n"

    static func run(
        executable: String?,
        arguments: [String],
        workspace: String,
        environment: [String: String]
    ) -> Result<Int32, OpenCodeLaunchError> {
        let path: String
        switch resolveExecutable(executable, environment: environment) {
        case .success(let resolved): path = resolved
        case .failure(let error): return .failure(error)
        }
        guard workspace.hasPrefix("/"), workspace.contains("\0") == false,
            let directory = WorkingDirectory(validating: workspace)
        else {
            return .failure(.workspaceMustBeAbsolute)
        }
        let plan = compileContainedPlan(workspace: directory)
        let command: IsolatedCommand
        switch IsolatedCommand.make(executable: path, arguments: arguments) {
        case .success(let validated): command = validated
        case .failure(let error): return .failure(.command(error))
        }
        return launchContainedHost(
            host: .opencode,
            command: command,
            plan: plan,
            admission: OpenCodeRun.admission
        )
        .map(\.exitStatus)
        .mapError(OpenCodeLaunchError.launch)
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

    /// Shell requests from the contained agent use `AgentAuthorization`, not the hook gate.
    static var admission: RuntimeAdmissionConfiguration { RuntimeAdmissionConfiguration(
        normalize: { subject, action in
            switch action {
            case .http(let method, let url):
                return normalizeRuntimeHTTP(
                    subject: subject,
                    method: method,
                    url: url,
                    resolve: { name in
                        resolveAdmittedHTTPHost(
                            name,
                            budgetMilliseconds: HTTPEgressLimits.requestTimeoutMilliseconds,
                            lookup: resolveHTTPHost
                        )
                    }
                )
            case .shell:
                return normalizeRuntimeAdmission(subject: subject, action: action)
            }
        },
        executor: .containedCommand,
        http: .direct,
        approval: { _ in nil },
        policy: { _ in .empty },
        evidence: RuntimeAdmissionEvidence(appendingTo: RuntimeAdmissionEvidence.productionFile())
    )}

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
        FileHandle.standardError.write(Data(OpenCodeRun.isolationNotice.utf8))
        switch OpenCodeRun.run(
            executable: executable,
            arguments: arguments,
            workspace: workspace ?? CLIProcess.workspacePath(),
            environment: CLIProcess.environment()
        ) {
        case .success(let status):
            if status != 0 { throw ExitCode(status) }
        case .failure(let error):
            throw ValidationError(error.message)
        }
    }
}
