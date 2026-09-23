#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

private struct Reply {
    var message: WorkspaceControlMessage
    var endConnection = false
    var retire = false
    /// Runs after the reply frame is written, so streamed bytes cannot precede it.
    var afterSend: (() -> Void)?
}

private final class CloseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var signaled = false

    func signal() {
        condition.lock()
        signaled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while signaled == false {
            condition.wait()
        }
        condition.unlock()
    }
}

private final class WorkspaceControlConnection: @unchecked Sendable {
    let id = UUID()
    private let flags: Mutex<ConnectionFlags>
    /// Serializes frames. `flags` is not held across the write, so a slow
    /// client cannot stall accept, but two writers cannot interleave bytes.
    private let sendLock = NSLock()

    private struct ConnectionFlags {
        var fd: Int32
        var hello = false
        var closed = false
    }

    init(fd: Int32) {
        self.flags = Mutex(ConnectionFlags(fd: fd))
    }

    var isHello: Bool {
        flags.withLock { $0.hello }
    }

    func markHello() {
        flags.withLock { $0.hello = true }
    }

    func send(_ message: WorkspaceControlMessage) -> Bool {
        guard let body = WorkspaceControlCodec.encode(message) else { return false }
        let fd = flags.withLock { flags -> Int32 in
            guard flags.closed == false, flags.fd >= 0 else { return -1 }
            return Darwin.dup(flags.fd)
        }
        guard fd >= 0 else { return false }
        sendLock.lock()
        defer {
            sendLock.unlock()
            Darwin.close(fd)
        }
        return WorkspaceControlSocket.writeFrame(fd: fd, body: body)
    }

    func socketFD() -> Int32 {
        flags.withLock { flags in
            flags.closed ? -1 : flags.fd
        }
    }

    /// Unblock a read without releasing the descriptor. The serve thread closes it.
    func interrupt() {
        flags.withLock { flags in
            guard flags.closed == false, flags.fd >= 0 else { return }
            _ = Darwin.shutdown(flags.fd, SHUT_RDWR)
        }
    }

    /// Shutdown and close exactly once. A later caller observes `closed` and
    /// does not touch the descriptor after it can be reused.
    func closeSocket() {
        let fd = flags.withLock { flags -> Int32 in
            if flags.closed { return -1 }
            flags.closed = true
            let fd = flags.fd
            flags.fd = -1
            return fd
        }
        guard fd >= 0 else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// Control plane for one live workspace. It does not render a UI.
final class WorkspaceHostServer: @unchecked Sendable {
    let endpoint: WorkspaceEndpoint
    private let supervisor: WorkspaceSessionSupervisor
    private let hostID: WorkspaceHostID
    private let credential: WorkspaceOwnerCredential
    private let sessionStore: RuntimeSessionStore
    private let listenFD: Int32
    private let endpointFile: URL
    private let socketDirectory: String
    private let removeSocketDirectory: Bool
    private let registry = Mutex<Registry>(Registry())
    private let gate = CloseGate()

    private struct Registry {
        var connections: [UUID: WorkspaceControlConnection] = [:]
        var retired = false
    }

    private init(
        supervisor: WorkspaceSessionSupervisor,
        hostID: WorkspaceHostID,
        credential: WorkspaceOwnerCredential,
        endpoint: WorkspaceEndpoint,
        sessionStore: RuntimeSessionStore,
        listenFD: Int32,
        endpointFile: URL,
        socketDirectory: String,
        removeSocketDirectory: Bool
    ) {
        self.supervisor = supervisor
        self.hostID = hostID
        self.credential = credential
        self.endpoint = endpoint
        self.sessionStore = sessionStore
        self.listenFD = listenFD
        self.endpointFile = endpointFile
        self.socketDirectory = socketDirectory
        self.removeSocketDirectory = removeSocketDirectory
    }

    static func start(
        supervisor: WorkspaceSessionSupervisor,
        configurationDirectory: URL,
        sessionStore: RuntimeSessionStore
    ) -> Result<WorkspaceHostServer, WorkspaceHostFailure> {
        guard let credential = supervisor.ownerCredential() else {
            return .failure(.endpointUnavailable)
        }
        let canonical = supervisor.snapshot.originalPath.rawValue
        let endpointFile = WorkspaceHostLocation.endpointFile(
            in: configurationDirectory,
            canonicalPath: canonical
        )
        WorkspaceEndpointStore.retireStale(at: endpointFile)
        let prepared: (path: String, directory: String, removeDirectory: Bool)
        switch WorkspaceEndpointStore.prepareSocket(
            configurationDirectory: configurationDirectory,
            canonicalPath: canonical
        ) {
        case .failure:
            return .failure(.endpointUnavailable)
        case .success(let value):
            prepared = value
        }
        let listened: (Int32, WorkspaceSocketIdentity)
        switch WorkspaceControlSocket.openListener(path: prepared.path) {
        case .failure:
            if prepared.removeDirectory {
                _ = prepared.directory.withCString { rmdir($0) }
            }
            return .failure(.endpointUnavailable)
        case .success(let value):
            listened = value
        }
        let hostID = WorkspaceHostID()
        let record = WorkspaceEndpointRecord(
            v: WorkspaceControlLimits.version,
            host: hostID.rawValue,
            workspace: supervisor.id.rawValue,
            canonicalPath: canonical,
            socketPath: prepared.path,
            socketDevice: listened.1.device,
            socketInode: listened.1.inode,
            ownerToken: credential.token,
            lockPath: credential.lockPath,
            lockDevice: credential.lockDevice,
            lockInode: credential.lockInode,
            uid: UInt32(getuid())
        )
        let wrote = WorkspaceEndpointStore.write(record, to: endpointFile)
        let recorded = wrote && supervisor.recordHostStarted(hostID.rawValue)
        guard recorded else {
            Darwin.close(listened.0)
            _ = WorkspaceControlSocket.unlinkOwnedSocket(prepared.path)
            if prepared.removeDirectory {
                _ = prepared.directory.withCString { rmdir($0) }
            }
            _ = endpointFile.path.withCString { unlink($0) }
            return .failure(.endpointUnavailable)
        }
        let server = WorkspaceHostServer(
            supervisor: supervisor,
            hostID: hostID,
            credential: credential,
            endpoint: record.endpoint(),
            sessionStore: sessionStore,
            listenFD: listened.0,
            endpointFile: endpointFile,
            socketDirectory: prepared.directory,
            removeSocketDirectory: prepared.removeDirectory
        )
        server.startAccepting()
        return .success(server)
    }

    func waitForClose() {
        gate.wait()
    }

    /// Drops the control endpoint. Does not close the workspace.
    func stop() {
        retire(excluding: nil, notify: false)
    }

    private func startAccepting() {
        let server = self
        let thread = Thread {
            server.acceptLoop()
        }
        thread.name = "rv-workspace-accept"
        thread.start()
    }

    private func acceptLoop() {
        while registry.withLock({ $0.retired }) == false {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                let error = errno
                switch WorkspaceAcceptLoop.action(
                    for: error,
                    retired: registry.withLock { $0.retired }
                ) {
                case .stop:
                    return
                case .retryImmediately:
                    continue
                case .retryAfterPause:
                    usleep(50_000)
                    continue
                }
            }
            if registry.withLock({ $0.retired }) {
                Darwin.close(client)
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &one,
                socklen_t(MemoryLayout<Int32>.size)
            )
            adopt(client)
        }
    }

    private func adopt(_ fd: Int32) {
        guard let uid = WorkspaceControlSocket.peerUID(fd),
            WorkspacePeerPolicy.decide(peerUID: uid, ownerUID: getuid()) == nil
        else {
            let refusal = WorkspaceControlMessage.error(
                id: nil,
                op: WorkspaceControlOp.hello.rawValue,
                code: .unauthorizedClient
            )
            if let body = WorkspaceControlCodec.encode(refusal) {
                _ = WorkspaceControlSocket.writeFrame(fd: fd, body: body)
            }
            Darwin.close(fd)
            return
        }
        let connection = WorkspaceControlConnection(fd: fd)
        let stored = registry.withLock { state -> Bool in
            guard state.retired == false,
                state.connections.count < WorkspaceControlLimits.maxConnections
            else {
                return false
            }
            state.connections[connection.id] = connection
            return true
        }
        guard stored else {
            connection.closeSocket()
            return
        }
        let server = self
        let thread = Thread {
            server.serve(connection)
        }
        thread.name = "rv-workspace-client"
        thread.start()
    }

    private func serve(_ connection: WorkspaceControlConnection) {
        defer {
            supervisor.detachTerminalClient(connection.id)
            registry.withLock { $0.connections[connection.id] = nil }
            connection.closeSocket()
        }
        while registry.withLock({ $0.retired }) == false {
            let fd = connection.socketFD()
            if fd < 0 { return }
            switch WorkspaceControlSocket.readFrame(fd: fd, timeout: nil) {
            case .failure:
                return
            case .success(let body):
                let reply = respond(body, connection: connection)
                let sent = connection.send(reply.message)
                if sent {
                    reply.afterSend?()
                } else if reply.afterSend != nil {
                    supervisor.detachTerminalClient(connection.id)
                }
                if reply.retire {
                    retire(excluding: connection.id, notify: true)
                }
                if reply.endConnection || reply.retire {
                    return
                }
            }
        }
    }

    private func respond(_ body: Data, connection: WorkspaceControlConnection) -> Reply {
        switch WorkspaceControlCodec.decode(body) {
        case .incompatible:
            return Reply(
                message: WorkspaceControlMessage.error(
                    id: nil,
                    op: WorkspaceControlOp.hello.rawValue,
                    code: .incompatibleProtocol
                ),
                endConnection: true
            )
        case .invalid:
            return Reply(
                message: WorkspaceControlMessage.error(
                    id: nil,
                    op: WorkspaceControlOp.ping.rawValue,
                    code: .invalidRequest
                )
            )
        case .message(let message):
            guard message.id != nil else {
                return Reply(
                    message: WorkspaceControlMessage.error(
                        id: nil,
                        op: message.op,
                        code: .invalidRequest
                    )
                )
            }
            if connection.isHello == false {
                return hello(message, connection: connection)
            }
            return operation(message, connection: connection)
        }
    }

    private func hello(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard message.op == WorkspaceControlOp.hello.rawValue,
            message.token == credential.token
        else {
            return Reply(
                message: WorkspaceControlMessage.error(
                    id: message.id,
                    op: WorkspaceControlOp.hello.rawValue,
                    code: .unauthorizedClient
                ),
                endConnection: true
            )
        }
        connection.markHello()
        return Reply(
            message: WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                id: message.id,
                op: WorkspaceControlOp.hello.rawValue,
                ok: true,
                workspace: supervisor.id.rawValue,
                host: hostID.rawValue
            )
        )
    }

    private func operation(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard let op = WorkspaceControlOp(rawValue: message.op) else {
            return Reply(message: failure(message, .invalidRequest))
        }
        switch op {
        case .hello:
            return Reply(message: failure(message, .invalidRequest))
        case .ping:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: op.rawValue,
                    ok: true,
                    host: hostID.rawValue
                )
            )
        case .describeWorkspace:
            return Reply(message: describe(message))
        case .listRuntimes:
            return Reply(message: list(message))
        case .launchRuntime:
            return Reply(message: launch(message))
        case .cancelRuntime:
            return Reply(message: cancel(message))
        case .closeWorkspace:
            return close(message)
        case .detach:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: op.rawValue,
                    ok: true
                ),
                endConnection: true
            )
        case .workspaceClosed, .terminalReplay, .terminalOutput, .terminalInputOwner,
            .runtimeExited, .terminalOverflow:
            return Reply(message: failure(message, .invalidRequest))
        case .subscribeTerminal:
            return subscribe(message, connection: connection)
        case .unsubscribeTerminal:
            return unsubscribe(message, connection: connection)
        case .terminalInput:
            return input(message, connection: connection)
        case .acquireTerminalInput:
            return acquire(message, connection: connection)
        case .releaseTerminalInput:
            return release(message, connection: connection)
        case .resizeTerminal:
            return resize(message)
        }
    }

    private func describe(_ message: WorkspaceControlMessage) -> WorkspaceControlMessage {
        let snapshot = supervisor.snapshot
        guard snapshot.originalPath.rawValue.utf8.count <= WorkspaceControlLimits.maxProjectBytes else {
            return failure(message, .invalidRequest)
        }
        let attached = registry.withLock { state in
            state.connections.values.filter(\.isHello).count
        }
        return WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: message.id,
            op: WorkspaceControlOp.describeWorkspace.rawValue,
            ok: true,
            workspace: snapshot.id.rawValue,
            host: hostID.rawValue,
            phase: snapshot.phase.rawValue,
            project: snapshot.originalPath.rawValue,
            attached: attached
        )
    }

    private func list(_ message: WorkspaceControlMessage) -> WorkspaceControlMessage {
        supervisor.pruneFinishedRuntimes(limit: WorkspaceControlLimits.maxRuntimes)
        let facts = supervisor.runtimeFacts()
        guard facts.count <= WorkspaceControlLimits.maxRuntimes else {
            return failure(message, .runtimeLimit)
        }
        return WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: message.id,
            op: WorkspaceControlOp.listRuntimes.rawValue,
            ok: true,
            runtimes: facts.map {
                WorkspaceRuntimeReport(
                    runtime: $0.id,
                    hook: $0.hookHost,
                    running: $0.running,
                    terminal: $0.terminal,
                    rows: $0.rows,
                    columns: $0.columns,
                    inputOwner: $0.inputOwner
                )
            }
        )
    }

    private func launch(_ message: WorkspaceControlMessage) -> WorkspaceControlMessage {
        let phase = supervisor.snapshot.phase
        guard phase.acceptsRuntime else {
            return failure(message, workspaceControlCode(.notAcceptingRuntime(phase)))
        }
        guard let executable = message.executable, executable.hasPrefix("/") else {
            return failure(message, .invalidRequest)
        }
        let hook: HookHost?
        if let raw = message.hook {
            guard let parsed = HookHost(rawValue: raw) else {
                return failure(message, .invalidRequest)
            }
            hook = parsed
        } else {
            hook = nil
        }
        guard let command = IsolatedCommand(
            executable: executable,
            arguments: message.arguments ?? []
        ) else {
            return failure(message, .invalidRequest)
        }
        let io: IsolatedIO
        switch launchIO(message) {
        case .failure(let code):
            return failure(message, code)
        case .success(let parsed):
            io = parsed
        }
        let plan = compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace)
        switch supervisor.launch(
            host: hook,
            command: command,
            plan: plan,
            io: io,
            admission: .failClosed,
            sessionStore: sessionStore,
            runningLimit: WorkspaceControlLimits.maxRuntimes
        ) {
        case .failure(let error):
            return failure(message, workspaceControlCode(error))
        case .success(let running):
            let fact = supervisor.runtimeFacts().first { $0.id == running.id.rawValue }
            supervisor.pruneFinishedRuntimes(limit: WorkspaceControlLimits.maxRuntimes)
            let launchedTerminal: Bool
            let launchedRows: Int?
            let launchedColumns: Int?
            if case .pseudoTerminal(let rows, let columns) = io {
                launchedTerminal = true
                launchedRows = rows
                launchedColumns = columns
            } else {
                launchedTerminal = false
                launchedRows = nil
                launchedColumns = nil
            }
            return WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                id: message.id,
                op: WorkspaceControlOp.launchRuntime.rawValue,
                runtime: running.id.rawValue,
                hook: running.session.host?.rawValue,
                ok: true,
                running: fact?.running ?? true,
                rows: fact?.rows ?? launchedRows,
                columns: fact?.columns ?? launchedColumns,
                terminal: (fact?.terminal ?? false) || launchedTerminal,
                inputOwner: fact?.inputOwner ?? false
            )
        }
    }

    private func launchIO(
        _ message: WorkspaceControlMessage
    ) -> Result<IsolatedIO, WorkspaceControlCode> {
        workspaceLaunchIO(io: message.io, rows: message.rows, columns: message.columns)
    }

    private func subscribe(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard let runtime = message.runtime else {
            return Reply(message: failure(message, .invalidRequest))
        }
        let client = connection.id
        switch supervisor.subscribeTerminal(runtime: runtime, client: client, emit: { notice in
            connection.send(workspaceTerminalMessage(notice, runtime: runtime))
        }) {
        case .failure(let code):
            return Reply(message: failure(message, code))
        case .success:
            let window = supervisor.terminalWindow(runtime: runtime)
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: WorkspaceControlOp.subscribeTerminal.rawValue,
                    runtime: runtime,
                    ok: true,
                    rows: window?.rows,
                    columns: window?.columns,
                    terminal: true
                ),
                afterSend: { [supervisor] in
                    supervisor.activateTerminal(runtime: runtime, client: client)
                }
            )
        }
    }

    private func unsubscribe(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard let runtime = message.runtime else {
            return Reply(message: failure(message, .invalidRequest))
        }
        switch supervisor.unsubscribeTerminal(runtime: runtime, client: connection.id) {
        case .failure(let code):
            return Reply(message: failure(message, code))
        case .success:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: WorkspaceControlOp.unsubscribeTerminal.rawValue,
                    runtime: runtime,
                    ok: true
                )
            )
        }
    }

    private func input(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard let runtime = message.runtime, let encoded = message.bytes,
            let data = TerminalBytesCodec.decode(encoded, maximum: TerminalStreamLimits.maximumInputBytes),
            data.isEmpty == false
        else {
            return Reply(message: failure(message, .invalidRequest))
        }
        switch supervisor.writeTerminal(runtime: runtime, client: connection.id, bytes: data) {
        case .failure(let code):
            return Reply(message: failure(message, code))
        case .success:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: WorkspaceControlOp.terminalInput.rawValue,
                    runtime: runtime,
                    ok: true
                )
            )
        }
    }

    private func acquire(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard let runtime = message.runtime else {
            return Reply(message: failure(message, .invalidRequest))
        }
        switch supervisor.acquireTerminalInput(runtime: runtime, client: connection.id) {
        case .failure(let code):
            return Reply(message: failure(message, code))
        case .success:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: WorkspaceControlOp.acquireTerminalInput.rawValue,
                    runtime: runtime,
                    ok: true,
                    inputOwner: true
                )
            )
        }
    }

    private func release(
        _ message: WorkspaceControlMessage,
        connection: WorkspaceControlConnection
    ) -> Reply {
        guard let runtime = message.runtime else {
            return Reply(message: failure(message, .invalidRequest))
        }
        switch supervisor.releaseTerminalInput(runtime: runtime, client: connection.id) {
        case .failure(let code):
            return Reply(message: failure(message, code))
        case .success:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: WorkspaceControlOp.releaseTerminalInput.rawValue,
                    runtime: runtime,
                    ok: true,
                    inputOwner: false
                )
            )
        }
    }

    private func resize(_ message: WorkspaceControlMessage) -> Reply {
        guard let runtime = message.runtime, let rows = message.rows, let columns = message.columns else {
            return Reply(message: failure(message, .invalidRequest))
        }
        switch supervisor.resizeTerminal(runtime: runtime, rows: rows, columns: columns) {
        case .failure(let code):
            return Reply(message: failure(message, code))
        case .success:
            return Reply(
                message: WorkspaceControlMessage(
                    version: WorkspaceControlLimits.version,
                    id: message.id,
                    op: WorkspaceControlOp.resizeTerminal.rawValue,
                    runtime: runtime,
                    ok: true,
                    rows: rows,
                    columns: columns
                )
            )
        }
    }

    private func cancel(_ message: WorkspaceControlMessage) -> WorkspaceControlMessage {
        guard let runtime = message.runtime else {
            return failure(message, .invalidRequest)
        }
        switch supervisor.cancel(runtime: runtime) {
        case .success:
            return WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                id: message.id,
                op: WorkspaceControlOp.cancelRuntime.rawValue,
                runtime: runtime,
                ok: true
            )
        case .failure(let error):
            return failure(message, workspaceControlCode(error))
        }
    }

    private func close(_ message: WorkspaceControlMessage) -> Reply {
        let result = supervisor.close()
        let closed = supervisor.snapshot.phase == .closed
        let response: WorkspaceControlMessage
        switch result {
        case .success where closed:
            response = WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                id: message.id,
                op: WorkspaceControlOp.closeWorkspace.rawValue,
                ok: true,
                workspace: supervisor.id.rawValue,
                host: hostID.rawValue,
                phase: WorkspaceLifecycle.closed.rawValue,
                project: supervisor.snapshot.originalPath.rawValue,
                attached: 0
            )
        case .failure(let error):
            response = failure(message, workspaceControlCode(error))
        case .success:
            response = failure(message, .workspaceClosed)
        }
        return Reply(message: response, retire: closed)
    }

    private func failure(
        _ message: WorkspaceControlMessage,
        _ code: WorkspaceControlCode
    ) -> WorkspaceControlMessage {
        WorkspaceControlMessage.error(id: message.id, op: message.op, code: code)
    }

    private func retire(excluding: UUID?, notify: Bool) {
        let snapshot: (first: Bool, others: [WorkspaceControlConnection]) = registry.withLock { state in
            if state.retired { return (false, []) }
            state.retired = true
            let others = state.connections.values.filter { $0.id != excluding }
            return (true, Array(others))
        }
        guard snapshot.first else { return }
        // Stop accept before client descriptors are closed so a new connection
        // cannot reuse a number this host still reads.
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        if notify {
            let event = WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                op: WorkspaceControlOp.workspaceClosed.rawValue,
                ok: true,
                workspace: supervisor.id.rawValue,
                host: hostID.rawValue,
                phase: WorkspaceLifecycle.closed.rawValue,
                project: supervisor.snapshot.originalPath.rawValue,
                attached: 0
            )
            for connection in snapshot.others {
                _ = connection.send(event)
            }
        }
        for connection in snapshot.others {
            connection.interrupt()
        }
        if let current = registry.withLock({ state in
            state.connections.values.first { $0.id == excluding }
        }) {
            current.interrupt()
        }
        _ = WorkspaceControlSocket.unlinkOwnedSocket(endpoint.socketPath)
        if removeSocketDirectory {
            _ = socketDirectory.withCString { rmdir($0) }
        }
        _ = endpointFile.path.withCString { unlink($0) }
        gate.signal()
    }

    /// Pushes a terminal frame the client must reject. The stream fails closed
    /// and the runtime is left running. Tests use this for the protocol-error
    /// raw-mode path; it is not a client operation.
    func testingInjectMalformedTerminalFrame() -> Bool {
        let message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalOutput.rawValue,
            runtime: UUID(),
            ok: true
        )
        let connections = registry.withLock { Array($0.connections.values) }
        guard connections.isEmpty == false else { return false }
        return connections.contains { $0.send(message) }
    }
}

private func workspaceTerminalMessage(
    _ notice: TerminalNotice,
    runtime: UUID
) -> WorkspaceControlMessage {
    switch notice {
    case .replay(let sequence, let bytes):
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalReplay.rawValue,
            runtime: runtime,
            ok: true,
            sequence: sequence,
            bytes: TerminalBytesCodec.encode(bytes)
        )
    case .output(let sequence, let bytes):
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalOutput.rawValue,
            runtime: runtime,
            ok: true,
            sequence: sequence,
            bytes: TerminalBytesCodec.encode(bytes)
        )
    case .inputOwner(let owned):
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalInputOwner.rawValue,
            runtime: runtime,
            ok: true,
            inputOwner: owned
        )
    case .exited(let status):
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.runtimeExited.rawValue,
            runtime: runtime,
            ok: true,
            running: false,
            exitStatus: status
        )
    case .overflow:
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalOverflow.rawValue,
            runtime: runtime,
            ok: true
        )
    }
}
#endif
