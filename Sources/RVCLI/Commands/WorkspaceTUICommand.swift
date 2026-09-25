import ArgumentParser
import Foundation
#if os(macOS)
import Darwin
import RVDomain
import RVIsolation
import RVWorkspaceTUI
#endif

public struct WorkspaceTUI: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Open the workspace shell. Runtimes stay alive after detach."
    )

    @OptionGroup var path: WorkspacePath

    public init() {}

    public func run() async throws {
        try await WorkspaceTUICommand.run(path.workspace)
    }
}

enum WorkspaceTUICommand {
    static func run(_ raw: String?) async throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ValidationError("workspace shell requires an interactive terminal")
        }
        let project = try WorkspaceCommandRun.requireProject(raw)
        guard let host = WorkspaceHostExecutable.currentSibling() else {
            throw ValidationError("workspace host executable is missing")
        }
        let endpoint: WorkspaceEndpoint
        switch WorkspaceHosts.ensure(project: project, executable: host) {
        case .success(let value):
            endpoint = value
        case .failure(let error):
            throw ValidationError(WorkspaceCommandRun.text(error))
        }
        guard case .success(let session) = LiveWorkspaceTUISession.connect(endpoint) else {
            throw ValidationError("workspace host is not reachable")
        }
        let described: WorkspaceTUISummary
        switch session.inventory() {
        case .success(let inventoried):
            described = inventoried.summary
        case .failure:
            session.close()
            throw ValidationError("workspace host is not reachable")
        }
        let model = WorkspaceTUIModel(
            session: session,
            summary: described,
            launcher: launcherChoices()
        )
        switch model.connect() {
        case .success:
            model.launchDefaultRuntimeIfEmpty()
        case .failure:
            session.close()
            throw ValidationError("workspace host is not reachable")
        }
        do {
            try await WorkspaceTUILaunch.run(model)
        } catch {
            model.detachSession()
            throw error
        }
        #endif
    }

    #if os(macOS)
    static func launcherChoices() -> [RuntimeLaunchChoice] {
        // The sandbox cannot see user dotfiles, so zsh starts with default
        // options, including PROMPT_SP (stray `%` lines). Preset it off for
        // the default shell only; a workspace-local .zshrc still overrides.
        // Plain sh has no such option and takes no arguments.
        let zshPath = "/bin/zsh"
        let shellExecutable = FileManager.default.isExecutableFile(atPath: zshPath) ? zshPath : "/bin/sh"
        let shellArguments = shellExecutable == zshPath ? ["-o", "NO_PROMPT_SP"] : []
        var choices = [
            RuntimeLaunchChoice(
                id: "shell",
                title: "shell",
                executable: shellExecutable,
                arguments: shellArguments,
                hook: nil
            ),
        ]
        if let opencode = opencodeExecutable() {
            choices.append(
                RuntimeLaunchChoice(
                    id: "opencode",
                    title: "opencode",
                    executable: opencode,
                    arguments: [],
                    hook: HookHost.opencode.rawValue
                )
            )
        }
        return choices
    }

    private static func opencodeExecutable() -> String? {
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            guard entry.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent("opencode").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    #endif
}
