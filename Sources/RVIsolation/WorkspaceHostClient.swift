#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

enum LegacyTerminalEnsureLock {
    static var directoryPath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-terminal-ensure-\(getuid())", isDirectory: true)
            .path
    }

    static var lockPath: String {
        URL(fileURLWithPath: directoryPath)
            .appendingPathComponent("ensure.lock")
            .path
    }

    static func acquire() -> Int32? {
        guard WorkspaceControlSocket.prepareDirectory(directoryPath) else { return nil }
        let path = lockPath
        let fd = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0,
            info.st_uid == getuid(),
            (info.st_mode & S_IFMT) == S_IFREG,
            (info.st_mode & 0o077) == 0
        else {
            Darwin.close(fd)
            return nil
        }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                Darwin.close(fd)
                return nil
            }
        }
        return fd
    }

    static func release(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }

    static func withLock<Value>(_ body: () -> Value) -> Value? {
        guard let fd = acquire() else { return nil }
        defer { release(fd) }
        return body()
    }
}

public enum WorkspaceClientFailure: Error, Sendable, Equatable {
    case disconnected
    case malformed
    /// The request exceeds the control-protocol bounds. Nothing was sent.
    case requestTooLarge
    case queueOverloaded
    case timedOut
    case incompatibleProtocol
    case unauthorizedClient
    case workspaceClosing
    case workspaceClosed
    case runtimeNotFound
    case invalidRequest
    /// The host reserves the operation for the prepare→permit→redeem
    /// ceremony and refused to execute it directly.
    case requiresOperatorPermit
    case resourceProfileUnavailable
    case resourceStagingFailed(String)
    case recoveryRequired
    case childTeardownFailed
    case runtimeLimit
    case staleEndpoint
    case terminalUnavailable
    case terminalBusy
    case terminalLimit
    case terminalPrefixCommitted
}

/// One host-owned terminal event. `bytes` are raw PTY output, not text.
public struct WorkspaceTerminalEvent: Sendable, Equatable {
    public var runtime: UUID
    public var body: Body

    public enum Body: Sendable, Equatable {
        case replayBegin(batch: UUID, truncated: Bool, byteCount: Int)
        case replay(sequence: Int64, bytes: Data)
        case replayEnd(batch: UUID)
        case output(sequence: Int64, bytes: Data)
        case inputOwner(Bool)
        case window(rows: Int, columns: Int)
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
    case homeDirectory
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
public final class WorkspaceClient: Sendable {
    private let endpoint: WorkspaceEndpoint
    /// Serializes every read, write, and close on `fd` before a terminal
    /// subscription. After that, the event reader is the only reader.
    private let io: Mutex<ClientState>
    private let writeLock = Mutex<Void>(())
    private let events = EventBoard()

    /// True when the host advertised `ensureTerminalRuntime`. Read from the
    /// Mutex-protected state so the Sendable client holds no mutable storage.
    var supportsEnsureTerminalRuntime: Bool {
        io.withLock { $0.supportsEnsureTerminalRuntime }
    }

    /// True when the host advertised `runtimeResourceProfilesV1`. Launch
    /// calls carrying a resource profile ID fail against hosts that lack it
    /// instead of silently running under the base fence.
    var supportsResourceProfiles: Bool {
        io.withLock { $0.supportsResourceProfiles }
    }

    var supportsIdentityAgentLaunch: Bool {
        io.withLock { $0.supportsIdentityAgentLaunch }
    }

    private struct ClientState {
        var fd: Int32
        var open: Bool
        var supportsEnsureTerminalRuntime: Bool
        var supportsResourceProfiles: Bool
        var supportsIdentityAgentLaunch: Bool
    }

    private init(fd: Int32, endpoint: WorkspaceEndpoint) {
        self.endpoint = endpoint
        self.io = Mutex(
            ClientState(
                fd: fd,
                open: true,
                supportsEnsureTerminalRuntime: false,
                supportsResourceProfiles: false,
                supportsIdentityAgentLaunch: false
            )
        )
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
        // Authenticate the live host before disclosing the endpoint owner token.
        guard let trust = try? ProtectedPeerTrustConfiguration.installed(),
            let peer = try? WorkspacePeerAuthenticator.capture(fd: fd, trust: trust),
            peer.effectiveUserID == getuid(), peer.componentRole == .workspaceHost
        else {
            close(fd)
            return .failure(.unauthorizedClient)
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
            switch client.negotiateCapabilities() {
            case .failure(let error):
                client.finish()
                return .failure(error)
            case .success(let features):
                client.io.withLock {
                    $0.supportsEnsureTerminalRuntime = features.contains(
                        WorkspaceControlFeature.ensureTerminalRuntime
                    )
                    $0.supportsIdentityAgentLaunch = features.contains(
                        WorkspaceControlFeature.identityAgentLaunchV1
                    )
                    $0.supportsResourceProfiles = features.contains(
                        WorkspaceControlFeature.runtimeResourceProfilesV1
                    )
                }
                client.events.setSupportsReplayBatches(
                    features.contains(WorkspaceControlFeature.terminalReplayBatchesV1)
                )
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

    /// Step 8 (F2): the wire carries hook protocol selection only.
    /// Caller-provided staging tags are unrepresentable: there is no
    /// parameter for them, and the server stages no filtered credentials
    /// on this path. Credential selection is definition-derived only.
    public func launchRuntime(
        executable: String,
        arguments: [String] = [],
        hookHost: HookHost? = nil,
        terminalRows: Int? = nil,
        terminalColumns: Int? = nil,
        resourceProfileID: String? = nil
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        guard WorkspaceControlCodec.launchFits(executable: executable, arguments: arguments) else {
            return .failure(.requestTooLarge)
        }
        guard WorkspaceControlCodec.resourceProfileIDFits(resourceProfileID) else {
            return .failure(.invalidRequest)
        }
        if resourceProfileID != nil, supportsResourceProfiles == false {
            return .failure(.incompatibleProtocol)
        }
        var message = WorkspaceControlRequest(
            operation: .launchRuntime,
            id: UUID(),
            executable: executable,
            arguments: arguments,
            resourceProfileID: resourceProfileID,
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
        switch transact(message, timeout: WorkspaceControlLimits.launchTimeoutSeconds) {
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
                    inputOwner: reply.inputOwner ?? false,
                    created: reply.created ?? true
                )
            )
        }
    }

    /// Selects a named definition in the authoritative host's operator configuration.
    /// The client supplies no executable, hook, resource profile or principal.
    public func launchAgentRuntime(
        definitionID: String,
        arguments: [String] = [],
        terminalRows: Int? = nil,
        terminalColumns: Int? = nil
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        guard WorkspaceControlCodec.agentDefinitionIDFits(definitionID) else {
            return .failure(.invalidRequest)
        }
        guard WorkspaceControlCodec.launchFits(executable: "", arguments: arguments) else {
            return .failure(.requestTooLarge)
        }
        let message = WorkspaceControlRequest(
            operation: .launchAgentRuntime,
            id: UUID(),
            arguments: arguments,
            agentDefinitionID: definitionID
        )
        return launchIdentityRuntime(message, rows: terminalRows, columns: terminalColumns)
    }

    /// Explicit custom identity selection. The host creates an ad-hoc definition;
    /// executable names cannot select named authority or credential bindings.
    public func launchCustomRuntime(
        executable: String,
        arguments: [String] = [],
        expectedContentDigestSHA256: String,
        terminalRows: Int? = nil,
        terminalColumns: Int? = nil
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        guard executable.hasPrefix("/"),
            IsolatedCommand(executable: executable, arguments: arguments) != nil,
            WorkspaceControlCodec.customDefinitionDigestFits(expectedContentDigestSHA256)
        else {
            return .failure(.invalidRequest)
        }
        guard WorkspaceControlCodec.launchFits(executable: executable, arguments: arguments) else {
            return .failure(.requestTooLarge)
        }
        let message = WorkspaceControlRequest(
            operation: .launchCustomRuntime,
            id: UUID(),
            executable: executable,
            arguments: arguments,
            customDefinitionDigest: expectedContentDigestSHA256
        )
        return launchIdentityRuntime(message, rows: terminalRows, columns: terminalColumns)
    }

    private func launchIdentityRuntime(
        _ request: WorkspaceControlRequest,
        rows: Int?,
        columns: Int?
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        guard supportsIdentityAgentLaunch else { return .failure(.incompatibleProtocol) }
        var message = request
        switch (rows, columns) {
        case (nil, nil):
            break
        case let (rows?, columns?) where TerminalStreamLimits.accepts(rows: rows, columns: columns):
            message.io = "terminal"
            message.rows = rows
            message.columns = columns
        default:
            return .failure(.invalidRequest)
        }
        switch transact(message, timeout: WorkspaceControlLimits.launchTimeoutSeconds) {
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
                    inputOwner: reply.inputOwner ?? false,
                    created: reply.created ?? true
                )
            )
        }
    }

    /// Ensures at least one running host-owned terminal exists. Concurrent
    /// callers are serialized by the host and receive the same runtime.
    ///
    /// Canonical-shell contract: when a running terminal exists it is
    /// returned regardless of the requested executable, arguments, hook,
    /// or profile — those select the command only when creating. A reused
    /// runtime keeps the grants it was created with. Callers that need a
    /// specific command must use `launchRuntime`.
    public func ensureTerminalRuntime(
        executable: String,
        arguments: [String] = [],
        hookHost: HookHost? = nil,
        terminalRows: Int,
        terminalColumns: Int,
        resourceProfileID: String? = nil
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        guard executable.hasPrefix("/"),
            IsolatedCommand(executable: executable, arguments: arguments) != nil,
            TerminalStreamLimits.accepts(rows: terminalRows, columns: terminalColumns)
        else {
            return .failure(.invalidRequest)
        }
        guard WorkspaceControlCodec.launchFits(executable: executable, arguments: arguments) else {
            return .failure(.requestTooLarge)
        }
        guard WorkspaceControlCodec.resourceProfileIDFits(resourceProfileID) else {
            return .failure(.invalidRequest)
        }
        if resourceProfileID != nil, supportsResourceProfiles == false {
            return .failure(.incompatibleProtocol)
        }
        guard supportsEnsureTerminalRuntime else {
            return ensureTerminalRuntimeOnLegacyHost(
                executable: executable,
                arguments: arguments,
                hookHost: hookHost,
                terminalRows: terminalRows,
                terminalColumns: terminalColumns
            )
        }
        let message = WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            id: UUID(),
            executable: executable,
            arguments: arguments,
            resourceProfileID: resourceProfileID,
            hook: hookHost?.rawValue,
            io: "terminal",
            rows: terminalRows,
            columns: terminalColumns
        )
        switch transact(message, timeout: WorkspaceControlLimits.launchTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard let runtime = reply.runtime, let running = reply.running, reply.terminal == true else {
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
                    inputOwner: reply.inputOwner ?? false,
                    created: reply.created ?? false
                )
            )
        }
    }

    /// Subscribes this connection to a terminal. After the host drops the
    /// subscription for overflow (a `.overflow` event), call
    /// `resubscribeTerminal` to resume from replay, then re-acquire input if
    /// this client held it.
    public func subscribeTerminal(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        // A prior client-side overflow would swallow this subscription's
        // output; clear the mark before the RPC so the fresh replay and
        // live frames are admitted. Queued backlog is untouched.
        events.clearOverflowed(runtime)
        let message = WorkspaceControlRequest(
            operation: .subscribeTerminal,
            id: UUID(),
            runtime: runtime,
            features: [
                WorkspaceControlFeature.terminalWindowNoticesV1,
                WorkspaceControlFeature.terminalReplayBatchesV1,
            ]
        )
        let result = transact(
            message,
            timeout: WorkspaceControlLimits.launchTimeoutSeconds,
            beginStreaming: true
        )
        if case .success = result {
            startEventReader()
        }
        return result.map { _ in () }
    }

    /// Re-establishes a terminal subscription after the host dropped it for
    /// overflow. The host replays recent bytes, then live output resumes.
    /// Re-acquire input after this returns if the client held the lease.
    /// The TUI calls this automatically after `.overflow` and after a failed
    /// acquire on a believed-subscribed pane. Heartbeat probes use plain
    /// subscribe (read-only on healthy duplicates); a successful probe may
    /// briefly duplicate backlog with replay, which the flood context makes
    /// invisible.
    public func resubscribeTerminal(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        switch unsubscribeTerminal(runtime) {
        case .failure(let error):
            return .failure(error)
        case .success:
            events.resetRuntime(runtime)
        }
        return subscribeTerminal(runtime)
    }

    public func unsubscribeTerminal(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        let message = WorkspaceControlRequest(
            operation: .unsubscribeTerminal,
            id: UUID(),
            runtime: runtime
        )
        return transact(message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func acquireTerminalInput(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        let message = WorkspaceControlRequest(
            operation: .acquireTerminalInput,
            id: UUID(),
            runtime: runtime
        )
        return transact(message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func releaseTerminalInput(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        let message = WorkspaceControlRequest(
            operation: .releaseTerminalInput,
            id: UUID(),
            runtime: runtime
        )
        return transact(message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func writeTerminal(_ runtime: UUID, bytes: Data) -> Result<Void, WorkspaceClientFailure> {
        guard bytes.isEmpty == false, bytes.count <= TerminalStreamLimits.maximumInputBytes else {
            return .failure(.invalidRequest)
        }
        let message = WorkspaceControlRequest(
            operation: .terminalInput,
            id: UUID(),
            runtime: runtime,
            bytes: TerminalBytesCodec.encode(bytes)
        )
        return transact(message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func resizeTerminal(
        _ runtime: UUID,
        rows: Int,
        columns: Int
    ) -> Result<Void, WorkspaceClientFailure> {
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else {
            return .failure(.invalidRequest)
        }
        let message = WorkspaceControlRequest(
            operation: .resizeTerminal,
            id: UUID(),
            runtime: runtime,
            rows: rows,
            columns: columns
        )
        return transact(message, timeout: WorkspaceControlLimits.describeTimeoutSeconds).map { _ in () }
    }

    public func nextTerminalEvent(
        timeout: TimeInterval
    ) -> Result<WorkspaceTerminalRead, WorkspaceClientFailure> {
        events.next(timeout: timeout).flatMap { message in
            guard let message else { return .success(.waiting) }
            if message.operation == .workspaceClosed {
                return .failure(.workspaceClosed)
            }
            guard let event = TerminalStreamCodec.decode(message) else {
                return .failure(.malformed)
            }
            return .success(.event(event))
        }
    }

    public func cancelRuntime(_ runtime: UUID) -> Result<Void, WorkspaceClientFailure> {
        let message = WorkspaceControlRequest(
            operation: .cancelRuntime,
            id: UUID(),
            runtime: runtime
        )
        return transact(message, timeout: WorkspaceControlLimits.launchTimeoutSeconds).map { _ in () }
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
                    guard message.operation == .workspaceClosed else {
                        continue
                    }
                    return description(message)
                }
            }
        }
    }

    private func hello() -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        let message = WorkspaceControlRequest(
            operation: .hello,
            id: UUID(),
            token: endpoint.ownerToken
        )
        return transact(message, timeout: WorkspaceControlLimits.connectTimeoutSeconds)
    }

    private func negotiateCapabilities() -> Result<[String], WorkspaceClientFailure> {
        Self.negotiatedFeatures(
            from: transact(op: .capabilities, timeout: WorkspaceControlLimits.describeTimeoutSeconds)
        )
    }

    /// Maps a capabilities RPC to its feature list. Older persistent hosts
    /// reject the operation with `invalidRequest`; they remain usable through
    /// the serialized ensure fallback below.
    /// Legacy-message entry kept for existing tests outside T6's
    /// exclusive writes; production uses the typed `from:` overload.
    static func negotiatedFeatures(
        from result: Result<WorkspaceControlMessage, WorkspaceClientFailure>
    ) -> Result<[String], WorkspaceClientFailure> {
        switch result {
        case .failure(let error):
            negotiatedFeatures(
                from: Result<WorkspaceControlResponse, WorkspaceClientFailure>.failure(error)
            )
        case .success(let message):
            negotiatedFeatures(from: .success(WorkspaceControlResponse(message)))
        }
    }

    static func negotiatedFeatures(
        from result: Result<WorkspaceControlResponse, WorkspaceClientFailure>
    ) -> Result<[String], WorkspaceClientFailure> {
        switch result {
        case .failure(.invalidRequest):
            return .success([])
        case .failure(let error):
            return .failure(error)
        case .success(let message):
            guard message.operation == .capabilities, message.ok == true else {
                return .failure(.malformed)
            }
            return .success(message.features ?? [])
        }
    }

    /// Forces the legacy ensure path for tests. Production sets this once
    /// from the capabilities negotiation in `connect`.
    func testingSetSupportsEnsureTerminalRuntime(_ value: Bool) {
        io.withLock { $0.supportsEnsureTerminalRuntime = value }
    }

    private func ensureTerminalRuntimeOnLegacyHost(
        executable: String,
        arguments: [String],
        hookHost: HookHost?,
        terminalRows: Int,
        terminalColumns: Int
    ) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure> {
        let fallback = LegacyTerminalEnsureLock.withLock {
            switch listRuntimes() {
            case .failure(let error):
                return Result<WorkspaceRuntimeReport, WorkspaceClientFailure>.failure(error)
            case .success(let runtimes):
                if let existing = runtimes
                    .filter({ $0.running && $0.terminal })
                    .sorted(by: { $0.runtime.uuidString < $1.runtime.uuidString })
                    .first
                {
                    return .success(existing)
                }
                return launchRuntime(
                    executable: executable,
                    arguments: arguments,
                    hookHost: hookHost,
                    terminalRows: terminalRows,
                    terminalColumns: terminalColumns
                )
            }
        }
        return fallback ?? .failure(.timedOut)
    }

    private func transact(
        op: WorkspaceControlOp,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        let message = WorkspaceControlRequest(
            operation: op,
            id: UUID()
        )
        return transact(message, timeout: timeout)
    }

    private func transact(
        _ message: WorkspaceControlRequest,
        timeout: TimeInterval,
        beginStreaming: Bool = false
    ) -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        if events.isStreaming {
            return streamingTransact(message, timeout: timeout)
        }
        guard let rpc = rpcTransact(message, timeout: timeout, beginStreaming: beginStreaming) else {
            return streamingTransact(message, timeout: timeout)
        }
        return rpc
    }

    /// Nil means a terminal reader owns the socket and the caller must retry
    /// on the streaming path. The request was not written.
    private func rpcTransact(
        _ message: WorkspaceControlRequest,
        timeout: TimeInterval,
        beginStreaming: Bool
    ) -> Result<WorkspaceControlResponse, WorkspaceClientFailure>? {
        // Encode fails only when the frame exceeds `maxBodyBytes`. Nothing
        // was sent; this is a local size refusal, not a host rejection.
        guard let body = message.encode() else { return .failure(.requestTooLarge) }
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
                    if reply.operation == .workspaceClosed,
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
        _ message: WorkspaceControlRequest,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        // Encode fails only when the frame exceeds `maxBodyBytes`. Nothing
        // was sent; this is a local size refusal, not a host rejection.
        guard let requestID = message.id else {
            return .failure(.malformed)
        }
        guard let body = message.encode() else {
            return .failure(.requestTooLarge)
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
        let wrote = writeLock.withLock { _ in
            WorkspaceControlSocket.writeFrame(fd: fd, body: body)
        }
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
                switch WorkspaceControlResponse.decode(data) {
                case .incompatible:
                    failStream(.incompatibleProtocol)
                    return
                case .invalid:
                    failStream(.malformed)
                    return
                case .response(let message):
                    if events.deliver(message) == false {
                        failStream(.malformed)
                        return
                    }
                    if message.operation == .workspaceClosed {
                        failStream(.workspaceClosed)
                        return
                    }
                }
            }
        }
    }

    private func failStream(_ error: WorkspaceClientFailure) {
        writeLock.withLock { _ in
            io.withLock { closeLocked(&$0) }
        }
        events.failAll(error)
    }

    /// Caller holds `io`. A broken frame closes the socket so the next call
    /// cannot pair a later reply with an earlier request.
    private func readFrame(
        state: inout ClientState,
        timeout: TimeInterval
    ) -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        guard state.open, state.fd >= 0 else { return .failure(.disconnected) }
        switch WorkspaceControlSocket.readFrame(fd: state.fd, timeout: timeout) {
        case .failure(.timedOut):
            closeLocked(&state)
            return .failure(.timedOut)
        case .failure:
            closeLocked(&state)
            return .failure(.disconnected)
        case .success(let data):
            switch WorkspaceControlResponse.decode(data) {
            case .incompatible:
                closeLocked(&state)
                return .failure(.incompatibleProtocol)
            case .invalid:
                closeLocked(&state)
                return .failure(.malformed)
            case .response(let message):
                return .success(message)
            }
        }
    }

    private func interpret(
        _ message: WorkspaceControlResponse
    ) -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        guard message.ok != false else {
            guard let code = message.code else {
                return .failure(.malformed)
            }
            return .failure(WorkspaceClientFailure(controlCode: code, detail: message.detail))
        }
        return .success(message)
    }

    private func description(
        _ message: WorkspaceControlResponse
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

final class ReplyWaiter: Sendable {
    private let group = DispatchGroup()
    private let state = Mutex<State>(State())

    private struct State {
        var message: WorkspaceControlResponse?
        var failure: WorkspaceClientFailure?
    }

    init() {
        group.enter()
    }

    func succeed(_ message: WorkspaceControlResponse) {
        settle(message: message, failure: nil)
    }

    func fail(_ error: WorkspaceClientFailure) {
        settle(message: nil, failure: error)
    }

    /// First settle wins and balances the initial `enter`.
    private func settle(message: WorkspaceControlResponse?, failure: WorkspaceClientFailure?) {
        let first = state.withLock { state -> Bool in
            if state.message != nil || state.failure != nil { return false }
            state.message = message
            state.failure = failure
            return true
        }
        if first {
            group.leave()
        }
    }

    func wait(timeout: TimeInterval) -> Result<WorkspaceControlResponse, WorkspaceClientFailure> {
        _ = group.wait(timeout: .now() + timeout)
        return state.withLock { state -> Result<WorkspaceControlResponse, WorkspaceClientFailure> in
            if let message = state.message {
                return message.ok == false
                    ? .failure(message.code.map { WorkspaceClientFailure(controlCode: $0, detail: message.detail) } ?? .malformed)
                    : .success(message)
            }
            if let failure = state.failure {
                return .failure(failure)
            }
            return .failure(.timedOut)
        }
    }
}

#endif
