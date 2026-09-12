import Foundation
import RVDomain

public struct GrokHostCodec: HostCodec {
    public var host: HookHost { .grok }

    public init() {}

    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(GrokEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard envelope.hookEventName == "pre_tool_use" else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId)
        if Self.shellTools.contains(envelope.toolName ?? "") {
            guard let command = envelope.toolInput?.command, command.isEmpty == false else {
                return .malformed(.missingCommand)
            }
            return .request(
                HookRequest(
                    host: .grok,
                    command: ShellCommand(rawValue: command),
                    cwd: cwd,
                    session: session
                )
            )
        }
        if let file = FileToolAction.decoded(
            toolName: envelope.toolName,
            paths: envelope.toolInput?.filePath,
            envelope.toolInput?.path,
            envelope.toolInput?.targetFile,
            envelope.toolInput?.target
        ) {
            return .request(
                HookRequest(
                    host: .grok,
                    command: ShellCommand(rawValue: ""),
                    cwd: cwd,
                    session: session,
                    file: file
                )
            )
        }
        return .foreign
    }

    private static let shellTools: Set<String> = [
        "run_terminal_command",
        "run_terminal_cmd",
        "Bash",
    ]

    public func encodeDeny(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }

    public func encodeAsk(reason: String, rule: RuleID? = nil, next: HookVoiceNext = .none) -> HookWire {
        encodeLeftoverDecisionAsk(reason: reason, rule: rule, next: next)
    }
}

private struct GrokEnvelope: Decodable {
    var hookEventName: String?
    var toolName: String?
    var toolInput: GrokToolInput?
    var cwd: String?
    var sessionId: String?
}

private struct GrokToolInput: Decodable {
    var command: String?
    var filePath: String?
    var path: String?
    var targetFile: String?
    var target: String?
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}

