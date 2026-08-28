import Foundation
import RVDomain
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

    public func evaluate(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> RoutedEvaluation {
        func inProcessRoute() async -> RoutedEvaluation {
            let now = clock()
            let baseDirectory = store.baseDirectory
            return RoutedEvaluation(
                result: await door.run(
                    .apply,
                    command: command,
                    cwd: cwd,
                    home: home,
                    store: store,
                    now: now,
                    allowlist: {
                        AllowlistStore(baseDirectory: baseDirectory)
                            .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
                    }
                ),
                path: .inProcess
            )
        }
        guard let transport else {
            return await inProcessRoute()
        }
        do {
            let evaluationRequest = GatedEvaluate.makeRequest(command: command, home: home)
            let request = IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: evaluationRequest,
                        cwd: cwd,
                        clientSemver: ProtocolVersion.serviceSemver
                    )
                )
            )
            let body = try IPCJSON.encode(request)
            let data = try await transport.send(body, timeoutMs: transport.oneShotEvaluateTimeoutMs)
            let response = try IPCJSON.decode(IPCResponse.self, from: data)
            guard response.id == request.id,
                  response.protocolName == request.protocolName
            else {
                transport.invalidate()
                return await inProcessRoute()
            }
            // Decode already requires EvaluateReply.via == .xpc; anything else falls back.
            if case .evaluate(let reply) = response.result {
                switch EvaluationRoute.path(for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: reply.serviceSemver
                )) {
                case .xpc:
                    return RoutedEvaluation(result: reply.result, path: .xpc)
                case .inProcess:
                    transport.invalidate()
                    return await inProcessRoute()
                }
            }
            transport.invalidate()
            return await inProcessRoute()
        } catch {
            return await inProcessRoute()
        }
    }

    public func evaluateResult(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> EvaluationResult {
        await evaluate(command: command, cwd: cwd).result
    }

    /// Plant+spend a host Allow once on the same grant file evaluate uses.
    public func spendHostAsk(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> EvaluationResult {
        let now = clock()
        let baseDirectory = store.baseDirectory
        return await door.spendHostAsk(
            command: command,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: {
                AllowlistStore(baseDirectory: baseDirectory)
                    .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
            }
        )
    }

    public func status() async -> ServiceStatusReport {
        ServiceHealth.inspect(await diagnostics()).statusReport
    }

    func diagnostics() async -> ServiceDiagnosticResult {
        let localCorePacksReady = door.corePacksReady
        switch await route() {
        case .xpc(let transport, let serviceSemver):
            let request = IPCRequest(method: .doctorSnapshot)
            do {
                let data = try await transport.send(IPCJSON.encode(request))
                let response = try IPCJSON.decode(IPCResponse.self, from: data)
                guard response.id == request.id,
                      response.protocolName == ProtocolVersion.name
                else {
                    return localDiagnostic(
                        cause: .requestFailed(.invalidResponse),
                        corePacksReady: localCorePacksReady,
                        serviceSemver: serviceSemver
                    )
                }
                switch response.result {
                case .doctorSnapshot(let snapshot):
                    return .xpc(
                        snapshot: snapshot,
                        localCorePacksReady: localCorePacksReady
                    )
                case .error(.protocolSkew):
                    return localDiagnostic(
                        cause: .skew(.protocolMismatch),
                        corePacksReady: localCorePacksReady,
                        serviceSemver: serviceSemver
                    )
                case .error(let error):
                    return localDiagnostic(
                        cause: .requestFailed(.service(error)),
                        corePacksReady: localCorePacksReady,
                        serviceSemver: serviceSemver
                    )
                default:
                    return localDiagnostic(
                        cause: .requestFailed(.unexpectedResponse),
                        corePacksReady: localCorePacksReady,
                        serviceSemver: serviceSemver
                    )
                }
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
            return AllowOnceStore.live(home: home)
        }
        return AllowOnceStore(baseDirectory: isolatedFactoryDirectory())
    }

    private static func isolatedFactoryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-client-allow-once-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
