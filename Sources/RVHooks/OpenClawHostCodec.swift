import Foundation
import RVDomain

/// Adapter wire for OpenClaw, not a host protocol.
public struct OpenClawHostCodec: HostCodec {
    /// The OpenClaw adapter host.
    public var host: HookHost { .openclaw }

    /// Creates an OpenClaw adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OpenClawEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        if envelope.toolKind == "code_mode_exec" {
            return .foreign
        }
        guard envelope.toolName == "exec" else {
            return .foreign
        }
        guard let command = envelope.params?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwdText = firstNonEmpty(envelope.params?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.sessionKey)
        return .request(
            HookRequest(
                host: .openclaw,
                command: ShellCommand(rawValue: command),
                cwd: cwd,
                session: session
            )
        )
    }

    /// Maps a decoded OpenClaw request to `ProposedAction.shell`.
    /// Session and cwd stay on the request and in the fingerprint until IR owns construction.
    public func proposedAction(from request: HookRequest) -> ProposedAction {
        let fingerprint = ActionFingerprint(
            rawValue: "openclaw:\(request.session ?? ""):\(request.cwd?.rawValue ?? ""):\(request.command.rawValue)"
        )
        return .shell(
            ShellAction(
                fingerprint: fingerprint,
                scope: ActionScope(workingDirectory: request.cwd),
                supportingCommand: request.command
            )
        )
    }
}

private struct OpenClawEnvelope: Decodable {
    var toolName: String?
    var params: OpenClawParams?
    var cwd: String?
    var sessionId: String?
    var sessionKey: String?
    var toolKind: String?
}

private struct OpenClawParams: Decodable {
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
