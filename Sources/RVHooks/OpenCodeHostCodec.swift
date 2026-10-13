import Foundation
import RVDomain

/// Adapter wire for OpenCode, not a host protocol.
public struct OpenCodeHostCodec: HostCodec {
    /// The OpenCode adapter host.
    public var host: HookHost { .opencode }

    /// Creates an OpenCode adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OpenCodeEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard let tool = envelope.tool,
              OpenCodeToolName(wireValue: tool).strictMatch == .shell
        else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionID, envelope.sessionId)
            .flatMap { SessionID(validating: $0) }
        return HookRequest.decoded(
            host: .opencode,
            command: envelope.args?.command,
            cwd: cwd,
            session: session
        )
    }

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }
}

private struct OpenCodeEnvelope: Decodable {
    var tool: String?
    var args: OpenCodeArgs?
    var cwd: String?
    var sessionID: String?
    var sessionId: String?
}

private struct OpenCodeArgs: Decodable {
    var command: String?
}
