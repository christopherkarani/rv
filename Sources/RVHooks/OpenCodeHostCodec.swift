import Foundation
import RVDomain

/// Adapter wire for OpenCode, not a host protocol.
public struct OpenCodeHostCodec: HostCodec {
    /// The OpenCode adapter host.
    public var host: HookHost { .opencode }

    /// Creates an OpenCode adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OpenCodeEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard let tool = envelope.tool, isOpenCodeShellTool(tool) else {
            return .foreign
        }
        guard let command = envelope.args?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionID, envelope.sessionId)
            .flatMap { SessionID(validating: $0) }
        let hostAsk = envelope.hostAsk.flatMap(HostAskHookIntent.init(rawValue:))
        return .request(
            HookRequest(
                host: .opencode,
                command: ShellCommand(rawValue: command),
                cwd: cwd,
                session: session,
                hostAsk: hostAsk
            )
        )
    }
}

/// Official agent tool id is `bash`. TUI `session.shell` is the same shell door.
private func isOpenCodeShellTool(_ tool: String) -> Bool {
    tool == "bash" || tool == "session.shell"
}

private struct OpenCodeEnvelope: Decodable {
    var tool: String?
    var args: OpenCodeArgs?
    var cwd: String?
    var hostAsk: String?
    var sessionID: String?
    var sessionId: String?
}

private struct OpenCodeArgs: Decodable {
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
