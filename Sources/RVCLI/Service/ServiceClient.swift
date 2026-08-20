import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVService

public struct ClientEvaluateReply: Sendable, Equatable {
    public var decision: String
    public var ruleID: String?
    public var reason: String?
    public var via: String
    public var indeterminateReason: String?

    public init(
        decision: String,
        ruleID: String? = nil,
        reason: String? = nil,
        via: String,
        indeterminateReason: String? = nil
    ) {
        self.decision = decision
        self.ruleID = ruleID
        self.reason = reason
        self.via = via
        self.indeterminateReason = indeterminateReason
    }
}

public struct ServiceClient: Sendable {
    private let transport: (any ServiceTransport)?
    private let injectedFallback: GatedEvaluate?
    private let store: AllowOnceStore

    public init(
        transport: (any ServiceTransport)? = XPCServiceTransport(),
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil
    ) {
        self.transport = transport
        self.injectedFallback = session.map(GatedEvaluate.init)
        self.store = Self.resolveStore(store: store, allowOnceDirectory: allowOnceDirectory)
    }

    public static func missingCore(
        transport: (any ServiceTransport)? = nil,
        allowOnceDirectory: URL? = nil
    ) -> ServiceClient {
        ServiceClient(
            transport: transport,
            session: .missingCore,
            allowOnceDirectory: allowOnceDirectory ?? isolatedFactoryDirectory()
        )
    }

    public static func uncompilableCore(
        transport: (any ServiceTransport)? = nil,
        allowOnceDirectory: URL? = nil
    ) -> ServiceClient {
        ServiceClient(
            transport: transport,
            session: .uncompilableCore,
            allowOnceDirectory: allowOnceDirectory ?? isolatedFactoryDirectory()
        )
    }

    public func insertGranted(matchingView: MatchingView, cwd: String, now: Date = Date()) async throws {
        try await store.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    public func evaluate(command: String, cwd: String? = nil) async -> ClientEvaluateReply {
        let evaluation = await evaluateRouted(command: ShellCommand(rawValue: command), cwd: cwd)
        return Self.view(evaluation.result, via: evaluation.via)
    }

    public func evaluateResult(command: ShellCommand, cwd: String? = nil) async -> EvaluationResult {
        await evaluateRouted(command: command, cwd: cwd).result
    }

    private func evaluateRouted(
        command: ShellCommand,
        cwd: String?
    ) async -> (result: EvaluationResult, via: String) {
        let request = EvaluationRequest(
            command: command,
            enabledPacks: dayOnePackIDs
        )
        switch await route() {
        case .xpc(let transport, _):
            do {
                let body = try IPCJSON.encode(
                    IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: cwd)))
                )
                let data = try await transport.send(body)
                let response = try IPCJSON.decode(IPCResponse.self, from: data)
                if case .evaluate(let reply) = response.result {
                    return (reply.result, "xpc")
                }
                return (await inProcessEvaluate(request, cwd: cwd), "inProcess")
            } catch {
                return (await inProcessEvaluate(request, cwd: cwd), "inProcess")
            }
        case .down, .skew, .failed:
            return (await inProcessEvaluate(request, cwd: cwd), "inProcess")
        }
    }

    private func inProcessEvaluate(_ request: EvaluationRequest, cwd: String?) async -> EvaluationResult {
        await fallback().apply(
            request,
            cwd: cwd,
            store: store,
            now: Date()
        )
    }

    public func status() async -> ServiceStatusReport {
        await diagnostics().statusReport
    }

    func diagnostics() async -> ServiceDiagnosticResult {
        let localCorePacksReady = fallback().corePacksReady
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
            } catch is DecodingError {
                return localDiagnostic(
                    cause: .requestFailed(.invalidResponse),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            } catch is EncodingError {
                return localDiagnostic(
                    cause: .requestFailed(.invalidResponse),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            } catch let error as ServiceTransportError {
                return localDiagnostic(
                    cause: .requestFailed(.transport(error)),
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            } catch {
                return localDiagnostic(
                    cause: .requestFailed(.transport(.unexpected)),
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

    private func fallback() -> GatedEvaluate {
        injectedFallback ?? GatedEvaluate()
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
            if ack.skewReason == "core packs unavailable" {
                return .corePacksUnavailable
            }
            return .rejected
        }
        return nil
    }

    private static func view(_ result: EvaluationResult, via: String) -> ClientEvaluateReply {
        switch result.decision {
        case .allow:
            return ClientEvaluateReply(
                decision: "allow",
                ruleID: result.matched?.ruleID.rawValue,
                via: via
            )
        case .deny(let deny):
            return ClientEvaluateReply(
                decision: "deny",
                ruleID: deny.ruleID.rawValue,
                reason: deny.reason,
                via: via
            )
        case .indeterminate(let reason):
            return ClientEvaluateReply(
                decision: "indeterminate",
                via: via,
                indeterminateReason: reason.rawValue
            )
        }
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
