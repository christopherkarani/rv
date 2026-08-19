import Foundation
import RVDomain

public struct OpenCodeHostCodec: HostCodec {
    public var host: HookHost { .opencode }

    public init() {}

    public func decode(_ stdin: String) -> HookRequest {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OpenCodeEnvelope.self, from: data)
        else {
            return HookRequest(host: .opencode, command: nil)
        }
        guard envelope.tool == "bash" else {
            return HookRequest(host: .opencode, command: nil)
        }
        guard let command = envelope.args?.command, command.isEmpty == false else {
            return HookRequest(host: .opencode, command: nil)
        }
        return HookRequest(host: .opencode, command: ShellCommand(rawValue: command))
    }

    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    public func encodeDeny(reason: String) -> HookWire {
        HookWire(stdout: hookDenyJSON(reason: reason), exitCode: 1)
    }
}

private struct OpenCodeEnvelope: Decodable {
    var tool: String?
    var args: OpenCodeArgs?
}

private struct OpenCodeArgs: Decodable {
    var command: String?
}
