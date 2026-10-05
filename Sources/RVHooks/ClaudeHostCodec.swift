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
        guard envelope.hookEventName == "PreToolUse" else {
            return .foreign
        }
        let cwd = envelope.cwd.flatMap { WorkingDirectory(validating: $0) }
        let session = firstNonEmpty(envelope.sessionId).flatMap { SessionID(validating: $0) }
        if envelope.toolName == "Bash" {
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
        return .foreign
    }

    /// Defaults must live here so one-argument `encodeDeny(reason:)` does not
    /// bind the protocol-extension leftover `decision: deny`.
    public func encodeDeny(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none
    ) -> HookWire {
        HookWire(
            stdout: claudeIndeterminateDenyJSON(reason: reason),
            exitCode: host.denyExitCode
        )
    }

    public func encodeEvaluatedDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint? = nil
    ) -> HookWire {
        switch result.decision {
        case .allow, .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny:
            return encodeRichDeny(from: result, command: command, unlockCode: unlockCode)
        }
    }

    /// Ask-denial keeps the rich shape (nested `permissionDecision` plus
    /// match fields). Guidance joins after the deny line so truncation
    /// cannot drop it. When the pending row failed to record, the guidance
    /// says so instead of promising RV approval (M-25).
    public func encodeEvaluatedAskDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint? = nil,
        askRecorded: Bool = true
    ) -> HookWire {
        switch result.decision {
        case .allow, .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            let hostDenyText =
                "\(hostDenyLine(command: command, reason: deny.reason, unlock: unlockCode)) \(askPendingLine(recorded: askRecorded))"
            guard case .deny(_, let matched?) = result.outcome else {
                return encodeDeny(
                    reason: hostDenyText,
                    rule: deny.ruleID,
                    next: unlockHookVoiceNext(unlockCode)
                )
            }
            return HookWire(
                stdout: claudeRichDenyJSON(
                    hostDenyText: hostDenyText,
                    match: matched
                ),
                exitCode: host.denyExitCode
            )
        }
    }

    public func encodeFileDeny(from result: EvaluationResult) -> HookWire {
        switch result.decision {
        case .allow:
            return encodeAllow()
        case .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            let reason = hostFileDenyLine(reason: deny.reason)
            guard case .deny(_, let matched?) = result.outcome else {
                return encodeDeny(reason: reason, rule: deny.ruleID, next: .none)
            }
            return HookWire(
                stdout: claudeRichDenyJSON(hostDenyText: reason, match: matched),
                exitCode: host.denyExitCode
            )
        }
    }

    public func encodeRichDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockMint? = nil
    ) -> HookWire {
        switch result.decision {
        case .allow:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            let hostDenyText = hostDenyLine(
                command: command,
                reason: deny.reason,
                unlock: unlockCode
            )
            guard case .deny(_, let matched?) = result.outcome else {
                return encodeDeny(
                    reason: hostDenyText,
                    rule: deny.ruleID,
                    next: unlockHookVoiceNext(unlockCode)
                )
            }
            return HookWire(
                stdout: claudeRichDenyJSON(
                    hostDenyText: hostDenyText,
                    match: matched
                ),
                exitCode: host.denyExitCode
            )
        }
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

    enum CodingKeys: String, CodingKey {
        case command
        case filePath = "file_path"
        case path
        case targetFile = "target_file"
        case target
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
