import ArgumentParser
import Foundation
import RVDomain
#if os(macOS)
import Darwin
import RVIsolation
#endif

struct Workspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Attach to the persistent workspace host.",
        subcommands: [
            WorkspaceStart.self, WorkspaceAttach.self, WorkspaceStatus.self, WorkspaceClose.self,
            WorkspaceRun.self, WorkspaceAgent.self, WorkspaceCustom.self,
            WorkspaceTUI.self, WorkspaceAbandon.self, WorkspaceLeftoversCommand.self,
        ]
    )
}

struct WorkspacePath: ParsableArguments {
    @Option(name: .long, help: "Project directory, not the home directory. Defaults to the current directory.")
    var workspace: String?
}

struct WorkspaceStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the workspace host, or attach when one is already live."
    )

    @OptionGroup var path: WorkspacePath

    func run() throws {
        try WorkspaceCommandRun.start(path.workspace)
    }
}

struct WorkspaceAttach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach to the live workspace host until stdin closes."
    )

    @OptionGroup var path: WorkspacePath

    func run() throws {
        try WorkspaceCommandRun.attach(path.workspace)
    }
}

struct WorkspaceStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the live workspace host, if one exists."
    )

    @OptionGroup var path: WorkspacePath

    func run() throws {
        try WorkspaceCommandRun.status(path.workspace)
    }
}

struct WorkspaceLeftoversCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leftovers",
        abstract: "List workspaces left behind by a dead host, across all projects."
    )

    func run() throws {
        try WorkspaceCommandRun.leftovers()
    }
}

struct WorkspaceRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Launch a contained runtime on a host-owned terminal and attach until it exits."
    )

    @OptionGroup var path: WorkspacePath

    @Option(name: .long, help: "Initial terminal rows. Defaults to the current terminal, or 24.")
    var rows: Int?

    @Option(name: .long, help: "Initial terminal columns. Defaults to the current terminal, or 80.")
    var columns: Int?

    @Option(name: .long, help: "Owner-authorized runtime resource profile ID. No profile is selected by executable name.")
    var resourceProfile: String?

    @Option(name: .long, help: "Hook protocol host (e.g. opencode). Tags that name no host select nothing; tags never stage credentials.")
    var hook: String?

    @Argument(parsing: .captureForPassthrough, help: "Absolute executable and arguments.")
    var command: [String] = []

    func run() throws {
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        try WorkspaceCommandRun.run(
            path.workspace, rows: rows, columns: columns, command: argv,
            resourceProfileID: resourceProfile, hook: hook
        )
    }
}

struct WorkspaceAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Launch a trusted operator-configured Agent Definition on the workspace host (not yet available)."
    )

    @OptionGroup var path: WorkspacePath

    @Option(name: .long, help: "Initial terminal rows.")
    var rows: Int?

    @Option(name: .long, help: "Initial terminal columns.")
    var columns: Int?

    @Argument(help: "Agent Definition ID from the operator's configuration.")
    var definitionID: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the configured executable.")
    var arguments: [String] = []

    func run() throws {
        let argv = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        try WorkspaceCommandRun.runAgent(
            path.workspace, definitionID: definitionID, arguments: argv,
            rows: rows, columns: columns
        )
    }
}

struct WorkspaceCustom: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "custom",
        abstract: "Launch a custom executable with an ad-hoc Agent Definition (not yet available)."
    )

    @OptionGroup var path: WorkspacePath

    @Option(name: .long, help: "Expected SHA-256 digest for the ad-hoc definition; launch does not verify the executable image.")
    var expectedContentDigestSHA256: String

    @Option(name: .long, help: "Initial terminal rows.")
    var rows: Int?

    @Option(name: .long, help: "Initial terminal columns.")
    var columns: Int?

    @Argument(parsing: .captureForPassthrough, help: "Absolute custom executable and arguments.")
    var command: [String] = []

    func run() throws {
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        try WorkspaceCommandRun.runCustom(
            path.workspace, command: argv, expectedContentDigestSHA256: expectedContentDigestSHA256,
            rows: rows, columns: columns
        )
    }
}

struct WorkspaceClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close the live workspace through its host."
    )

    @OptionGroup var path: WorkspacePath

    func run() throws {
        try WorkspaceCommandRun.close(path.workspace)
    }
}

struct WorkspaceAbandon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "abandon",
        abstract: "Abandon a blocked workspace, discarding its unpublished volume and restoring the saved tree (not yet available)."
    )

    @OptionGroup var path: WorkspacePath

    func run() throws {
        try WorkspaceCommandRun.abandon(path.workspace)
    }
}

enum WorkspaceCommandRun {
    /// Failed connect after `WorkspaceHosts.ensure` (`start`, `run`, and the
    /// workspace shell's first connect). Ensure may already have published
    /// or restored, so this text does not claim the workspace was untouched.
    static let hostNotReachableText =
        "workspace host is not reachable; run 'rv workspace status' to check its state, or 'rv doctor' if it stays unreachable"

    /// Failed connect from `attach` or `close`. Those commands use an
    /// endpoint inspect already reported as live and do not call ensure, so
    /// a failed connect leaves the volume and saved tree as they were.
    static let hostNotReachablePreservedText =
        "workspace host is not reachable: the workspace was left untouched (volume and saved changes are preserved); run 'rv workspace status' to check its state, or 'rv doctor' if it stays unreachable"

    /// Inventory or shell connect failed after the TUI session was already
    /// connected. The host was reached; this is not a host-unreachable error.
    static let workspaceSessionFailedText =
        "workspace session failed after the host was reached; run 'rv workspace status' to check its state"

    /// Shared by `workspace status` when connect fails, the inspect dump's
    /// stale endpoint (failed file validation, no connect), and client
    /// `.staleEndpoint`. The check itself does not change the volume or
    /// saved tree. A connect failure here is not always "no answer".
    static let staleEndpointText =
        "stale endpoint: the saved endpoint could not be used; this check did not change the volume or saved tree — run 'rv workspace status' to re-check, or 'rv doctor' if it persists"

    /// `rv workspace status`, `close`, and `attach` all print this block.
    /// The project path is a field: ESC and line separators stay inside it.
    static func statusLines(workspace: String, host: String, phase: String, project: String, attached: Int) -> String {
        """
        workspace \(workspace)
        host \(host)
        phase \(phase)
        project \(DisplayedText.field(project))
        attached \(attached)
        """
    }

    /// The first field of an `rv workspace leftovers` row.
    static func leftoverProjectLine(project: String, attachment: String, detail: String) -> String {
        [DisplayedText.field(project), attachment, detail].joined(separator: "  ")
    }

    static func start(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try requireProject(raw)
        let before = WorkspaceHosts.inspect(project: project)
        let endpoint = try requireEndpoint(WorkspaceHosts.ensure(project: project, executable: try hostBinary()))
        guard let client = connected(endpoint) else {
            throw ValidationError(hostNotReachableText)
        }
        let described = client.describe()
        _ = client.detach()
        switch before {
        case .live:
            emit("workspace already running")
        default:
            emit("started")
        }
        switch described {
        case .success(let description):
            emit(lines(description))
        case .failure:
            emit("workspace \(endpoint.workspace.uuidString)")
            emit("host \(endpoint.host.rawValue.uuidString)")
        }
        #endif
    }

    static func attach(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try requireProject(raw)
        guard case .live(let endpoint) = WorkspaceHosts.inspect(project: project) else {
            throw ValidationError(text(WorkspaceHosts.inspect(project: project)))
        }
        guard let client = connected(endpoint) else {
            throw ValidationError(hostNotReachablePreservedText)
        }
        let described = client.describe()
        switch described {
        case .success(let description):
            emit("attached")
            emit(lines(description))
        case .failure:
            emit("attached")
            emit("workspace \(endpoint.workspace.uuidString)")
        }
        waitForStandardInput()
        _ = client.detach()
        emit("detached")
        #endif
    }

    static func status(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try requireProject(raw)
        let attachment = WorkspaceHosts.inspect(project: project)
        guard case .live(let endpoint) = attachment else {
            emit(text(attachment))
            return
        }
        guard let client = connected(endpoint) else {
            emit(staleEndpointText)
            return
        }
        let described = client.describe()
        _ = client.detach()
        switch described {
        case .success(let description):
            emit(lines(description))
        case .failure:
            emit(text(attachment))
        }
        #endif
    }

    static func leftovers() throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        let found = WorkspaceHosts.leftovers()
        emit(leftoverReport(sessions: found, disk: WorkspaceHosts.diskLeftovers()))
        #endif
    }

    #if os(macOS)
    static func leftoverReport(sessions: [WorkspaceLeftover], disk: WorkspaceDiskLeftovers) -> String {
        var lines: [String] = []
        if sessions.isEmpty {
            lines.append("no unfinished workspace sessions")
        } else {
            lines.append("unfinished workspace sessions: \(sessions.count)")
            lines += sessions.map { "  " + leftoverLine($0) }
            lines.append("  start the project to recover it, or `rv workspace abandon --workspace <path>` when blocked")
        }
        if disk.attachedKnown == false {
            lines.append("attached workspace images: unknown (hdiutil info failed)")
        } else {
            let mounted = disk.stranded.filter { $0.mountPoint != nil }
            let unmounted = disk.stranded.count - mounted.count
            if disk.stranded.isEmpty {
                lines.append("no stranded workspace images (\(disk.attachedCount) attached, all owned by live hosts)")
            } else {
                lines.append(
                    "stranded workspace images: \(disk.stranded.count) of \(disk.attachedCount) attached"
                        + " (\(mounted.count) mounted, \(unmounted) attached without a mount)"
                )
                let retainedPaths = Set(disk.retained.map(\.imagePath))
                let retainedMounted = mounted.filter { retainedPaths.contains($0.imagePath) }
                let detachableMounted = mounted.filter { retainedPaths.contains($0.imagePath) == false }
                lines += retainedMounted.prefix(20).map { image in
                    "  \(image.mountPoint ?? "-")  \(image.device ?? "-")"
                }
                if retainedMounted.count > 20 {
                    lines.append("  … \(retainedMounted.count - 20) more mounted")
                }
                lines += detachableMounted.prefix(20).map { image in
                    "  \(image.mountPoint ?? "-")  \(image.device ?? "-")"
                }
                if detachableMounted.count > 20 {
                    lines.append("  … \(detachableMounted.count - 20) more mounted")
                }
                let detachable = disk.stranded.filter { retainedPaths.contains($0.imagePath) == false }
                if detachable.isEmpty == false {
                    if disk.retained.isEmpty {
                        lines.append("  copy out anything you need, then `hdiutil detach <device>` for each")
                    } else {
                        let targets = detachable.prefix(20).map { image in
                            "`hdiutil detach \(image.device ?? image.imagePath)`"
                        }
                        lines.append(
                            "  copy out anything you need, then " + targets.joined(separator: " ")
                        )
                    }
                }
            }
        }
        if disk.detachedImageFiles.isEmpty == false {
            lines.append("unattached workspace image files: \(disk.detachedImageFiles.count) in the temporary directory")
            lines.append("  nothing has them attached; delete them while no workspace is starting, e.g.")
            lines.append("  rm \(disk.detachedImageFiles.first ?? "")")
        }
        return lines.joined(separator: "\n")
    }
    #endif

    #if os(macOS)
    static func leftoverLine(_ leftover: WorkspaceLeftover) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return leftoverProjectLine(
            project: leftover.project,
            attachment: text(leftover.attachment),
            detail: "last \(leftover.lastEvent) at \(formatter.string(from: leftover.recordedAt))"
        )
    }
    #endif

    static func close(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try requireProject(raw)
        guard case .live(let endpoint) = WorkspaceHosts.inspect(project: project) else {
            throw ValidationError(text(WorkspaceHosts.inspect(project: project)))
        }
        guard let client = connected(endpoint) else {
            throw ValidationError(hostNotReachablePreservedText)
        }
        switch client.closeWorkspace() {
        case .success(let description):
            emit("closed")
            emit(lines(description))
        case .failure(let error):
            throw ValidationError(text(error))
        }
        #endif
    }

    static func abandon(_ raw: String?) throws {
        do {
            try LocalControlBoundary.requireOwnerAuthorization()
        } catch {
            throw ValidationError("'rv workspace abandon' is not yet available: it needs owner authorization over an authenticated service route, which does not exist yet; use 'rv workspace status' to inspect the blocked workspace")
        }
        try abandonBlockedWorkspace(raw)
    }

    /// Abandon behind the owner gate. The gate throws until
    /// authenticated service mutation routes exist; without this body an
    /// implemented gate would report success while abandoning nothing.
    static func abandonBlockedWorkspace(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let project = try requireProject(raw)
        switch WorkspaceHosts.abandon(project: project) {
        case .abandoned(let report):
            emit(lines(report))
        case .refused(let refusal):
            throw ValidationError(text(refusal))
        case .failed(let reason):
            throw ValidationError(abandonFailedText(reason))
        }
        #endif
    }

    static func run(
        _ raw: String?, rows: Int?, columns: Int?, command: [String],
        resourceProfileID: String? = nil, hook: String? = nil
    ) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        guard let executable = command.first, executable.hasPrefix("/"), executable.contains("\0") == false else {
            throw ValidationError("executable must be an absolute path")
        }
        let arguments = Array(command.dropFirst())
        guard arguments.contains(where: { $0.contains("\0") }) == false else {
            throw ValidationError("executable must be an absolute path")
        }
        if let hook, AgentTagValidator.isValid(hook) == false {
            throw ValidationError("hook must be an agent tag of 1-32 letters, digits, '-', '.', or '_'")
        }
        let project = try requireProject(raw)
        try runInteractive(
            project: project,
            executable: executable,
            arguments: arguments,
            hook: hook.flatMap(HookHost.init(rawValue:)),
            rows: rows,
            columns: columns,
            resourceProfileID: resourceProfileID
        )
        #endif
    }

    static func runAgent(
        _ raw: String?, definitionID: String, arguments: [String], rows: Int?, columns: Int?
    ) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        guard AgentDefinitionID(validating: definitionID) != nil else {
            throw ValidationError("invalid Agent Definition ID")
        }
        guard arguments.contains(where: { $0.contains("\0") }) == false else {
            throw ValidationError("arguments must not contain NUL bytes")
        }
        try runInteractiveSelection(
            project: requireProject(raw), selection: .named(definitionID: definitionID),
            arguments: arguments, rows: rows, columns: columns
        )
        #endif
    }

    static func runCustom(
        _ raw: String?, command: [String], expectedContentDigestSHA256: String,
        rows: Int?, columns: Int?
    ) throws {
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        guard let executable = command.first, executable.hasPrefix("/"),
            executable.contains("\0") == false,
            expectedContentDigestSHA256.utf8.count == 64,
            expectedContentDigestSHA256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw ValidationError("custom launch requires an absolute executable and lowercase SHA-256 digest")
        }
        guard command.dropFirst().contains(where: { $0.contains("\0") }) == false else {
            throw ValidationError("arguments must not contain NUL bytes")
        }
        try runInteractiveSelection(
            project: requireProject(raw),
            selection: .custom(executable: executable, digest: expectedContentDigestSHA256),
            arguments: Array(command.dropFirst()), rows: rows, columns: columns
        )
        #endif
    }

    private enum InteractiveSelection {
        case legacy(executable: String, hook: HookHost?)
        case named(definitionID: String)
        case custom(executable: String, digest: String)
    }

    /// One interactive launch path for every agent frontend. `workspace run`
    /// and the `rv opencode` compatibility command both arrive here, so PTY
    /// ownership, the terminal bridge, resize, and exit propagation cannot
    /// drift between entrypoints.
    static func runInteractive(
        project: String,
        executable: String,
        arguments: [String],
        hook: HookHost?,
        rows: Int?,
        columns: Int?,
        resourceProfileID: String? = nil
    ) throws {
        try runInteractiveSelection(
            project: project,
            selection: .legacy(executable: executable, hook: hook),
            arguments: arguments, rows: rows, columns: columns, resourceProfileID: resourceProfileID
        )
    }

    private static func runInteractiveSelection(
        project: String,
        selection: InteractiveSelection,
        arguments: [String],
        rows: Int?,
        columns: Int?,
        resourceProfileID: String? = nil
    ) throws {
        // Identity launch requires a scoped operator permit, which the
        // ceremony cannot issue yet. Fail before spawning or contacting a
        // host so the reserved ops never reach the wire from here.
        switch selection {
        case .named, .custom:
            throw ValidationError("identity launches are not yet available: they require a scoped operator permit, which cannot be issued yet; use 'rv workspace run -- <absolute-executable> [args...]' for a contained launch")
        case .legacy:
            break
        }
        #if !os(macOS)
        throw ValidationError(ContainedRuntimeRefusal.message)
        #else
        let endpoint = try requireEndpoint(
            WorkspaceHosts.ensure(project: project, executable: try hostBinary())
        )
        guard let client = connected(endpoint) else {
            throw ValidationError(hostNotReachableText)
        }
        let window = LocalTerminalWindow.current(fd: STDOUT_FILENO)
        let rows = rows ?? window?.rows ?? TerminalStreamLimits.defaultRows
        let columns = columns ?? window?.columns ?? TerminalStreamLimits.defaultColumns
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else {
            throw ValidationError("terminal size is out of range")
        }
        let launched: Result<WorkspaceRuntimeReport, WorkspaceClientFailure>
        switch selection {
        case .legacy(let executable, let hook):
            launched = client.launchRuntime(
                executable: executable, arguments: arguments, hookHost: hook,
                terminalRows: rows, terminalColumns: columns,
                resourceProfileID: resourceProfileID
            )
        case .named(let definitionID):
            launched = client.launchAgentRuntime(
                definitionID: definitionID, arguments: arguments,
                terminalRows: rows, terminalColumns: columns
            )
        case .custom(let executable, let digest):
            launched = client.launchCustomRuntime(
                executable: executable, arguments: arguments, expectedContentDigestSHA256: digest,
                terminalRows: rows, terminalColumns: columns
            )
        }
        let runtime: UUID
        switch launched {
        case .failure(let error):
            _ = client.detach()
            throw ValidationError(text(error, resourceProfileID: resourceProfileID))
        case .success(let report):
            guard report.terminal else {
                _ = client.detach()
                throw ValidationError("runtime has no terminal")
            }
            runtime = report.runtime
        }
        if case .failure(let error) = client.subscribeTerminal(runtime) {
            _ = client.detach()
            throw ValidationError(text(error))
        }
        let ownsInput: Bool
        switch client.acquireTerminalInput(runtime) {
        case .success:
            ownsInput = true
        case .failure(.terminalUnavailable):
            // The runtime can exit before this client takes input. The exit
            // status is still on the stream.
            ownsInput = false
        case .failure(let error):
            _ = client.detach()
            throw ValidationError(text(error))
        }
        let restorer = ownsInput ? LocalTerminalRestorer.engage(STDIN_FILENO) : nil
        defer { restorer?.restore() }
        let bridge = TerminalStdinBridge(client: client, runtime: runtime)
        if ownsInput {
            bridge.start()
        }
        // A pipe or /dev/null EOFs immediately; only a terminal EOF (Ctrl-D)
        // means the user wants out. Abandoning on any EOF cuts slow
        // commands short with a success exit.
        let stdinIsTTY = isatty(STDIN_FILENO) == 1
        var exitCode: Int32 = 1
        var currentRows = rows
        var currentColumns = columns
        while true {
            if abandonRunOnInputEnd(ownsInput: ownsInput, stdinIsTTY: stdinIsTTY, inputEnded: bridge.inputEnded) {
                restorer?.restore()
                _ = client.detach()
                return
            }
            if let size = LocalTerminalWindow.current(fd: STDOUT_FILENO),
                size.rows != currentRows || size.columns != currentColumns
            {
                currentRows = size.rows
                currentColumns = size.columns
                _ = client.resizeTerminal(runtime, rows: size.rows, columns: size.columns)
            }
            switch client.nextTerminalEvent(timeout: 0.2) {
            case .failure(let error):
                restorer?.restore()
                _ = client.detach()
                throw ValidationError(text(error))
            case .success(.waiting):
                continue
            case .success(.event(let event)):
                guard event.runtime == runtime else { continue }
                switch event.body {
                case .replayBegin, .replayEnd:
                    // The direct CLI writes a fresh byte stream to stdout; it
                    // has no retained terminal screen to reconcile.
                    break
                case .replay(_, let bytes), .output(_, let bytes):
                    FileHandle.standardOutput.write(bytes)
                case .exited(let status):
                    exitCode = status
                    restorer?.restore()
                    _ = client.detach()
                    throw ExitCode(exitCode)
                case .overflow:
                    restorer?.restore()
                    _ = client.detach()
                    throw ValidationError("terminal client fell behind")
                case .inputOwner, .window:
                    break
                }
            }
        }
        #endif
    }

    #if os(macOS)
    static func requireProject(
        _ raw: String?,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let shellDirectory = environment["PWD"].flatMap { candidate -> String? in
            guard candidate.hasPrefix("/"), candidate.isEmpty == false, candidate.contains("\0") == false else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return candidate
        }
        let baseDirectory = shellDirectory ?? currentDirectory
        let value = raw ?? baseDirectory
        guard value.isEmpty == false, value.contains("\0") == false else {
            throw ValidationError("workspace path is unusable")
        }
        if value.hasPrefix("/") { return value }
        return URL(fileURLWithPath: baseDirectory, isDirectory: true).appendingPathComponent(value).path
    }

    private static func hostBinary() throws -> URL {
        guard let url = WorkspaceHostExecutable.currentSibling() else {
            throw ValidationError("workspace host executable is missing")
        }
        return url
    }

    private static func requireEndpoint(
        _ result: Result<WorkspaceEndpoint, WorkspaceHostFailure>
    ) throws -> WorkspaceEndpoint {
        switch result {
        case .success(let endpoint):
            return endpoint
        case .failure(let error):
            throw ValidationError(text(error))
        }
    }

    private static func connected(_ endpoint: WorkspaceEndpoint) -> WorkspaceClient? {
        switch WorkspaceClient.connect(endpoint) {
        case .success(let client):
            return client
        case .failure:
            return nil
        }
    }

    static func lines(_ description: WorkspaceDescription) -> String {
        statusLines(
            workspace: description.workspace.uuidString,
            host: description.host.rawValue.uuidString,
            phase: description.phase.rawValue,
            project: description.project,
            attached: description.attached
        )
    }

    private static func lines(_ report: WorkspaceAbandonReport) -> String {
        var emitted = [
            "abandoned \(report.workspace.uuidString)",
            "restored \(report.originalPath)",
        ]
        if report.volumePresent {
            emitted.append("volume discarded")
        } else {
            emitted.append("volume missing")
        }
        emitted.append("discarded \(report.discardedCount)")
        for relative in report.discarded {
            emitted.append("discarded-path \(relative)")
        }
        emitted.append("retained \(report.retainedCount)")
        for relative in report.retained {
            emitted.append("retained-path \(relative)")
        }
        if report.uncomparedCount > 0 {
            emitted.append("uncompared \(report.uncomparedCount)")
        }
        if report.truncated {
            emitted.append("truncated")
        }
        return emitted.joined(separator: "\n")
    }

    /// `.failed` from `abandonLocked` can land after `recoveryBegan`, child
    /// teardown, unmount, restore, or owned-file cleanup. Those steps are
    /// idempotent, so the next action is status, then retry. "Nothing was
    /// changed" is reserved for `.refused`.
    static func abandonFailedText(_ reason: WorkspaceRecoveryBlock.Reason?) -> String {
        let head = reason.map { "abandon stopped: \($0.rawValue)" } ?? "abandon failed"
        return head + ": abandon stopped before it finished; the workspace may already be mid-abandon"
            + " (journal recoveryBegan, child teardown, unmount, restore, or owned-file cleanup);"
            + " run 'rv workspace status', then retry 'rv workspace abandon' (steps are idempotent)"
    }

    /// Abandon is legal only for `publicationConflict` and `missingVolume`
    /// (`WorkspaceRecovery.abandonPhaseRefusal`). Every other block refuses.
    static func blockedRecoveryText(_ reason: WorkspaceRecoveryBlock.Reason) -> String {
        switch reason {
        case .publicationConflict:
            return "recovery blocked: publicationConflict: run 'rv workspace status' for state,"
                + " or 'rv workspace abandon' to discard the volume and restore the saved tree"
        case .missingVolume:
            return "recovery blocked: missingVolume: the volume is already absent and the saved tree is untouched;"
                + " run 'rv workspace abandon' to restore the saved tree, or 'rv workspace status' for state"
        case .tornLog, .corrupt, .ambiguousOwnership, .ambiguousSavedTree, .unprovenProcess, .unrelatedMount:
            return "recovery blocked: \(reason.rawValue): abandon will refuse;"
                + " run 'rv workspace status' and 'rv doctor' for state"
        }
    }

    static func text(_ attachment: WorkspaceAttachment) -> String {
        switch attachment {
        case .absent:
            "no workspace: no workspace host is running for this project; run 'rv workspace start' to create one"
        case .live(let endpoint):
            "workspace \(endpoint.workspace.uuidString)"
        case .starting:
            "workspace host is starting: the host is not ready yet; wait, then run 'rv workspace status'"
        case .orphaned(let id):
            "orphaned \(id.uuidString): the workspace host exited without closing; run 'rv workspace status', then 'rv workspace start' to reclaim it"
        case .recovering(let id):
            "recovering \(id.uuidString): workspace recovery is in progress; wait, then run 'rv workspace status'"
        case .blocked(let block):
            blockedRecoveryText(block.reason)
        case .staleEndpoint:
            staleEndpointText
        case .unsupported:
            "contained workspace host is unavailable on this platform; run 'rv doctor' to check the installation"
        }
    }

    static func text(_ refusal: WorkspaceAbandonRefusal) -> String {
        switch refusal {
        case .live:
            "workspace is live; close it instead: nothing was changed — run 'rv workspace close'; retry 'rv workspace abandon' only for publicationConflict or missingVolume"
        case .notBlocked:
            "workspace is not blocked: nothing was changed and no abandon is needed; run 'rv workspace status' to see its state, or 'rv workspace start' to use it"
        case .configurationUnavailable:
            "workspace host configuration is unavailable: nothing was changed and the workspace state could not be checked; run 'rv doctor' to inspect the installation"
        case .unsafeReason(let reason):
            "abandon refused: \(reason.rawValue): nothing was changed; this block cannot be cleared by abandoning — run 'rv workspace status' and 'rv doctor' for state"
        case .unprovenOwner:
            "abandon refused: workspace ownership is unproven: nothing was changed; run 'rv workspace status' and 'rv doctor'; do not delete workspace files by hand"
        }
    }

    static func text(_ error: WorkspaceHostFailure) -> String {
        switch error {
        case .unsupported:
            ContainedRuntimeRefusal.message
        case .projectUnusable:
            "workspace path is unusable"
        case .homeDirectory:
            "home directory cannot be a workspace root; pass --workspace <project directory>"
        case .hostBinaryMissing:
            "workspace host executable is missing"
        case .spawnFailed:
            "workspace host failed to start"
        case .recoveryBlocked(let block):
            blockedRecoveryText(block.reason)
        case .endpointUnavailable:
            "workspace host endpoint is unavailable"
        case .timedOut:
            "workspace host did not become ready"
        case .hostExited:
            "workspace host failed"
        case .control(let failure):
            text(failure)
        }
    }

    /// Launch-failure text with the requested profile echoed. The id appears
    /// only when the request carried one; other failures are unchanged.
    static func text(_ error: WorkspaceClientFailure, resourceProfileID: String?) -> String {
        if error == .resourceProfileUnavailable, let resourceProfileID {
            return "runtime resource profile '\(resourceProfileID)' is unavailable for this project"
        }
        if case .resourceStagingFailed(let detail) = error, let resourceProfileID {
            return "runtime resource profile '\(resourceProfileID)' staging failed: \(detail) is unusable"
        }
        return text(error)
    }

    static func text(_ error: WorkspaceClientFailure) -> String {
        switch error {
        case .disconnected: "workspace host disconnected"
        case .malformed: "workspace host rejected the request"
        case .queueOverloaded: "workspace host client queue is overloaded"
        case .requestTooLarge:
            "command exceeds the workspace control limit (\(WorkspaceControlLimits.maxArguments) arguments, \(WorkspaceControlLimits.maxArgumentBytes) bytes each, \(WorkspaceControlLimits.maxBodyBytes) bytes total)"
        case .timedOut: "workspace host timed out"
        case .incompatibleProtocol: "incompatible workspace protocol; close the workspace and retry (rv workspace close)"
        case .unauthorizedClient: "unauthorized workspace client"
        case .workspaceClosing: "workspace is closing"
        case .workspaceClosed: "workspace is closed"
        case .runtimeNotFound: "runtime not found"
        case .invalidRequest: "invalid workspace request"
        case .requiresOperatorPermit: "operator permits not yet available"
        case .resourceProfileUnavailable: "runtime resource profile is unavailable"
        case .resourceStagingFailed(let detail): "runtime resource staging failed: \(detail) is unusable"
        case .recoveryRequired: "workspace recovery is required: run 'rv workspace status' for state; run 'rv workspace abandon' only when that status is publicationConflict or missingVolume"
        case .childTeardownFailed: "runtime teardown failed"
        case .runtimeLimit: "workspace runtime limit reached"
        case .staleEndpoint: staleEndpointText
        case .terminalUnavailable: "runtime has no terminal"
        case .terminalBusy: "terminal input is owned by another client"
        case .terminalLimit: "terminal subscriber limit reached"
        case .terminalPrefixCommitted: "terminal input was partially written"
        }
    }

    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func waitForStandardInput() {
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
        }
    }
    #endif
}

/// Whether a local stdin EOF abandons `workspace run` instead of waiting
/// for the runtime to exit. Only an interactive terminal EOFs on purpose
/// (Ctrl-D); a pipe or /dev/null EOFs immediately and must not cut a slow
/// command's output short with a success exit.
func abandonRunOnInputEnd(ownsInput: Bool, stdinIsTTY: Bool, inputEnded: Bool) -> Bool {
    ownsInput && stdinIsTTY && inputEnded
}
