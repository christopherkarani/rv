import RVDomain

/// Returns Claude rich deny wire from `result`; allow uses `encodeAllow`.
public func hookWire(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: ClaudeHostCodec
) -> HookWire {
    codec.encodeRichDeny(from: result, command: command)
}

/// Returns the host wire for `result`: allow uses `encodeAllow`; deny and indeterminate use `encodeDeny`.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C
) -> HookWire {
    if let claude = codec as? ClaudeHostCodec {
        return claude.encodeRichDeny(from: result, command: command)
    }
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
