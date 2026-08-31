import Foundation
import RVDomain

/// Adapter wire for Codex, not a host protocol.
public struct CodexHostCodec: HostCodec {
    /// The Codex adapter host.
    public var host: HookHost { .codex }

    /// Creates a Codex adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard envelope.hookEventName == "PreToolUse" else {
            return .foreign
        }
        guard envelope.toolName == "Bash" else {
            return .foreign
        }
        guard let command = envelope.toolInput?.command, command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwdText = firstNonEmpty(envelope.toolInput?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.turnId)
        return .request(
            HookRequest(
                host: .codex,
                command: ShellCommand(rawValue: command),
                cwd: cwd,
                session: session
            )
        )
    }

    /// Official Codex honor path: older `decision: block` JSON + exit 2.
    /// Claude permission deny JSON is not a Codex TUI honor path.
    /// Defaults must live here: a one-argument `encodeDeny(reason:)` otherwise
    /// binds the protocol extension and emits leftover `decision: deny`.
    public func encodeDeny(reason: String, rule: String? = nil, next: String? = nil) -> HookWire {
        HookWire(
            stdout: hookBlockJSON(reason: reason),
            exitCode: host.denyExitCode,
            stderr: hookBlockStderr(reason: reason)
        )
    }

    /// Codex has no Ask. Leftover Ask continues the tool — same as deny.
    public func encodeAsk(reason: String, rule: String? = nil, next: String? = nil) -> HookWire {
        encodeDeny(reason: reason, rule: rule, next: next)
    }
}

private struct CodexEnvelope: Decodable {
    var hookEventName: String?
    var toolName: String?
    var toolInput: CodexToolInput?
    var cwd: String?
    var sessionId: String?
    var turnId: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case cwd
        case sessionId = "session_id"
        case turnId = "turn_id"
    }
}

private struct CodexToolInput: Decodable {
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
