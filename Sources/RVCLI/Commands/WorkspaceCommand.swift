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
            WorkspaceRun.self,
        ]
    )
}

struct WorkspacePath: ParsableArguments {
    @Option(name: .long, help: "Project path. Defaults to the current directory.")
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

    @Argument(parsing: .captureForPassthrough, help: "Absolute executable and arguments.")
    var command: [String] = []

    func run() throws {
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        try WorkspaceCommandRun.run(path.workspace, rows: rows, columns: columns, command: argv)
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

enum WorkspaceCommandRun {
    static func start(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        let project = try requireProject(raw)
        let before = WorkspaceHosts.inspect(project: project)
        let endpoint = try requireEndpoint(WorkspaceHosts.ensure(project: project, executable: try hostBinary()))
        guard let client = connected(endpoint) else {
            throw ValidationError("workspace host is not reachable")
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
        throw ValidationError("contained workspace host is unavailable")
        #else
        let project = try requireProject(raw)
        guard case .live(let endpoint) = WorkspaceHosts.inspect(project: project) else {
            throw ValidationError(text(WorkspaceHosts.inspect(project: project)))
        }
        guard let client = connected(endpoint) else {
            throw ValidationError("workspace host is not reachable")
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
        throw ValidationError("contained workspace host is unavailable")
        #else
        let project = try requireProject(raw)
        let attachment = WorkspaceHosts.inspect(project: project)
        guard case .live(let endpoint) = attachment else {
            emit(text(attachment))
            return
        }
        guard let client = connected(endpoint) else {
            emit("stale endpoint")
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

    static func close(_ raw: String?) throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        let project = try requireProject(raw)
        guard case .live(let endpoint) = WorkspaceHosts.inspect(project: project) else {
            throw ValidationError(text(WorkspaceHosts.inspect(project: project)))
        }
        guard let client = connected(endpoint) else {
            throw ValidationError("workspace host is not reachable")
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

    static func run(_ raw: String?, rows: Int?, columns: Int?, command: [String]) throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        guard let executable = command.first, executable.hasPrefix("/"), executable.contains("\0") == false else {
            throw ValidationError("executable must be an absolute path")
        }
        let arguments = Array(command.dropFirst())
        guard arguments.contains(where: { $0.contains("\0") }) == false else {
            throw ValidationError("executable must be an absolute path")
        }
        let project = try requireProject(raw)
        let endpoint = try requireEndpoint(
            WorkspaceHosts.ensure(project: project, executable: try hostBinary())
        )
        guard let client = connected(endpoint) else {
            throw ValidationError("workspace host is not reachable")
        }
        let window = LocalTerminalWindow.current(fd: STDOUT_FILENO)
        let rows = rows ?? window?.rows ?? TerminalStreamLimits.defaultRows
        let columns = columns ?? window?.columns ?? TerminalStreamLimits.defaultColumns
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else {
            throw ValidationError("terminal size is out of range")
        }
        let launched = client.launchRuntime(
            executable: executable,
            arguments: arguments,
            terminalRows: rows,
            terminalColumns: columns
        )
        let runtime: UUID
        switch launched {
        case .failure(let error):
            _ = client.detach()
            throw ValidationError(text(error))
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
        var exitCode: Int32 = 1
        var currentRows = rows
        var currentColumns = columns
        while true {
            if ownsInput, bridge.inputEnded {
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
                case .inputOwner:
                    break
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private static func requireProject(_ raw: String?) throws -> String {
        let value = raw ?? FileManager.default.currentDirectoryPath
        guard value.isEmpty == false, value.contains("\0") == false else {
            throw ValidationError("workspace path is unusable")
        }
        if value.hasPrefix("/") { return value }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(value).path
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

    private static func lines(_ description: WorkspaceDescription) -> String {
        """
        workspace \(description.workspace.uuidString)
        host \(description.host.rawValue.uuidString)
        phase \(description.phase.rawValue)
        project \(description.project)
        attached \(description.attached)
        """
    }

    private static func text(_ attachment: WorkspaceAttachment) -> String {
        switch attachment {
        case .absent:
            "no workspace"
        case .live(let endpoint):
            "workspace \(endpoint.workspace.uuidString)"
        case .starting:
            "workspace host is starting"
        case .orphaned(let id):
            "orphaned \(id.uuidString)"
        case .recovering(let id):
            "recovering \(id.uuidString)"
        case .blocked(let block):
            "recovery blocked: \(block.reason.rawValue)"
        case .staleEndpoint:
            "stale endpoint"
        case .unsupported:
            "contained workspace host is unavailable"
        }
    }

    private static func text(_ error: WorkspaceHostFailure) -> String {
        switch error {
        case .unsupported:
            "contained workspace host is unavailable"
        case .projectUnusable:
            "workspace path is unusable"
        case .hostBinaryMissing:
            "workspace host executable is missing"
        case .spawnFailed:
            "workspace host failed to start"
        case .recoveryBlocked(let block):
            "recovery blocked: \(block.reason.rawValue)"
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

    private static func text(_ error: WorkspaceClientFailure) -> String {
        switch error {
        case .disconnected: "workspace host disconnected"
        case .malformed: "workspace host rejected the request"
        case .timedOut: "workspace host timed out"
        case .incompatibleProtocol: "incompatible workspace protocol"
        case .unauthorizedClient: "unauthorized workspace client"
        case .workspaceClosing: "workspace is closing"
        case .workspaceClosed: "workspace is closed"
        case .runtimeNotFound: "runtime not found"
        case .invalidRequest: "invalid workspace request"
        case .recoveryRequired: "workspace recovery is required"
        case .childTeardownFailed: "runtime teardown failed"
        case .runtimeLimit: "workspace runtime limit reached"
        case .staleEndpoint: "stale endpoint"
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

#if os(macOS)
private final class TerminalStdinBridge: @unchecked Sendable {
    private let client: WorkspaceClient
    private let runtime: UUID
    private let input: Int32
    private let lock = NSLock()
    private var ended = false

    init(client: WorkspaceClient, runtime: UUID) {
        self.client = client
        self.runtime = runtime
        self.input = STDIN_FILENO
    }

    init(client: WorkspaceClient, runtime: UUID, input: Int32) {
        self.client = client
        self.runtime = runtime
        self.input = input
    }

    var didEnd: Bool {
        lock.lock()
        let value = ended
        lock.unlock()
        return value
    }

    var inputEnded: Bool {
        lock.lock()
        let value = ended
        lock.unlock()
        return value
    }

    func start() {
        let bridge = self
        let thread = Thread {
            bridge.read()
        }
        thread.name = "rv-terminal-stdin"
        thread.start()
    }

    private func read() {
        LocalTerminalRestorer.blockInterruptSignalsInThisThread()
        var buffer = [UInt8](repeating: 0, count: TerminalStreamLimits.maximumInputBytes)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 {
                markEnded()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                markEnded()
                return
            }
            let data = Data(buffer.prefix(count))
            if case .failure = client.writeTerminal(runtime, bytes: data) {
                markEnded()
                return
            }
        }
    }

    private func markEnded() {
        lock.lock()
        ended = true
        lock.unlock()
    }
}
#endif
