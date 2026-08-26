import RVDomain

/// Returns the host wire for `result`: allow uses `encodeAllow`; deny and indeterminate use `encodeDeny`.
/// Claude is the only rich encoder; Grok / Pi / OpenCode stay on short `encodeDeny`.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C
) -> HookWire {
    switch codec.host {
    case .claude:
        return ClaudeHostCodec().encodeRichDeny(from: result, command: command)
    case .grok, .pi, .opencode, .openclaw, .hermes:
        switch result.decision {
        case .allow:
            return codec.encodeAllow()
        case .deny(let deny):
            return codec.encodeDeny(
                reason: hostDenyLine(command: command, ruleID: deny.ruleID),
                rule: displayRuleID(deny.ruleID),
                next: hookUnlockNext
            )
        case .indeterminate:
            return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
        }
    }
}
