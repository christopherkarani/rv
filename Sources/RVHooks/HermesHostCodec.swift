import Foundation
import RVDomain

/// Adapter wire for Hermes, not a host protocol.
public struct HermesHostCodec: HostCodec {
    /// The Hermes adapter host.
    public var host: HookHost { .hermes }

    /// Creates a Hermes adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(HermesEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard envelope.toolName == "terminal" else {
            return .foreign
        }
        guard let command = envelope.args?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwdText = firstNonEmpty(envelope.args?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.taskId)
            .flatMap { SessionID(validating: $0) }
        return .request(
            HookRequest(
                host: .hermes,
                command: ShellCommand(rawValue: command),
                cwd: cwd,
                session: session
            )
        )
    }

}

private struct HermesEnvelope: Decodable {
    var toolName: String?
    var args: HermesArgs?
    var cwd: String?
    var sessionId: String?
    var taskId: String?
}

private struct HermesArgs: Decodable {
    var command: String?
    var workdir: String?
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}
