import Foundation
import RVDomain

/// Adapter wire for Pi, not a host protocol.
public struct PiHostCodec: HostCodec {
    /// The Pi adapter host.
    public var host: HookHost { .pi }

    /// Creates a Pi adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PiEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard envelope.toolName == "bash" else {
            return .foreign
        }
        guard let command = envelope.input?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        return .request(HookRequest(host: .pi, command: ShellCommand(rawValue: command)))
    }
}

private struct PiEnvelope: Decodable {
    var toolName: String?
    var input: PiInput?
}

private struct PiInput: Decodable {
    var command: String?
}
