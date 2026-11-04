import Foundation
import RVDomain

public struct ClaudeHostCodec: HostCodec {
    public var host: HookHost { .claude }

    public init() {}

    public func decode(_ stdin: String) -> HookDecodeOutcome {
        guard let data = stdin.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data)
        else {
            return .malformed(.unreadable)
        }
        guard let eventName = envelope.hookEventName,
              ClaudeEventName(wireValue: eventName).strictMatch
        else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId).flatMap { SessionID(validating: $0) }
        if let toolName = envelope.toolName,
           ClaudeToolName(wireValue: toolName).strictMatch == .shell {
            return HookRequest.decoded(
                host: .claude,
                command: envelope.toolInput?.command,
                cwd: cwd,
                session: session
            )
        }
        if let file = FileToolAction.make(
            toolName: envelope.toolName,
            filePath: envelope.toolInput?.filePath,
            path: envelope.toolInput?.path,
            targetFile: envelope.toolInput?.targetFile,
            target: envelope.toolInput?.target
        ) {
            return HookRequest.decoded(
                host: .claude,
                command: nil,
                cwd: cwd,
                session: session,
                file: file
            )
        }
        if let search = ClaudeSearchTarget.action(
            toolName: envelope.toolName,
            input: envelope.toolInput?.searchInput ?? ClaudeSearchInput()
        ) {
            return HookRequest.decoded(
                host: .claude,
                command: nil,
                cwd: cwd,
                session: session,
                file: search
            )
        }
        return .foreign
    }

    /// Rich JSON (nested `permissionDecision` plus match fields) only
    /// when the presentation carries a matched rule; plain deny JSON
    /// otherwise (REQ-T4).
    public func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire {
        if let matched = presentation.matched {
            return HookWire(
                stdout: claudeRichDenyJSON(
                    hostDenyText: presentation.reason,
                    match: matched
                ),
                exitCode: host.denyExitCode
            )
        }
        return HookWire(
            stdout: claudeIndeterminateDenyJSON(reason: presentation.reason),
            exitCode: host.denyExitCode
        )
    }
}

private struct ClaudeEnvelope: Decodable {
    var hookEventName: String?
    var toolName: String?
    var toolInput: ClaudeToolInput?
    var cwd: String?
    var sessionId: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case cwd
        case sessionId = "session_id"
    }
}

private struct ClaudeToolInput: Decodable {
    var command: String?
    var filePath: String?
    var path: String?
    var targetFile: String?
    var target: String?
    var notebookPath: String?
    var pattern: String?
    var glob: String?

    var searchInput: ClaudeSearchInput {
        ClaudeSearchInput(
            path: path,
            pattern: pattern,
            glob: glob,
            notebookPath: notebookPath,
            filePath: filePath
        )
    }

    enum CodingKeys: String, CodingKey {
        case notebookPath = "notebook_path"
        case pattern
        case glob
        case command
        case filePath = "file_path"
        case path
        case targetFile = "target_file"
        case target
    }
}
