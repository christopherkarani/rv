import Foundation
import RVDomain

/// Adapter wire for OpenClaw, not a host protocol.
public struct OpenClawHostCodec: HostCodec {
    /// The OpenClaw adapter host.
    public var host: HookHost { .openclaw }

    /// Creates an OpenClaw adapter codec.
    public init() {}

    /// Guarded spellings; near-variants read as these (`HookWireName`).
    static let guardedTools = ["exec"]

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = StrictHookJSON.screenedData(stdin),
              let envelope = try? JSONDecoder().decode(OpenClawEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        if let toolKind = envelope.toolKind,
           OpenClawToolKind(wireValue: toolKind).isExcludedCodeMode {
            return .foreign
        }
        guard let toolName = HookWireName.canonical(envelope.toolName, among: Self.guardedTools),
              OpenClawToolName(wireValue: toolName).strictMatch == .shell
        else {
            return .foreign
        }
        let cwdText = firstNonEmpty(envelope.params?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.sessionKey)
            .flatMap { SessionID(validating: $0) }
        return HookRequest.decoded(
            host: .openclaw,
            command: envelope.params?.command,
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

private struct OpenClawEnvelope: Decodable {
    var toolName: String?
    var params: OpenClawParams?
    var cwd: String?
    var sessionId: String?
    var sessionKey: String?
    var toolKind: String?
}

private struct OpenClawParams: Decodable {
    var command: String?
    var workdir: String?
}
