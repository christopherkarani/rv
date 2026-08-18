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

    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    public func encodeDeny(reason: String) -> HookWire {
        HookWire(stdout: grokDenyLine(reason: reason), exitCode: 0)
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

private func grokDenyLine(reason: String) -> String {
    "{\"decision\":\"deny\",\"reason\":\(jsonQuoted(reason))}\n"
}

private func jsonQuoted(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"":
            output += "\\\""
        case "\\":
            output += "\\\\"
        case "\n":
            output += "\\n"
        case "\r":
            output += "\\r"
        case "\t":
            output += "\\t"
        default:
            if scalar.value < 0x20 {
                output += String(format: "\\u%04x", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
    }
    output += "\""
    return output
}
