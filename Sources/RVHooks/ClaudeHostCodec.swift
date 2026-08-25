import Foundation
import RVDomain

public struct ClaudeHostCodec: HostCodec {
    public var host: HookHost { .claude }

    public init() {}

    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard envelope.hookEventName == "PreToolUse" else {
            return .foreign
        }
        guard envelope.toolName == "Bash" else {
            return .foreign
        }
        guard let command = envelope.toolInput?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        return .request(HookRequest(host: .claude, command: ShellCommand(rawValue: command), cwd: cwd))
    }

    public func encodeDeny(reason: String, rule: String?, next: String?) -> HookWire {
        HookWire(
            stdout: claudeIndeterminateDenyJSON(reason: reason),
            exitCode: host.denyExitCode
        )
    }

    public func encodeRichDeny(from result: EvaluationResult, command: ShellCommand) -> HookWire {
        switch result.decision {
        case .allow:
            return encodeAllow()
        case .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
        case .deny(let deny):
            let hostDenyText = hostDenyLine(command: command, ruleID: deny.ruleID)
            guard case .deny(_, let matched?) = result.outcome else {
                return encodeDeny(reason: hostDenyText, rule: nil, next: nil)
            }
            return HookWire(
                stdout: claudeRichDenyJSON(
                    hostDenyText: hostDenyText,
                    match: matched,
                    command: command
                ),
                exitCode: host.denyExitCode
            )
        }
    }
}

private struct ClaudeEnvelope: Decodable {
    var hookEventName: String?
    var toolName: String?
    var toolInput: ClaudeToolInput?
    var cwd: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case cwd
    }
}

private struct ClaudeToolInput: Decodable {
    var command: String?
}
