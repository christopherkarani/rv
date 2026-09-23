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
    case runtimeLimit
    case staleEndpoint
    case terminalUnavailable
    case terminalBusy
    case terminalLimit
}

/// One host-owned terminal event. `bytes` are raw PTY output, not text.
public struct WorkspaceTerminalEvent: Sendable, Equatable {
    public var runtime: UUID
    public var body: Body

    public enum Body: Sendable, Equatable {
        case replay(sequence: Int64, bytes: Data)
        case output(sequence: Int64, bytes: Data)
        case inputOwner(Bool)
        case exited(Int32)
        case overflow
    }
}

public enum WorkspaceTerminalRead: Sendable, Equatable {
    case event(WorkspaceTerminalEvent)
    /// The wait expired. The connection stays open.
    case waiting
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
    /// Serializes every read, write, and close on `fd` before a terminal
    /// subscription. After that, the event reader is the only reader.
    private let io: Mutex<ClientState>
    private let writeLock = NSLock()
    private let events = EventBoard()

    private struct ClientState {
        var fd: Int32
        var open: Bool
    }

    private init(fd: Int32, endpoint: WorkspaceEndpoint) {
        self.endpoint = endpoint
        self.io = Mutex(ClientState(fd: fd, open: true))
    }

    deinit {
        io.withLock { closeLocked(&$0) }
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
        hookHost: HookHost? = nil,
        terminalRows: Int? = nil,
        terminalColumns: Int? = nil
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.launchRuntime.rawValue,
            executable: executable,
            arguments: arguments,
            hook: hookHost?.rawValue
        )
        switch (terminalRows, terminalColumns) {
        case (nil, nil):
            break
        case let (rows?, columns?) where TerminalStreamLimits.accepts(rows: rows, columns: columns):
            message.io = "terminal"
            message.rows = rows
            message.columns = columns
        default:
            return .failure(.invalidRequest)
        }
        switch transact(&message, timeout: WorkspaceControlLimits.launchTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard let runtime = reply.runtime, let running = reply.running else {
                return .failure(.malformed)
            }
            return .success(
                WorkspaceRuntimeReport(
                    runtime: runtime,
                    hook: reply.hook,
                    running: running,
                    terminal: reply.terminal ?? false,
                    rows: reply.rows,
                    columns: reply.columns,
                    inputOwner: reply.inputOwner ?? false
                )
            )
        }
    }

    public func subscribeTerminal(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.subscribeTerminal.rawValue,
            runtime: runtime
        )
        let result = transact(
            &message,
            timeout: WorkspaceControlLimits.launchTimeoutSeconds,
            beginStreaming: true
        )
        if case .success = result {
            startEventReader()
        }
        return result.map { _ in () }
    }

    public func unsubscribeTerminal(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.unsubscribeTerminal.rawValue,
            runtime: runtime
        )
        return transact(&message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func acquireTerminalInput(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.acquireTerminalInput.rawValue,
            runtime: runtime
        )
        return transact(&message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func releaseTerminalInput(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.releaseTerminalInput.rawValue,
            runtime: runtime
        )
        return transact(&message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func writeTerminal(_ runtime: UUID, bytes: Data) -> Result<Void, WorkspaceClientFailure> {
        guard bytes.isEmpty == false, bytes.count <= TerminalStreamLimits.maximumInputBytes else {
            return .failure(.invalidRequest)
        }
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.terminalInput.rawValue,
            runtime: runtime,
            bytes: TerminalBytesCodec.encode(bytes)
        )
        return transact(&message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func resizeTerminal(
        _ runtime: UUID,
        rows: Int,
        columns: Int
    ) -> Result<Void, WorkspaceClientFailure> {
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else {
            return .failure(.invalidRequest)
        }
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.resizeTerminal.rawValue,
            runtime: runtime,
            rows: rows,
            columns: columns
        )
        return transact(&message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func nextTerminalEvent(
        timeout: TimeInterval
    ) -> Result<WorkspaceTerminalRead, WorkspaceClientFailure> {
        events.next(timeout: timeout).flatMap { message in
            guard let message else { return .success(.waiting) }
            if message.op == WorkspaceControlOp.workspaceClosed.rawValue {
                return .failure(.workspaceClosed)
            }
            guard let event = workspaceTerminalEvent(message) else {
                return .failure(.malformed)
            }
            return .success(.event(event))
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
        if events.isStreaming { return .failure(.invalidRequest) }
        return io.withLock { state in
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remain = deadline.timeIntervalSinceNow
                if remain <= 0 {
                    closeLocked(&state)
                    return .failure(.timedOut)
                }
                switch readFrame(state: &state, timeout: remain) {
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
        timeout: TimeInterval,
        beginStreaming: Bool = false
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        if events.isStreaming {
            return streamingTransact(&message, timeout: timeout)
        }
        guard let rpc = rpcTransact(&message, timeout: timeout, beginStreaming: beginStreaming) else {
            return streamingTransact(&message, timeout: timeout)
        }
        return rpc
    }

    /// Nil means a terminal reader owns the socket and the caller must retry
    /// on the streaming path. The request was not written.
    private func rpcTransact(
        _ message: inout WorkspaceControlMessage,
        timeout: TimeInterval,
        beginStreaming: Bool
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure>? {
        guard let body = WorkspaceControlCodec.encode(message) else { return .failure(.malformed) }
        let requestID = message.id
        return io.withLock { state in
            if events.isStreaming { return nil }
            guard state.open, state.fd >= 0 else { return .failure(.disconnected) }
            guard WorkspaceControlSocket.writeFrame(fd: state.fd, body: body) else {
                closeLocked(&state)
                return .failure(.disconnected)
            }
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remain = deadline.timeIntervalSinceNow
                if remain <= 0 {
                    closeLocked(&state)
                    return .failure(.timedOut)
                }
                switch readFrame(state: &state, timeout: remain) {
                case .failure(let error):
                    return .failure(error)
                case .success(let reply):
                    if reply.op == WorkspaceControlOp.workspaceClosed.rawValue,
                        reply.id != requestID
                    {
                        closeLocked(&state)
                        return .failure(.workspaceClosed)
                    }
                    guard reply.id == requestID else {
                        closeLocked(&state)
                        return .failure(.malformed)
                    }
                    let interpreted = interpret(reply)
                    if beginStreaming, case .success = interpreted {
                        events.armStreaming()
                    }
                    return interpreted
                }
            }
        }
    }

    private func streamingTransact(
        _ message: inout WorkspaceControlMessage,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        guard let body = WorkspaceControlCodec.encode(message), let requestID = message.id else {
            return .failure(.malformed)
        }
        let waiter = ReplyWaiter()
        if events.register(requestID, waiter: waiter) == false {
            return .failure(events.failure ?? .disconnected)
        }
        let fd = io.withLock { $0.open ? $0.fd : -1 }
        guard fd >= 0 else {
            events.fail(requestID, .disconnected)
            return .failure(.disconnected)
        }
        writeLock.lock()
        let wrote = WorkspaceControlSocket.writeFrame(fd: fd, body: body)
        writeLock.unlock()
        guard wrote else {
            failStream(.disconnected)
            return .failure(.disconnected)
        }
        let result = waiter.wait(timeout: timeout)
        if case .failure(.timedOut) = result {
            events.fail(requestID, .timedOut)
            failStream(.timedOut)
        }
        return result
    }

    private func startEventReader() {
        guard events.claimReader() else { return }
        let thread = Thread { [self] in
            self.readEvents()
        }
        thread.name = "rv-workspace-terminal"
        thread.start()
    }

    private func readEvents() {
        while true {
            let fd = io.withLock { state -> Int32 in
                state.open ? state.fd : -1
            }
            if fd < 0 {
                failStream(.disconnected)
                return
            }
            switch WorkspaceControlSocket.readFrame(fd: fd, timeout: nil) {
            case .failure:
                failStream(.disconnected)
                return
            case .success(let data):
                switch WorkspaceControlCodec.decode(data) {
                case .incompatible:
                    failStream(.incompatibleProtocol)
                    return
                case .invalid:
                    failStream(.malformed)
                    return
                case .message(let message):
                    if events.deliver(message) == false {
                        failStream(.malformed)
                        return
                    }
                    if message.op == WorkspaceControlOp.workspaceClosed.rawValue {
                        failStream(.workspaceClosed)
                        return
                    }
                }
            }
        }
    }

    private func failStream(_ error: WorkspaceClientFailure) {
        writeLock.lock()
        io.withLock { closeLocked(&$0) }
        writeLock.unlock()
        events.failAll(error)
    }

    /// Caller holds `io`. A broken frame closes the socket so the next call
    /// cannot pair a later reply with an earlier request.
    private func readFrame(
        state: inout ClientState,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        guard state.open, state.fd >= 0 else { return .failure(.disconnected) }
        switch WorkspaceControlSocket.readFrame(fd: state.fd, timeout: timeout) {
        case .failure(.timedOut):
            closeLocked(&state)
            return .failure(.timedOut)
        case .failure:
            closeLocked(&state)
            return .failure(.disconnected)
        case .success(let data):
            switch WorkspaceControlCodec.decode(data) {
            case .incompatible:
                closeLocked(&state)
                return .failure(.incompatibleProtocol)
            case .invalid:
                closeLocked(&state)
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

    private func finish() {
        io.withLock { closeLocked(&$0) }
    }

    /// Caller holds `io`.
    private func closeLocked(_ state: inout ClientState) {
        let fd = state.fd
        state.open = false
        state.fd = -1
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
    case .runtimeLimit: .runtimeLimit
    case .terminalUnavailable: .terminalUnavailable
    case .terminalBusy: .terminalBusy
    case .terminalLimit: .terminalLimit
}
}

private final class ReplyWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var message: WorkspaceControlMessage?
    private var failure: WorkspaceClientFailure?

    func succeed(_ message: WorkspaceControlMessage) {
        condition.lock()
        self.message = message
        condition.signal()
        condition.unlock()
    }

    func fail(_ error: WorkspaceClientFailure) {
        condition.lock()
        if message == nil, failure == nil { failure = error }
        condition.signal()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Result<WorkspaceControlMessage, WorkspaceClientFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while message == nil, failure == nil {
            if condition.wait(until: deadline) == false, message == nil, failure == nil {
                condition.unlock()
                return .failure(.timedOut)
            }
        }
        let result: Result<WorkspaceControlMessage, WorkspaceClientFailure>
        if let message {
            result = message.ok == false
                ? .failure(message.error.flatMap(WorkspaceControlCode.init(rawValue:)).map(clientFailure) ?? .malformed)
                : .success(message)
        } else {
            result = .failure(failure ?? .disconnected)
        }
        condition.unlock()
        return result
    }
}

private final class EventBoard: @unchecked Sendable {
    private let condition = NSCondition()
    private var streaming = false
    private var readerClaimed = false
    private var failed: WorkspaceClientFailure?
    private var waiters: [UUID: ReplyWaiter] = [:]
    private var messages: [WorkspaceControlMessage] = []
    private var queuedBytes = 0

    var isStreaming: Bool {
        condition.lock()
        let value = streaming
        condition.unlock()
        return value
    }

    var failure: WorkspaceClientFailure? {
        condition.lock()
        let value = failed
        condition.unlock()
        return value
    }

    func armStreaming() {
        condition.lock()
        streaming = true
        condition.unlock()
    }

    func claimReader() -> Bool {
        condition.lock()
        if readerClaimed {
            condition.unlock()
            return false
        }
        readerClaimed = true
        condition.unlock()
        return true
    }

    func register(_ id: UUID, waiter: ReplyWaiter) -> Bool {
        condition.lock()
        if streaming == false || failed != nil {
            condition.unlock()
            return false
        }
        waiters[id] = waiter
        condition.unlock()
        return true
    }

    func fail(_ id: UUID, _ error: WorkspaceClientFailure) {
        condition.lock()
        let waiter = waiters.removeValue(forKey: id)
        condition.unlock()
        waiter?.fail(error)
    }

    /// False when the frame is neither a matching reply nor a terminal event.
    func deliver(_ message: WorkspaceControlMessage) -> Bool {
        condition.lock()
        if let id = message.id, let waiter = waiters.removeValue(forKey: id) {
            condition.unlock()
            waiter.succeed(message)
            return true
        }
        guard workspaceTerminalEvent(message) != nil
            || message.op == WorkspaceControlOp.workspaceClosed.rawValue
        else {
            condition.unlock()
            return false
        }
        let weight = message.bytes?.utf8.count ?? 1
        let (sum, overflowed) = queuedBytes.addingReportingOverflow(weight)
        if overflowed || sum > TerminalStreamLimits.subscriberQueueBytes {
            failed = .terminalLimit
            condition.broadcast()
            condition.unlock()
            return true
        }
        messages.append(message)
        queuedBytes = sum
        condition.broadcast()
        condition.unlock()
        return true
    }

    func failAll(_ error: WorkspaceClientFailure) {
        condition.lock()
        if failed == nil { failed = error }
        let pending = waiters
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for waiter in pending.values {
            waiter.fail(error)
        }
    }

    func next(timeout: TimeInterval) -> Result<WorkspaceControlMessage?, WorkspaceClientFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while messages.isEmpty, failed == nil {
            if condition.wait(until: deadline) == false, messages.isEmpty, failed == nil {
                condition.unlock()
                return .success(nil)
            }
        }
        if messages.isEmpty, let failed {
            condition.unlock()
            return .failure(failed)
        }
        let message = messages.removeFirst()
        queuedBytes = max(0, queuedBytes - (message.bytes?.utf8.count ?? 1))
        condition.unlock()
        return .success(message)
    }
}

private func workspaceTerminalEvent(_ message: WorkspaceControlMessage) -> WorkspaceTerminalEvent? {
    guard let runtime = message.runtime else { return nil }
    switch message.op {
    case WorkspaceControlOp.terminalReplay.rawValue:
        guard let sequence = message.sequence, let bytes = message.bytes,
            let data = TerminalBytesCodec.decode(bytes, maximum: TerminalStreamLimits.readChunkBytes)
        else { return nil }
        return WorkspaceTerminalEvent(runtime: runtime, body: .replay(sequence: sequence, bytes: data))
    case WorkspaceControlOp.terminalOutput.rawValue:
        guard let sequence = message.sequence, let bytes = message.bytes,
            let data = TerminalBytesCodec.decode(bytes, maximum: TerminalStreamLimits.readChunkBytes)
        else { return nil }
        return WorkspaceTerminalEvent(runtime: runtime, body: .output(sequence: sequence, bytes: data))
    case WorkspaceControlOp.terminalInputOwner.rawValue:
        guard let owned = message.inputOwner else { return nil }
        return WorkspaceTerminalEvent(runtime: runtime, body: .inputOwner(owned))
    case WorkspaceControlOp.runtimeExited.rawValue:
        guard let status = message.exitStatus else { return nil }
        return WorkspaceTerminalEvent(runtime: runtime, body: .exited(status))
    case WorkspaceControlOp.terminalOverflow.rawValue:
        return WorkspaceTerminalEvent(runtime: runtime, body: .overflow)
    default:
        return nil
    }
}
#endif
