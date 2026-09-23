#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

public enum WorkspaceClientFailure: Error, Sendable, Equatable {
    case disconnected
    case malformed
    case timedOut
    case incompatibleProtocol
    case unauthorizedClient
    case workspaceClosing
    case workspaceClosed
    case runtimeNotFound
    case invalidRequest
    case recoveryRequired
    case childTeardownFailed
    case staleEndpoint
}

public enum WorkspaceHostFailure: Error, Sendable, Equatable {
    case unsupported
    case projectUnusable
    case hostBinaryMissing
    case spawnFailed
    case recoveryBlocked(WorkspaceRecoveryBlock)
    case endpointUnavailable
    case timedOut
    case hostExited(Int32)
    case control(WorkspaceClientFailure)
}

public enum WorkspaceHostExit {
    public static let closed: Int32 = 0
    public static let failed: Int32 = 1
    public static let unsupported: Int32 = 2
    public static let liveOwner: Int32 = 75
    public static let recoveryBlocked: Int32 = 76
}

/// Authenticated control client. It never receives workspace or runtime capabilities.
public final class WorkspaceClient: @unchecked Sendable {
    private let endpoint: WorkspaceEndpoint
    private let writeLock = Mutex(0)
    private let state: Mutex<ClientState>

    private struct ClientState {
        var fd: Int32
        var open: Bool
    }

    private init(fd: Int32, endpoint: WorkspaceEndpoint) {
        self.endpoint = endpoint
        self.state = Mutex(ClientState(fd: fd, open: true))
    }

    deinit {
        let fd = state.withLock { current -> Int32 in
            let fd = current.fd
            current.open = false
            current.fd = -1
            return fd
        }
        if fd >= 0 { close(fd) }
    }

    public static func connect(
        _ endpoint: WorkspaceEndpoint
    ) -> Result<WorkspaceClient, WorkspaceClientFailure> {
        guard endpoint.uid == UInt32(getuid()) else { return .failure(.unauthorizedClient) }
        guard let identity = WorkspaceControlSocket.identity(endpoint.socketPath),
            identity.device == endpoint.socketDevice,
            identity.inode == endpoint.socketInode
        else {
            return .failure(.staleEndpoint)
        }
        let fd: Int32
        switch WorkspaceControlSocket.connect(
            path: endpoint.socketPath,
            timeout: WorkspaceControlLimits.connectTimeoutSeconds
        ) {
        case .failure(.timedOut):
            return .failure(.timedOut)
        case .failure:
            return .failure(.disconnected)
        case .success(let connected):
            fd = connected
        }
        guard let after = WorkspaceControlSocket.identity(endpoint.socketPath),
            after == identity
        else {
            close(fd)
            return .failure(.staleEndpoint)
        }
        let client = WorkspaceClient(fd: fd, endpoint: endpoint)
        switch client.hello() {
        case .failure(let error):
            client.finish()
            return .failure(error)
        case .success(let message):
            guard message.ok == true,
                message.host == endpoint.host.rawValue,
                message.workspace == endpoint.workspace
            else {
                client.finish()
                return .failure(.staleEndpoint)
            }
            return .success(client)
        }
    }

    public func ping() -> Result<Void, WorkspaceClientFailure> {
        transact(op: .ping, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func describe() -> Result<WorkspaceDescription, WorkspaceClientFailure> {
        switch transact(op: .describeWorkspace, timeout: WorkspaceControlLimits.describeTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let message):
            return description(message)
        }
    }

    public func listRuntimes() -> Result<[WorkspaceRuntimeReport], WorkspaceClientFailure> {
        switch transact(op: .listRuntimes, timeout: WorkspaceControlLimits.describeTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let message):
            return .success(message.runtimes ?? [])
        }
    }

    public func launchRuntime(
        executable: String,
        arguments: [String] = [],
        hookHost: HookHost? = nil
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.launchRuntime.rawValue,
            executable: executable,
            arguments: arguments,
            hook: hookHost?.rawValue
        )
        switch transact(&message, timeout: WorkspaceControlLimits.launchTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard let runtime = reply.runtime, let running = reply.running else {
                return .failure(.malformed)
            }
            return .success(
                WorkspaceRuntimeReport(runtime: runtime, hook: reply.hook, running: running)
            )
        }
    }

    public func cancelRuntime(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.cancelRuntime.rawValue,
            runtime: runtime
        )
        return transact(&message, timeout: WorkspaceControlLimits.launchTimeoutSeconds).map { _ in () }
    }

    public func closeWorkspace() -> Result<WorkspaceDescription, WorkspaceClientFailure> {
        switch transact(op: .closeWorkspace, timeout: WorkspaceControlLimits.closeTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let message):
            return description(message)
        }
    }

    public func detach() -> Result<Void, WorkspaceClientFailure> {
        let result = transact(op: .detach, timeout: WorkspaceControlLimits.describeTimeoutSeconds)
        finish()
        return result.map { _ in () }
    }

    /// Blocks until the host reports that the workspace closed.
    public func watchClose(
        timeout: TimeInterval = WorkspaceControlLimits.closeTimeoutSeconds
    ) -> Result<WorkspaceDescription, WorkspaceClientFailure> {
        while true {
            switch read(timeout: timeout) {
            case .failure(let error):
                return .failure(error)
            case .success(let message):
                guard message.op == WorkspaceControlOp.workspaceClosed.rawValue else {
                    continue
                }
                return description(message)
            }
        }
    }

    private func hello() -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.hello.rawValue,
            token: endpoint.ownerToken
        )
        return transact(&message, timeout: WorkspaceControlLimits.connectTimeoutSeconds)
    }

    private func transact(
        op: WorkspaceControlOp,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: op.rawValue
        )
        return transact(&message, timeout: timeout)
    }

    private func transact(
        _ message: inout WorkspaceControlMessage,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        guard let body = WorkspaceControlCodec.encode(message) else { return .failure(.malformed) }
        let wrote = writeLock.withLock { _ in
            guard let fd = fileDescriptor() else { return false }
            return WorkspaceControlSocket.writeFrame(fd: fd, body: body)
        }
        guard wrote else { return .failure(.disconnected) }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 { return .failure(.timedOut) }
            switch read(timeout: remain) {
            case .failure(let error):
                return .failure(error)
            case .success(let reply):
                if reply.op == WorkspaceControlOp.workspaceClosed.rawValue,
                    reply.id != message.id
                {
                    return .failure(.workspaceClosed)
                }
                guard reply.id == message.id else { return .failure(.malformed) }
                return interpret(reply)
            }
        }
    }

    private func read(timeout: TimeInterval) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        guard let fd = fileDescriptor() else { return .failure(.disconnected) }
        switch WorkspaceControlSocket.readFrame(fd: fd, timeout: timeout) {
        case .failure(.timedOut):
            return .failure(.timedOut)
        case .failure:
            return .failure(.disconnected)
        case .success(let data):
            switch WorkspaceControlCodec.decode(data) {
            case .incompatible:
                return .failure(.incompatibleProtocol)
            case .invalid:
                return .failure(.malformed)
            case .message(let message):
                return .success(message)
            }
        }
    }

    private func interpret(
        _ message: WorkspaceControlMessage
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        guard message.ok != false else {
            guard let code = message.error.flatMap(WorkspaceControlCode.init(rawValue:)) else {
                return .failure(.malformed)
            }
            return .failure(clientFailure(code))
        }
        return .success(message)
    }

    private func description(
        _ message: WorkspaceControlMessage
    ) -> Result<WorkspaceDescription, WorkspaceClientFailure> {
        guard let workspace = message.workspace,
            let host = message.host,
            let phase = message.phase.flatMap(WorkspaceLifecycle.init(rawValue:)),
            let project = message.project,
            let attached = message.attached
        else {
            return .failure(.malformed)
        }
        return .success(
            WorkspaceDescription(
                host: WorkspaceHostID(rawValue: host),
                workspace: workspace,
                project: project,
                phase: phase,
                attached: attached
            )
        )
    }

    private func fileDescriptor() -> Int32? {
        state.withLock { current in
            current.open ? current.fd : nil
        }
    }

    private func finish() {
        let fd = state.withLock { current -> Int32 in
            let fd = current.fd
            current.open = false
            current.fd = -1
            return fd
        }
        if fd >= 0 { close(fd) }
    }
}

private func clientFailure(_ code: WorkspaceControlCode) -> WorkspaceClientFailure {
    switch code {
    case .workspaceClosing: .workspaceClosing
    case .workspaceClosed: .workspaceClosed
    case .runtimeNotFound: .runtimeNotFound
    case .invalidRequest: .invalidRequest
    case .incompatibleProtocol: .incompatibleProtocol
    case .unauthorizedClient: .unauthorizedClient
    case .recoveryRequired: .recoveryRequired
    case .childTeardownFailed: .childTeardownFailed
    }
}
#endif
