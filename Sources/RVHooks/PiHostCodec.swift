import Foundation
import RVDomain

public struct PiHostCodec: HostCodec {
    public var host: HookHost { .pi }

    public init() {}

    public func decode(_ stdin: String) -> HookRequest {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PiEnvelope.self, from: data)
        else {
            return HookRequest(host: .pi, command: nil)
        }
        guard envelope.toolName == "bash" else {
            return HookRequest(host: .pi, command: nil)
        }
        guard let command = envelope.input?.command, command.isEmpty == false else {
            return HookRequest(host: .pi, command: nil)
        }
        return HookRequest(host: .pi, command: ShellCommand(rawValue: command))
    }

    public func encodeAllow() -> HookWire {
        HookWire(stdout: "", exitCode: 0)
    }

    public func encodeDeny(reason: String) -> HookWire {
        HookWire(stdout: hookDenyJSON(reason: reason), exitCode: 1)
    }
}

private struct PiEnvelope: Decodable {
    var toolName: String?
    var input: PiInput?
}

private struct PiInput: Decodable {
    var command: String?
}
