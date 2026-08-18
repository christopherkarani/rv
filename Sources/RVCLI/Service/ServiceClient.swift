import Foundation
import RVDomain
import RVIPC

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
    private let fallback: InProcessFallback

    public init(
        transport: (any ServiceTransport)? = XPCServiceTransport(),
        fallback: InProcessFallback = InProcessFallback(),
        connectTimeoutMs: Int = 200,
        requestTimeoutMs: Int = 500
    ) {
        self.transport = transport
        self.fallback = fallback
        self.connectTimeoutMs = connectTimeoutMs
        self.requestTimeoutMs = requestTimeoutMs
    }

    public func evaluate(command: String) async -> ClientEvaluateReply {
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: command),
            enabledPacks: dayOnePackIDs
        )
        switch await route() {
        case .xpc(let transport):
            do {
                let body = try IPCJSON.encode(
                    IPCRequest(method: .evaluate(EvaluateParams(request: request)))
                )
                let data = try await transport.send(body)
                let response = try IPCJSON.decode(IPCResponse.self, from: data)
                if case .evaluate(let reply) = response.result {
                    return Self.view(reply.result, via: "xpc")
                }
                return Self.view(fallback.evaluate(request), via: "inProcess")
            } catch {
                return Self.view(fallback.evaluate(request), via: "inProcess")
            }
        case .down, .skew:
            return Self.view(fallback.evaluate(request), via: "inProcess")
        }
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
}
