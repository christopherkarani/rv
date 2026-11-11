import Foundation
import RVDomain

/// Adapter wire for Hermes, not a host protocol.
public struct HermesHostCodec: HostCodec {
    /// The Hermes adapter host.
    public var host: HookHost { .hermes }

    /// Creates a Hermes adapter codec.
    public init() {}

    /// Guarded spellings; near-variants read as these (`HookWireName`).
    static let guardedTools = ["terminal"]

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = StrictHookJSON.screenedData(stdin),
              let envelope = try? JSONDecoder().decode(HermesEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard let toolName = HookWireName.canonical(envelope.toolName, among: Self.guardedTools),
              HermesToolName(wireValue: toolName).strictMatch == .shell
        else {
            return .foreign
        }
        let cwdText = firstNonEmpty(envelope.args?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.taskId)
            .flatMap { SessionID(validating: $0) }
        return HookRequest.decoded(
            host: .hermes,
            command: envelope.args?.command,
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

private struct HermesEnvelope: Decodable {
    var toolName: String?
    var args: HermesArgs?
    var cwd: String?
    var sessionId: String?
    var taskId: String?
}

private struct HermesArgs: Decodable {
    var command: String?
    var workdir: String?
}
