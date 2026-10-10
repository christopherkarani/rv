import Foundation
import RVDomain

/// Adapter wire for Antigravity CLI (`agy`), not a host protocol.
/// PreToolUse stdin is camelCase protojson with `toolCall: {name, args}` and no
/// event field; the adapter registers only under PreToolUse. Deny-only: exit 0
/// `decision: deny` JSON blocks even with `--dangerously-skip-permissions`.
public struct AntigravityHostCodec: HostCodec {
    public var host: HookHost { .antigravity }

    public init() {}

    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AntigravityEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard let toolCall = envelope.toolCall else {
            return .foreign
        }
        let cwdText = firstNonEmpty(
            toolCall.args?.cwd,
            envelope.workspacePaths?.first
        )
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.conversationId)
            .flatMap { SessionID(validating: $0) }
        if let name = toolCall.name,
           AntigravityToolName(wireValue: name).strictMatch == .shell {
            return HookRequest.decoded(
                host: .antigravity,
                command: toolCall.args?.commandLine,
                cwd: cwd,
                session: session
            )
        }
        let mappedFileTool = toolCall.name.flatMap {
            AntigravityToolName(wireValue: $0).fileKind?.ledgerName
        }
        if let file = FileToolAction.decoded(
            toolName: mappedFileTool,
            paths: toolCall.args?.targetFile, toolCall.args?.absolutePath
        ) {
            return HookRequest.decoded(
                host: .antigravity,
                command: nil,
                cwd: cwd,
                session: session,
                file: file
            )
        }
        return .foreign
    }

    /// Explicit allow JSON: empty stdout fails unmarshal and blocks.
    public func encodeAllow() -> HookWire {
        HookWire(stdout: hookDecisionAllowJSON(), exitCode: 0)
    }

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }

}

private struct AntigravityEnvelope: Decodable {
    var conversationId: String?
    var toolCall: AntigravityToolCall?
    var workspacePaths: [String]?

    enum CodingKeys: String, CodingKey {
        case conversationId
        case toolCall
        case workspacePaths
    }
}

private struct AntigravityToolCall: Decodable {
    var name: String?
    var args: AntigravityToolArgs?
}

private struct AntigravityToolArgs: Decodable {
    var commandLine: String?
    var cwd: String?
    var targetFile: String?
    var absolutePath: String?

    enum CodingKeys: String, CodingKey {
        case commandLine = "CommandLine"
        case cwd = "Cwd"
        case targetFile = "TargetFile"
        case absolutePath = "AbsolutePath"
    }
}
