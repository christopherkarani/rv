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
        subcommands: [WorkspaceStart.self, WorkspaceAttach.self, WorkspaceStatus.self, WorkspaceClose.self]
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
