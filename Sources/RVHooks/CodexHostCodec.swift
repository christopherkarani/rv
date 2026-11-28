import Foundation
import RVDomain

/// Adapter wire for Codex, not a host protocol.
public struct CodexHostCodec: HostCodec {
    /// The Codex adapter host.
    public var host: HookHost { .codex }

    /// Creates a Codex adapter codec.
    public init() {}

    /// B4: house rules ride this event's `additionalContext`.
    static let sessionStartEvent = "SessionStart"

    /// Session-start context (`additionalContext`), exit 0.
    public func encodeHouseRules(_ text: String) -> HookWire {
        HookWire(stdout: sessionStartContextJSON(text), exitCode: 0)
    }

    /// Guarded spellings; near-variants read as these (`HookWireName`).
    static let guardedTools = ["Bash"]

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = StrictHookJSON.screenedData(stdin),
              let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        if HookWireName.isEvent(envelope.hookEventName, named: Self.sessionStartEvent) {
            return .sessionStart(cwd: envelope.cwd.flatMap { WorkingDirectory(validating: $0) })
        }
        guard HookWireName.isPreToolEvent(envelope.hookEventName, preToolEvent: "PreToolUse") else {
            return .foreign
        }
        guard let toolName = HookWireName.canonical(envelope.toolName, among: Self.guardedTools),
              CodexToolName(wireValue: toolName).strictMatch == .shell
        else {
            return .foreign
        }
        let cwdText = firstNonEmpty(envelope.toolInput?.workdir, envelope.cwd)
        let cwd = cwdText.flatMap { WorkingDirectory(validating: $0) }
        // A turn id is not a session: it may key a pending approval when
        // Codex sent no session id, but never names one on a block row.
        let session = firstNonEmpty(envelope.sessionId).flatMap { SessionID(validating: $0) }
        let turn = firstNonEmpty(envelope.turnId).flatMap { SessionID(validating: $0) }
        return HookRequest.decoded(
            host: .codex,
            command: envelope.toolInput?.command,
            cwd: cwd,
            session: session,
            approvalSession: turn
        )
    }

    /// Official Codex honor path: older `decision: block` JSON + exit 2.
    /// Claude permission deny JSON is not a Codex TUI honor path.
    public func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire {
        HookWire(
            stdout: hookBlockJSON(reason: presentation.reason),
            exitCode: host.denyExitCode,
            stderr: hookBlockStderr(reason: presentation.reason)
        )
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
