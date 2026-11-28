import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVPolicy
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The imperative shell of `rv box done`: finds this project's open box,
/// reads where it started from, and hands `BoxDoneFlow` the live box.
/// macOS only, like every box. Runs on its own (`rv box done`) and right
/// after a boxed session ends when boxed by default is on.
enum BoxDoneRun {
    /// The words `rv box done` takes after `done`.
    static let words: Set = ["--help", "-h"]

    /// `rv box done`. `agent` names who worked in the box when rv knows
    /// it; `project` is the box's project when the caller already has it.
    static func run(agent: String? = nil, project known: String? = nil) throws {
        #if !os(macOS)
        try BoxRun.refuse(BoxPlan.linuxHostRefusal)
        #else
        let project: String
        if let known {
            project = known
        } else {
            guard let surroundings = BoxRun.live() else { try BoxRun.refuse(BoxPlan.missingFolder) }
            switch BoxPlan.projectRoot(
                from: surroundings.workingDirectory, home: surroundings.home,
                homeAliases: surroundings.homeAliases, hasGitEntry: surroundings.hasGitEntry,
                identity: surroundings.identity)
            {
            case .failure(let refusal): try BoxRun.refuse(refusal)
            case .success(let root): project = root
            }
        }
        let endpoint: WorkspaceEndpoint
        switch WorkspaceHosts.inspect(project: project) {
        case .live(let live):
            endpoint = live
        case .absent:
            write(BoxDoneRender.noBox)
            return
        case let other:
            try BoxRun.refuse(BoxStartFailure.refusal(WorkspaceCommandRun.text(other)))
        }
        guard case .success(let client) = WorkspaceClient.connect(endpoint) else {
            try BoxRun.refuse(BoxStartFailure.refusal(WorkspaceCommandRun.hostNotReachableText))
        }
        guard let source = BoxHomecomingSource.live(workspace: endpoint.workspace) else {
            write(BoxDoneRender.noSource)
            throw ExitCode(1)
        }
        let running: Int
        switch client.listRuntimes() {
        case .success(let runtimes): running = runtimes.filter(\.running).count
        case .failure(let error): try BoxRun.refuse(BoxStartFailure.refusal(WorkspaceCommandRun.text(error)))
        }
        let home = BoxRun.passwdHome()
        let configDirectory = home.map { RVPolicyPaths.configDirectory(home: $0) }
        guard let configDirectory else { try BoxRun.refuse(BoxPlan.noHome) }
        let machine = BoxDoneMachine(
            source: source,
            boxRoot: endpoint.canonicalPath,
            stillRunning: running,
            agent: agent,
            home: home.flatMap { BoxRun.canonical($0.rawValue) },
            trash: BoxTrash(configDirectory: configDirectory),
            now: Date.init,
            isTerminal: isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1,
            ask: { prompt in
                write(prompt)
                return readLine()
            },
            write: write,
            close: {
                switch client.closeWorkspace() {
                case .success: nil
                case .failure(let error): WorkspaceCommandRun.text(error)
                }
            }
        )
        switch BoxDoneFlow.run(machine) {
        case .home, .keptInBox: return
        case .failed: throw ExitCode(1)
        }
        #endif
    }

    private static let stdoutPalette = BoxInk.palette(
        isTerminal: isatty(STDOUT_FILENO) == 1, environment: CLIProcess.environment())

    private static func write(_ text: String) {
        guard text.isEmpty == false else { return }
        FileHandle.standardOutput.write(Data(BoxInk.paint(text, palette: stdoutPalette).utf8))
    }
}
