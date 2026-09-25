import Foundation
import RVDomain

/// Adapter wire for OpenClaw, not a host protocol.
public struct OpenClawHostCodec: HostAskCodec {
    /// The OpenClaw adapter host.
    public var host: HookHost { .openclaw }

    /// Creates an OpenClaw adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OpenClawEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        if envelope.toolKind == "code_mode_exec" {
            return .foreign
        }
        guard envelope.toolName == "exec" else {
            return .foreign
        }
        let cwdText = firstNonEmpty(envelope.params?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.sessionKey)
            .flatMap { SessionID(validating: $0) }
        let hostAsk = envelope.hostAsk.flatMap(HostAskHookIntent.init(rawValue:))
        return HookRequest.decoded(
            host: .openclaw,
            cwd: cwd,
            session: session,
            payload: .shell(command: envelope.params?.command, ask: hostAsk)
        )
    }

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }

    public func encodeAsk(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionAsk(reason: reason, rule: rule, next: next)
    }
}

private struct OpenClawEnvelope: Decodable {
    var toolName: String?
    var params: OpenClawParams?
    var cwd: String?
    var sessionId: String?
    var sessionKey: String?
    var toolKind: String?
    var hostAsk: String?
}

private struct OpenClawParams: Decodable {
    var command: String?
    var workdir: String?
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}
