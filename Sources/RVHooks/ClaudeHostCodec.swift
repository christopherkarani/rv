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
        let session = firstNonEmpty(envelope.sessionId)
        let hostAsk = envelope.hostAsk.flatMap(HostAskHookIntent.init(rawValue:))
        if envelope.toolName == "Bash" {
            guard let command = envelope.toolInput?.command, command.isEmpty == false else {
                return .malformed(.missingCommand)
            }
            return .request(
                HookRequest(
                    host: .claude,
                    command: ShellCommand(rawValue: command),
                    cwd: cwd,
                    session: session,
                    hostAsk: hostAsk
                )
            )
        }
        if let file = FileToolAction.decoded(
            toolName: envelope.toolName,
            paths: envelope.toolInput?.filePath,
            envelope.toolInput?.path,
            envelope.toolInput?.targetFile,
            envelope.toolInput?.target
        ) {
            return .request(
                HookRequest(
                    host: .claude,
                    command: ShellCommand(rawValue: ""),
                    cwd: cwd,
                    session: session,
                    hostAsk: hostAsk,
                    file: file
                )
            )
        }
        return .foreign
    }

    /// Short `{decision:ask,continuation:hostNative}` for the PreToolUse wrapper.
    /// Official `permissionDecision: "ask"` is leftover-ask-as-permit. Never emit it.
    /// Exit 2 (not Claude's deny-honor 0): leftover `rv hook --host claude` must
    /// block instead of fail-opening schema-invalid JSON. The wrapper maps
    /// nonempty `decision:ask` regardless of exit.
    /// Defaults must live here so one-argument `encodeAsk(reason:)` does not
    /// bind the protocol-extension leftover `decision: ask` at exit `denyExitCode`.
    public func encodeAsk(
        reason: String,
        rule: RuleID? = nil,
        next: HookVoiceNext = .none
    ) -> HookWire {
        HookWire(
            stdout: hookAskJSON(
                reason: reason,
                rule: rule.map(displayRuleID),
                next: hookVoiceNextSentence(next)
            ),
            exitCode: 2
        )
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

    public func encodeRichDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: String? = nil
    ) -> HookWire {
        switch result.decision {
        case .allow:
            return encodeAllow()
        case .indeterminate:
            return encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
        case .deny(let deny):
            let hostDenyText = hostDenyLine(
                command: command,
                reason: deny.reason,
                unlockCode: unlockCode
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
    var hostAsk: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case cwd
        case sessionId = "session_id"
        case hostAsk
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
