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

    public init(
        transport: (any ServiceTransport)? = XPCServiceTransport(),
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        home: HomeDirectory? = HomeDirectory.process(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        if let session {
            self.door = GatedEvaluate(session)
        } else {
            self.door = EvaluationWorld.assemble(home: home, snapshots: nil, catalog: nil)
        }
        self.store = Self.resolveStore(store: store, allowOnceDirectory: allowOnceDirectory)
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
        self.store = Self.resolveStore(store: nil, allowOnceDirectory: allowOnceDirectory)
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

    package func insertGranted(matchingView: MatchingView, cwd: String, now: Date = Date()) async throws {
        try await store.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    public func evaluate(command: ShellCommand, cwd: String? = nil) async -> RoutedEvaluation {
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
                            .loadUserSnapshot(workspacePath: cwd, now: now)
                    }
                ),
                path: .inProcess
            )
        }
        guard let transport else {
            return await inProcessRoute()
        }
        do {
            let request = GatedEvaluate.makeRequest(command: command, home: home)
            let body = try IPCJSON.encode(
                IPCRequest(
                    method: .evaluate(
                        EvaluateParams(
                            request: request,
                            cwd: cwd,
                            clientSemver: ProtocolVersion.serviceSemver
                        )
                    )
                )
            )
            let data = try await transport.send(body, timeoutMs: transport.oneShotEvaluateTimeoutMs)
            let response = try IPCJSON.decode(IPCResponse.self, from: data)
            // Decode already requires EvaluateReply.via == .xpc; anything else falls back.
            if case .evaluate(let reply) = response.result {
                // A reply without serviceSemver cannot prove major
                // compatibility, so it is treated like skew: invalidate and
                // re-route through the always-safe in-process evaluate.
                guard let advertised = reply.serviceSemver else {
                    transport.invalidate()
                    return await inProcessRoute()
                }
                if ProtocolVersion.isMajorSkew(
                    clientSemver: ProtocolVersion.serviceSemver,
                    serviceSemver: advertised
                ) {
                    transport.invalidate()
                    return await inProcessRoute()
                }
                return RoutedEvaluation(result: reply.result, path: .xpc)
            }
            transport.invalidate()
            return await inProcessRoute()
        } catch {
            return await inProcessRoute()
        }
    }

    public func evaluateResult(command: ShellCommand, cwd: String? = nil) async -> EvaluationResult {
        await evaluate(command: command, cwd: cwd).result
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
        if ack.ok == false {
            switch ack.skewReason {
            case .corePacksUnavailable:
                return .corePacksUnavailable
            case .majorVersion:
                return .majorVersionMismatch
            case .protocolSkew, .handshakeRequired, nil:
                return .rejected
            }
        }
        return nil
    }

    private static func resolveStore(
        store: AllowOnceStore?,
        allowOnceDirectory: URL?
    ) -> AllowOnceStore {
        if let store {
            return store
        }
        if let allowOnceDirectory {
            return AllowOnceStore(baseDirectory: allowOnceDirectory)
        }
        return .live()
    }

    private static func isolatedFactoryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-client-allow-once-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
