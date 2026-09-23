#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

private struct Reply {
    var message: WorkspaceControlMessage
    var endConnection = false
    var retire = false
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
    let fd: Int32
    private let writeLock = Mutex(0)
    private let flags = Mutex(ConnectionFlags())

    private struct ConnectionFlags {
        var hello = false
        var closed = false
    }

    init(fd: Int32) {
        self.fd = fd
    }

    var isHello: Bool {
        flags.withLock { $0.hello }
    }

    func markHello() {
        flags.withLock { $0.hello = true }
    }

    func send(_ message: WorkspaceControlMessage) -> Bool {
        guard let body = WorkspaceControlCodec.encode(message) else { return false }
        return writeLock.withLock { _ in
            let closed = flags.withLock { $0.closed }
            guard closed == false else { return false }
            return WorkspaceControlSocket.writeFrame(fd: fd, body: body)
        }
    }

    func shutdown() {
        flags.withLock { $0.closed = true }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
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
    private let connections = Mutex<[UUID: WorkspaceControlConnection]>([:])
    private let retired = Mutex(false)
    private let gate = CloseGate()

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
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
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
        let allowed = connections.withLock { $0.count < WorkspaceControlLimits.maxConnections }
        guard allowed else {
            Darwin.close(fd)
            return
        }
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
        connections.withLock { $0[connection.id] = connection }
        let server = self
        let thread = Thread {
            server.serve(connection)
        }
        thread.name = "rv-workspace-client"
        thread.start()
    }

    private func serve(_ connection: WorkspaceControlConnection) {
        defer {
            connections.withLock { $0[connection.id] = nil }
            connection.shutdown()
            Darwin.close(connection.fd)
        }
        while retired.withLock({ $0 }) == false {
            switch WorkspaceControlSocket.readFrame(fd: connection.fd, timeout: nil) {
            case .failure:
                return
            case .success(let body):
                let reply = respond(body, connection: connection)
                _ = connection.send(reply.message)
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
            return operation(message)
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

    private func operation(_ message: WorkspaceControlMessage) -> Reply {
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
        case .workspaceClosed:
            return Reply(message: failure(message, .invalidRequest))
        }
    }

    private func describe(_ message: WorkspaceControlMessage) -> WorkspaceControlMessage {
        let snapshot = supervisor.snapshot
        guard snapshot.originalPath.rawValue.utf8.count <= WorkspaceControlLimits.maxProjectBytes else {
            return failure(message, .invalidRequest)
        }
        let attached = connections.withLock { list in
            list.values.filter(\.isHello).count
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
        let facts = supervisor.runtimeFacts()
        guard facts.count <= WorkspaceControlLimits.maxRuntimes else {
            return failure(message, .invalidRequest)
        }
        return WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: message.id,
            op: WorkspaceControlOp.listRuntimes.rawValue,
            ok: true,
            runtimes: facts.map {
                WorkspaceRuntimeReport(runtime: $0.id, hook: $0.hookHost, running: $0.running)
            }
        )
    }

    private func launch(_ message: WorkspaceControlMessage) -> WorkspaceControlMessage {
        let phase = supervisor.snapshot.phase
        guard phase.acceptsRuntime else {
            return failure(message, workspaceControlCode(.notAcceptingRuntime(phase)))
        }
        guard supervisor.runtimeFacts().count < WorkspaceControlLimits.maxRuntimes else {
            return failure(message, .invalidRequest)
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
        let plan = compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace)
        switch supervisor.launch(
            host: hook,
            command: command,
            plan: plan,
            io: .discard,
            admission: .failClosed,
            sessionStore: sessionStore
        ) {
        case .failure(let error):
            return failure(message, workspaceControlCode(error))
        case .success(let running):
            return WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                id: message.id,
                op: WorkspaceControlOp.launchRuntime.rawValue,
                runtime: running.id.rawValue,
                hook: running.session.host?.rawValue,
                ok: true,
                running: true
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
        let first = retired.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
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
            let others = connections.withLock { list in
                list.values.filter { $0.id != excluding }
            }
            for connection in others {
                _ = connection.send(event)
            }
        }
        let fds = connections.withLock { list -> [Int32] in
            let values = list.values.map(\.fd)
            list.removeAll()
            return values
        }
        for fd in fds {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        _ = WorkspaceControlSocket.unlinkOwnedSocket(endpoint.socketPath)
        if removeSocketDirectory {
            _ = socketDirectory.withCString { rmdir($0) }
        }
        _ = endpointFile.path.withCString { unlink($0) }
        gate.signal()
    }
}
#endif
