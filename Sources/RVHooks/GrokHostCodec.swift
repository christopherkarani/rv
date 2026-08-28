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
        guard Self.shellTools.contains(envelope.toolName ?? "") else {
            return .foreign
        }
        guard let command = envelope.toolInput?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId)
        return .request(
            HookRequest(
                host: .grok,
                command: ShellCommand(rawValue: command),
                cwd: cwd,
                session: session
            )
        )
    }

    private static let shellTools: Set<String> = [
        "run_terminal_command",
        "run_terminal_cmd",
        "Bash",
    ]
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
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}

