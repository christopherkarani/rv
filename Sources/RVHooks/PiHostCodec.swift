import Foundation
import RVDomain

/// Adapter wire for Pi, not a host protocol.
public struct PiHostCodec: HostCodec {
    /// The Pi adapter host.
    public var host: HookHost { .pi }

    /// Creates a Pi adapter codec.
    public init() {}

    /// Guarded spellings; near-variants read as these (`HookWireName`).
    static let guardedTools = ["bash"]

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = StrictHookJSON.screenedData(stdin),
              let envelope = try? JSONDecoder().decode(PiEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard let toolName = HookWireName.canonical(envelope.toolName, among: Self.guardedTools),
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

    public func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire {
        encodeLeftoverDecisionDeny(
            reason: presentation.reason,
            rule: presentation.rule,
            next: presentation.next
        )
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
