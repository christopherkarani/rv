import ArgumentParser
import Foundation
#if os(macOS)
import RVDomain
import RVIsolation
import RVWorkspaceTUI
#endif

struct WorkspaceTUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Open the workspace shell. Runtimes stay alive after detach."
    )

    @OptionGroup var path: WorkspacePath

    func run() async throws {
        try await WorkspaceTUICommand.run(path.workspace)
    }
}

enum WorkspaceTUICommand {
    static func run(_ raw: String?) async throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        let project = try projectPath(raw)
        guard let host = WorkspaceHostExecutable.currentSibling() else {
            throw ValidationError("workspace host executable is missing")
        }
        let endpoint: WorkspaceEndpoint
        switch WorkspaceHosts.ensure(project: project, executable: host) {
        case .success(let value):
            endpoint = value
        case .failure(let error):
            throw ValidationError(String(describing: error))
        }
        guard case .success(let client) = WorkspaceClient.connect(endpoint) else {
            throw ValidationError("workspace host is not reachable")
        }
        guard case .success(let terminalClient) = WorkspaceClient.connect(endpoint) else {
            _ = client.detach()
            throw ValidationError("workspace host is not reachable")
        }
        let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
        let described: WorkspaceTUISummary
        switch live.describe() {
        case .success(let summary):
            described = summary
        case .failure:
            _ = live.detach()
            throw ValidationError("workspace host is not reachable")
        }
        let model = WorkspaceTUIModel(
            client: live,
            summary: described,
            launcher: launcherChoices()
        )
        switch model.connect() {
        case .success:
            break
        case .failure:
            _ = live.detach()
            throw ValidationError("workspace host is not reachable")
        }
        let pump = TerminalEventPump(client: live, model: model)
        do {
            try await WorkspaceTUILaunch.run(model, pump: pump)
        } catch {
            model.detachSession()
            throw error
        }
        #endif
    }

    #if os(macOS)
    private static func projectPath(_ raw: String?) throws -> String {
        let value = raw ?? FileManager.default.currentDirectoryPath
        guard value.isEmpty == false, value.contains("\0") == false else {
            throw ValidationError("workspace path is unusable")
        }
        if value.hasPrefix("/") { return value }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(value).path
    }

    private static func launcherChoices() -> [RuntimeLaunchChoice] {
        var choices = [
            RuntimeLaunchChoice(
                id: "shell",
                title: "shell",
                executable: FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh",
                arguments: [],
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
