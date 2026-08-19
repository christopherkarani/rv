import Foundation
import RVDomain

public struct GrokHostCodec: HostCodec {
    public var host: HookHost { .grok }

    public init() {}

    public func decode(_ stdin: String) -> HookRequest {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(GrokEnvelope.self, from: data)
        else {
            return HookRequest(host: .grok, command: nil)
        }
        guard envelope.hookEventName == "pre_tool_use" else {
            return HookRequest(host: .grok, command: nil)
        }
        guard Self.shellTools.contains(envelope.toolName ?? "") else {
            return HookRequest(host: .grok, command: nil)
        }
        guard let command = envelope.toolInput?.command, command.isEmpty == false else {
            return HookRequest(host: .grok, command: nil)
        }
        return HookRequest(host: .grok, command: ShellCommand(rawValue: command))
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
}

private struct GrokToolInput: Decodable {
    var command: String?
}

