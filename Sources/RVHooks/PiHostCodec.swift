import Foundation
import RVDomain

/// Adapter wire for Pi, not a host protocol.
public struct PiHostCodec: HostAskCodec {
    /// The Pi adapter host.
    public var host: HookHost { .pi }

    /// Creates a Pi adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PiEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard envelope.toolName == "bash" else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId).flatMap { SessionID(validating: $0) }
        let hostAsk = envelope.hostAsk.flatMap(HostAskHookIntent.init(rawValue:))
        return HookRequest.decoded(
            host: .pi,
            cwd: cwd,
            session: session,
            payload: .shell(command: envelope.input?.command, ask: hostAsk)
        )
    }

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }

    public func encodeAsk(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionAsk(reason: reason, rule: rule, next: next)
    }
}

private struct PiEnvelope: Decodable {
    var toolName: String?
    var input: PiInput?
    var cwd: String?
    var sessionId: String?
    var hostAsk: String?
}

private struct PiInput: Decodable {
    var command: String?
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}
