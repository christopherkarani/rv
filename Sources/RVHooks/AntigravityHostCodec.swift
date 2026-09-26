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
        if toolCall.name == "run_command" {
            return HookRequest.decoded(
                host: .antigravity,
                command: toolCall.args?.commandLine,
                cwd: cwd,
                session: session
            )
        }
        if let file = FileToolAction.decoded(
            toolName: ledgerName(for: toolCall.name),
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
        HookWire(stdout: hookAllowJSON(), exitCode: 0)
    }

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }
}

/// Antigravity file-tool names onto the closed ledger kinds.
private func ledgerName(for toolName: String?) -> String? {
    switch toolName {
    case "view_file":
        "Read"
    case "replace_file_content", "multi_replace_file_content":
        "Edit"
    case "write_to_file":
        "Write"
    default:
        nil
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

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}
