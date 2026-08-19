import Foundation
import RVDomain

/// Adapter wire for OpenCode, not a host protocol.
public struct OpenCodeHostCodec: HostCodec {
    /// The OpenCode adapter host.
    public var host: HookHost { .opencode }

    /// Creates an OpenCode adapter codec.
    public init() {}

    /// Decodes adapter stdin; `command` is nil for non-bash or unreadable stdin.
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
}

private struct OpenCodeEnvelope: Decodable {
    var tool: String?
    var args: OpenCodeArgs?
}

private struct OpenCodeArgs: Decodable {
    var command: String?
}
