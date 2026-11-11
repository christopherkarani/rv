import Foundation
import RVDomain

/// Adapter wire for Muse Code (`muse`), not a host protocol.
///
/// Wire proven by live probe 2026-10-26
/// (`planning/muse-wire-probe-fixtures.md`): PreToolUse stdin is
/// `{hook_event_name, tool_name, tool_input, tool_use_id, …}`; the shell
/// tool is lowercase `bash` with `tool_input.command`. Deny is the
/// `hookSpecificOutput.permissionDecision` JSON + exit 0 — `decision:
/// block` is rejected on this event. v1 is shell-only: every non-shell
/// tool or event decodes `.foreign` (allow), never `.malformed`.
public struct MuseHostCodec: HostCodec {
    /// The Muse adapter host.
    public var host: HookHost { .muse }

    /// Creates a Muse adapter codec.
    public init() {}

    /// Guarded spellings; near-variants read as these (`HookWireName`).
    static let guardedTools = ["bash"]

    /// Decodes adapter stdin into a classified outcome.
    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = StrictHookJSON.screenedData(stdin),
              let envelope = try? JSONDecoder().decode(MuseEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard HookWireName.isPreToolEvent(envelope.hookEventName, preToolEvent: "PreToolUse") else {
            return .foreign
        }
        guard let toolName = HookWireName.canonical(envelope.toolName, among: Self.guardedTools),
              MuseToolName(wireValue: toolName).strictMatch == .shell
        else {
            return .foreign
        }
        let cwd = firstNonEmpty(envelope.cwd, envelope.toolInput?.workdir)
            .flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId, envelope.turnId)
            .flatMap { SessionID(validating: $0) }
        return HookRequest.decoded(
            host: .muse,
            command: envelope.toolInput?.command,
            cwd: cwd,
            session: session
        )
    }

    /// Muse honor path: `hookSpecificOutput.permissionDecision: deny`
    /// JSON + exit 0. The reason is required non-empty on the wire, so
    /// blank reasons fall back to `rv failed` inside the encoder.
    public func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire {
        HookWire(
            stdout: musePermissionDenyJSON(reason: presentation.reason),
            exitCode: host.denyExitCode
        )
    }
}

private struct MuseEnvelope: Decodable {
    var hookEventName: String?
    var toolName: String?
    var toolInput: MuseToolInput?
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

private struct MuseToolInput: Decodable {
    var command: String?
    var workdir: String?
}
