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
        case .xpc(let transport):
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
        case .down, .skew:
            return (await inProcessEvaluate(request, cwd: cwd), "inProcess")
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
