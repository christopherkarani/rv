import Foundation
import RVDomain

public struct GrokHostCodec: HostCodec {
    public var host: HookHost { .grok }

    public init() {}

    /// Guarded spellings; near-variants read as these (`HookWireName`).
    static let guardedTools = ["run_terminal_command", "run_terminal_cmd", "Bash"] + HookWireName.fileTools

    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = StrictHookJSON.screenedData(stdin),
              let envelope = try? JSONDecoder().decode(GrokEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard HookWireName.isPreToolEvent(envelope.hookEventName, preToolEvent: "pre_tool_use") else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId).flatMap { SessionID(validating: $0) }
        let toolName = HookWireName.canonical(envelope.toolName, among: Self.guardedTools)
        if let toolName,
           GrokToolName(wireValue: toolName).strictMatch == .shell {
            return HookRequest.decoded(
                host: .grok,
                command: envelope.toolInput?.command,
                cwd: cwd,
                session: session
            )
        }
        if let file = FileToolAction.make(
            toolName: toolName,
            filePath: envelope.toolInput?.filePath,
            path: envelope.toolInput?.path,
            targetFile: envelope.toolInput?.targetFile,
            target: envelope.toolInput?.target
        ) {
            return HookRequest.decoded(
                host: .grok,
                command: nil,
                cwd: cwd,
                session: session,
                file: file
            )
        }
        return .foreign
    }

    public func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire {
        encodeLeftoverDecisionDeny(
            reason: presentation.reason,
            rule: presentation.rule,
            next: presentation.next
        )
    }
}

private struct GrokEnvelope: Decodable {
    var hookEventName: String?
    var toolName: String?
    var toolInput: GrokToolInput?
    var cwd: String?
    var sessionId: String?
}

private struct GrokToolInput: Decodable {
    var command: String?
    var filePath: String?
    var path: String?
    var targetFile: String?
    var target: String?

    enum CodingKeys: String, CodingKey {
        case command
        case filePath = "file_path"
        case path
        case targetFile = "target_file"
        case target
    }
}
