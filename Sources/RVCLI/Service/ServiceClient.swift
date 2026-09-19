import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import RVPolicy
import RVService

public struct RoutedEvaluation: Sendable, Equatable {
    public let result: EvaluationResult
    public let path: EvaluationPath

    public init(result: EvaluationResult, path: EvaluationPath) {
        self.result = result
        self.path = path
    }
}

public struct ServiceClient: Sendable {
    private let transport: (any ServiceTransport)?
    private let door: GatedEvaluate
    private let store: AllowOnceStore
    private let pendingApprovals: (any PendingApprovalCoordinating)?
    private let home: HomeDirectory?
    private let clock: @Sendable () -> Date

#if canImport(XPC)
    public init(
        transport: (any ServiceTransport)? = XPCServiceTransport(),
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        home: HomeDirectory? = HomeDirectory.process(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            resolvedTransport: transport,
            session: session,
            store: store,
            allowOnceDirectory: allowOnceDirectory,
            home: home,
            clock: clock
        )
    }
#else
    public init(
        transport: (any ServiceTransport)? = nil,
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        home: HomeDirectory? = HomeDirectory.process(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            resolvedTransport: transport,
            session: session,
            store: store,
            allowOnceDirectory: allowOnceDirectory,
            home: home,
            clock: clock
        )
    }
#endif

    private init(
        resolvedTransport: (any ServiceTransport)?,
        session: EvaluateSession?,
        store: AllowOnceStore?,
        allowOnceDirectory: URL?,
        home: HomeDirectory?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.transport = resolvedTransport
        if let session {
            self.door = GatedEvaluate(session)
        } else {
            self.door = EvaluationWorld.assemble(home: home, snapshots: nil, catalog: nil)
        }
        self.store = Self.resolveStore(store: store, allowOnceDirectory: allowOnceDirectory, home: home)
        self.pendingApprovals = Self.resolvePending(home: home)
        self.home = home
        self.clock = clock
    }

    /// Test seam: builds the fallback door from an explicit provider so tests can
    /// observe when the in-process session is constructed.
    package init(
        transport: (any ServiceTransport)?,
        lazySession: @escaping @Sendable () -> EvaluateSession,
        allowOnceDirectory: URL?,
        home: HomeDirectory?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.door = GatedEvaluate(lazySession: lazySession)
        self.store = Self.resolveStore(store: nil, allowOnceDirectory: allowOnceDirectory, home: home)
        self.pendingApprovals = Self.resolvePending(home: home)
        self.home = home
        self.clock = clock
    }

    public static func missingCore(
        transport: (any ServiceTransport)? = nil,
        allowOnceDirectory: URL? = nil
    ) -> ServiceClient {
        let sandbox = isolatedFactoryDirectory()
        return ServiceClient(
            transport: transport,
            session: .missingCore,
            allowOnceDirectory: allowOnceDirectory ?? sandbox,
            home: HomeDirectory(validating: sandbox.path)
        )
    }

    public static func uncompilableCore(
        transport: (any ServiceTransport)? = nil,
        allowOnceDirectory: URL? = nil
    ) -> ServiceClient {
        let sandbox = isolatedFactoryDirectory()
        return ServiceClient(
            transport: transport,
            session: .uncompilableCore,
            allowOnceDirectory: allowOnceDirectory ?? sandbox,
            home: HomeDirectory(validating: sandbox.path)
        )
    }

    package func insertGranted(matchingView: MatchingView, cwd: WorkingDirectory, now: Date = Date()) async throws {
        try await store.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    private func liveWorld() -> LiveEvaluateWorld {
        LiveEvaluateWorld(home: home, store: store, gated: door, clock: clock)
    }

    private func inProcessApply(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        await liveWorld().apply(command: command, cwd: cwd, host: host)
    }

    public func evaluate(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> RoutedEvaluation {
        func inProcessRoute() async -> RoutedEvaluation {
            RoutedEvaluation(result: await inProcessApply(command: command, cwd: cwd), path: .inProcess)
        }
        guard let transport else {
            return await inProcessRoute()
        }
        do {
            let reply = try await send(
                EvaluateCall(
                    params: EvaluateParams(
                        request: GatedEvaluate.makeRequest(command: command, home: home),
                        cwd: cwd,
                        clientSemver: ProtocolVersion.serviceSemver
                    )
                ),
                using: transport,
                timeoutMs: transport.oneShotEvaluateTimeoutMs
            )
            switch EvaluationRoute.path(for: .reply(
                clientSemver: ProtocolVersion.serviceSemver,
                advertisedServiceSemver: reply.serviceSemver
            )) {
            case .service:
                return RoutedEvaluation(result: reply.result, path: .service)
            case .inProcess:
                transport.invalidate()
                return await inProcessRoute()
            }
        } catch is IPCCallError {
            transport.invalidate()
            return await inProcessRoute()
        } catch {
            return await inProcessRoute()
        }
    }

    public func evaluateResult(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> EvaluationResult {
        await evaluate(command: command, cwd: cwd).result
    }

    private enum IPCCallError: Error, Sendable, Equatable {
        case identityMismatch
        case unexpectedResult
        case service(IPCError)
    }

    private func send<C: IPCCall>(
        _ call: C,
        using transport: any ServiceTransport,
        timeoutMs: Int? = nil
    ) async throws -> C.Reply {
        let request = IPCRequest(method: call.method)
        let body = try IPCJSON.encode(request)
        let data: Data
        if let timeoutMs {
            data = try await transport.send(body, timeoutMs: timeoutMs)
        } else {
            data = try await transport.send(body)
        }
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard response.id == request.id, response.protocolName == request.protocolName else {
            throw IPCCallError.identityMismatch
        }
        if case .error(let error) = response.result {
            throw IPCCallError.service(error)
        }
        guard let reply = C.extract(response.result) else {
            throw IPCCallError.unexpectedResult
        }
        return reply
    }

    /// Maps host stdin through IPC `hookEvaluate`, or in-process `hookWire` on miss.
    public func hookEvaluate(host: HookHost, stdin: String) async -> HookWire {
        func inProcessWire() async -> HookWire {
            await hookWire(
                host: host,
                stdin: stdin,
                world: HookEvaluateWorld.live(
                    world: liveWorld(),
                    host: host,
                    pending: pendingApprovals,
                    clock: clock
                )
            )
        }
        guard let transport else {
            return await inProcessWire()
        }
        do {
            let reply = try await send(
                HookEvaluateCall(
                    params: HookEvaluateParams(
                        host: host,
                        stdin: stdin,
                        clientSemver: ProtocolVersion.serviceSemver
                    )
                ),
                using: transport,
                timeoutMs: transport.oneShotEvaluateTimeoutMs
            )
            switch EvaluationRoute.path(for: .reply(
                clientSemver: ProtocolVersion.serviceSemver,
                advertisedServiceSemver: reply.serviceSemver
            )) {
            case .service:
                return HookWire(stdout: reply.stdout, exitCode: reply.exitCode, stderr: reply.stderr)
            case .inProcess:
                transport.invalidate()
                return await inProcessWire()
            }
        } catch is IPCCallError {
            transport.invalidate()
            return await inProcessWire()
        } catch {
            return await inProcessWire()
        }
    }

    /// Plant+spend a host Allow once on the same grant file evaluate uses.
    public func spendHostAsk(
        command: ShellCommand,
        cwd: WorkingDirectory? = nil,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        await liveWorld().spend(command: command, cwd: cwd, host: host)
    }

    public func status() async -> ServiceStatusReport {
        ServiceHealth.inspect(await diagnostics()).statusReport
    }

    func diagnostics() async -> ServiceDiagnosticResult {
        let localCorePacksReady = door.corePacksReady
        switch await route() {
        case .xpc(let transport, let serviceSemver):
            do {
                let snapshot = try await send(DoctorSnapshotCall(), using: transport)
                return .xpc(
                    snapshot: snapshot,
                    localCorePacksReady: localCorePacksReady
                )
            } catch IPCCallError.identityMismatch {
                return localDiagnostic(
                    cause: .requestFailed(.invalidResponse),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            } catch IPCCallError.unexpectedResult {
                return localDiagnostic(
                    cause: .requestFailed(.unexpectedResponse),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            } catch let IPCCallError.service(error) {
                if case .protocolSkew = error {
                    return localDiagnostic(
                        cause: .skew(.protocolMismatch),
                        corePacksReady: localCorePacksReady,
                        serviceSemver: serviceSemver
                    )
                }
                return localDiagnostic(
                    cause: .requestFailed(.service(error)),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            } catch {
                return localDiagnostic(
                    cause: .requestFailed(Self.diagnosticFailure(from: error)),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            }
        case .down:
            return localDiagnostic(cause: .down, corePacksReady: localCorePacksReady)
        case .skew(let reason, let serviceSemver):
            return localDiagnostic(
                cause: .skew(reason),
                corePacksReady: localCorePacksReady,
                serviceSemver: serviceSemver
            )
        case .failed(let failure):
            return localDiagnostic(
                cause: .requestFailed(failure),
                corePacksReady: localCorePacksReady
            )
        }
    }

    private func localDiagnostic(
        cause: ServiceFallbackCause,
        corePacksReady: Bool,
        serviceSemver: String? = nil
    ) -> ServiceDiagnosticResult {
        .local(
            ServiceFallbackDiagnostic(
                cause: cause,
                corePacksReady: corePacksReady,
                serviceSemver: serviceSemver
            )
        )
    }

    private static func diagnosticFailure(from error: Error) -> ServiceDiagnosticFailure {
        switch error {
        case is DecodingError, is EncodingError:
            .invalidResponse
        case let error as ServiceTransportError:
            .transport(error)
        default:
            .transport(.unexpected)
        }
    }

    private enum Route {
        case xpc(any ServiceTransport, serviceSemver: String)
        case down
        case skew(ServiceSkewReason, serviceSemver: String)
        case failed(ServiceDiagnosticFailure)
    }

    private func route() async -> Route {
        guard let transport else { return .down }
        do {
            let ack = try await transport.hello(clientSemver: ProtocolVersion.serviceSemver)
            if let reason = skewReason(ack) {
                transport.invalidate()
                return .skew(reason, serviceSemver: ack.serviceSemver)
            }
            return .xpc(transport, serviceSemver: ack.serviceSemver)
        } catch let error as ServiceTransportError {
            switch error {
            case .connectFailed, .timeout, .interrupted:
                return .down
            case .decodeFailed, .unexpected:
                return .failed(.transport(error))
            }
        } catch {
            return .failed(.transport(.unexpected))
        }
    }

    private func skewReason(_ ack: HelloAckView) -> ServiceSkewReason? {
        if ack.protocolName != ProtocolVersion.name {
            return .protocolMismatch
        }
        if ProtocolVersion.isMajorSkew(
            clientSemver: ProtocolVersion.serviceSemver,
            serviceSemver: ack.serviceSemver
        ) {
            return .majorVersionMismatch
        }
        switch ack.status {
        case .ok:
            return nil
        case .skew(.corePacksUnavailable):
            return .corePacksUnavailable
        case .skew(.majorVersion):
            return .majorVersionMismatch
        case .skew(.protocolSkew), .skew(.handshakeRequired):
            return .rejected
        }
    }

    private static func resolveStore(
        store: AllowOnceStore?,
        allowOnceDirectory: URL?,
        home: HomeDirectory?
    ) -> AllowOnceStore {
        if let store {
            return store
        }
        if let allowOnceDirectory {
            return AllowOnceStore(baseDirectory: allowOnceDirectory)
        }
        if let home {
            return AllowOnceStore.makeLive(home: home)
        }
        return AllowOnceStore(baseDirectory: isolatedFactoryDirectory())
    }

    private static func resolvePending(home: HomeDirectory?) -> (any PendingApprovalCoordinating)? {
        if let home {
            return PendingApprovalStore.makeLive(home: home)
        }
        return PendingApprovalStore(baseDirectory: isolatedFactoryDirectory())
    }

    private static func isolatedFactoryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-client-allow-once-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
