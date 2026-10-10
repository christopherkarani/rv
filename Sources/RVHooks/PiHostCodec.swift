import Foundation
import RVDomain

/// Adapter wire for Pi, not a host protocol.
public struct PiHostCodec: HostCodec {
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
        guard let toolName = envelope.toolName,
              PiToolName(wireValue: toolName).strictMatch == .shell
        else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId).flatMap { SessionID(validating: $0) }
        return HookRequest.decoded(
            host: .pi,
            command: envelope.input?.command,
            cwd: cwd,
            session: session
        )
    }

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }
}

private struct PiEnvelope: Decodable {
    var toolName: String?
    var input: PiInput?
    var cwd: String?
    var sessionId: String?
}

private struct PiInput: Decodable {
    var command: String?
}
