import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVService

public enum EvaluationPath: String, Sendable, Equatable {
    case xpc
    case inProcess
}

public struct RoutedEvaluation: Sendable, Equatable {
    public var result: EvaluationResult
    public var path: EvaluationPath

    public init(result: EvaluationResult, path: EvaluationPath) {
        self.result = result
        self.path = path
    }
}

public struct ServiceClient: Sendable {
    public var connectTimeoutMs: Int
    public var requestTimeoutMs: Int

    private let transport: (any ServiceTransport)?
    private let session: EvaluateSession?
    private let store: AllowOnceStore

    public init(
        transport: (any ServiceTransport)? = XPCServiceTransport(),
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        connectTimeoutMs: Int = 200,
        requestTimeoutMs: Int = 500
    ) {
        self.transport = transport
        self.session = session
        self.store = Self.resolveStore(store: store, allowOnceDirectory: allowOnceDirectory)
        self.connectTimeoutMs = connectTimeoutMs
        self.requestTimeoutMs = requestTimeoutMs
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

    public func evaluate(command: String, cwd: String? = nil) async -> RoutedEvaluation {
        await evaluateRouted(command: ShellCommand(rawValue: command), cwd: cwd)
    }

    public func evaluateResult(command: ShellCommand, cwd: String? = nil) async -> EvaluationResult {
        await evaluate(command: command.rawValue, cwd: cwd).result
    }

    private func evaluateRouted(
        command: ShellCommand,
        cwd: String?
    ) async -> RoutedEvaluation {
        let request = dayOneEvaluationRequest(command: command)
        switch await route() {
        case .xpc(let transport):
            do {
                let body = try IPCJSON.encode(
                    IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: cwd)))
                )
                let data = try await transport.send(body)
                let response = try IPCJSON.decode(IPCResponse.self, from: data)
                if case .evaluate(let reply) = response.result, reply.via == EvaluationPath.xpc.rawValue {
                    return RoutedEvaluation(result: reply.result, path: .xpc)
                }
                return RoutedEvaluation(
                    result: await inProcessEvaluate(request, cwd: cwd),
                    path: .inProcess
                )
            } catch {
                return RoutedEvaluation(
                    result: await inProcessEvaluate(request, cwd: cwd),
                    path: .inProcess
                )
            }
        case .down, .skew:
            return RoutedEvaluation(
                result: await inProcessEvaluate(request, cwd: cwd),
                path: .inProcess
            )
        }
    }

    private func inProcessEvaluate(_ request: EvaluationRequest, cwd: String?) async -> EvaluationResult {
        await GatedEvaluate(session ?? EvaluateSession()).apply(
            request,
            cwd: cwd,
            store: store,
            now: Date()
        )
    }

    public func status() async -> ServiceStatusReport {
        switch await route() {
        case .xpc:
            return ServiceStatusReport(state: "running", fallback: "inactive")
        case .down:
            return ServiceStatusReport(state: "down", fallback: "down")
        case .skew(let reason):
            return ServiceStatusReport(state: "skew", fallback: "skew", lastError: reason)
        }
    }

    private enum Route {
        case xpc(any ServiceTransport)
        case down
        case skew(String)
    }

    private func route() async -> Route {
        guard let transport else { return .down }
        do {
            let ack = try await transport.hello(clientSemver: ProtocolVersion.serviceSemver)
            if isSkew(ack) {
                return .skew(ack.skewReason ?? "protocol")
            }
            return .xpc(transport)
        } catch {
            return .down
        }
    }

    private func isSkew(_ ack: HelloAckView) -> Bool {
        if ack.ok == false { return true }
        if ack.protocolName != ProtocolVersion.name { return true }
        if ProtocolVersion.isMajorSkew(
            clientSemver: ProtocolVersion.serviceSemver,
            serviceSemver: ack.serviceSemver
        ) {
            return true
        }
        return false
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
