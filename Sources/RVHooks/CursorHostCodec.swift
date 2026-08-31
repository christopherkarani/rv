import Foundation
import RVDomain

/// Adapter wire for Cursor, not a host protocol.
public struct CursorHostCodec: HostCodec {
    /// The Cursor adapter host.
    public var host: HookHost { .cursor }

    /// Creates a Cursor adapter codec.
    public init() {}

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CursorEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        switch classify(envelope) {
        case .foreign:
            return .foreign
        case .shell:
            break
        }
        guard let command = shellCommand(in: envelope), command.isEmpty == false else {
            return .malformed(.missingCommand)
        }
        let cwdText = firstNonEmpty(
            envelope.toolInput?.workingDirectory,
            envelope.cwd,
            envelope.workspaceRoots?.first
        )
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(
            envelope.conversationId,
            envelope.sessionId,
            envelope.generationId
        )
        return .request(
            HookRequest(
                host: .cursor,
                command: ShellCommand(rawValue: command),
                cwd: cwd,
                session: session
            )
        )
    }

    /// Official Cursor honor path: `permission: allow` JSON + exit 0.
    /// Empty stdout + `failClosed: true` would block a harmless command.
    public func encodeAllow() -> HookWire {
        HookWire(stdout: hookPermissionAllowJSON(), exitCode: 0)
    }

    /// Official Cursor honor path: `permission: deny` + messages + exit 0.
    /// Claude permission deny and Codex `decision: block` are not this wire.
    /// Defaults must live here so one-argument `encodeDeny(reason:)` does not
    /// bind the protocol-extension leftover `decision: deny`.
    public func encodeDeny(reason: String, rule: String? = nil, next: String? = nil) -> HookWire {
        HookWire(
            stdout: hookPermissionDenyJSON(reason: reason),
            exitCode: host.denyExitCode
        )
    }

    /// Cursor has no Ask. Leftover `permission: ask` is leftover-ask-as-permit.
    public func encodeAsk(reason: String, rule: String? = nil, next: String? = nil) -> HookWire {
        encodeDeny(reason: reason, rule: rule, next: next)
    }
}

private enum CursorEventClass {
    case shell
    case foreign
}

private func classify(_ envelope: CursorEnvelope) -> CursorEventClass {
    let event = envelope.hookEventName ?? ""
    if event == "beforeShellExecution" || event.isEmpty {
        return .shell
    }
    if event == "preToolUse" {
        let tool = envelope.toolName ?? ""
        if tool == "Shell" || tool == "Bash" {
            return .shell
        }
        return .foreign
    }
    return .foreign
}

private func shellCommand(in envelope: CursorEnvelope) -> String? {
    let event = envelope.hookEventName ?? ""
    if event == "preToolUse" {
        return firstNonEmpty(envelope.toolInput?.command)
    }
    return firstNonEmpty(envelope.command, envelope.toolInput?.command)
}

private struct CursorEnvelope: Decodable {
    var hookEventName: String?
    var command: String?
    var cwd: String?
    var conversationId: String?
    var sessionId: String?
    var generationId: String?
    var toolName: String?
    var toolInput: CursorToolInput?
    var workspaceRoots: [String]?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case command
        case cwd
        case conversationId = "conversation_id"
        case sessionId = "session_id"
        case generationId = "generation_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case workspaceRoots = "workspace_roots"
    }
}

private struct CursorToolInput: Decodable {
    var command: String?
    var workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case command
        case workingDirectory = "working_directory"
    }
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}
