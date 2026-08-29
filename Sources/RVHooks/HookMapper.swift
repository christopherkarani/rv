import RVDomain

/// Returns the host wire for `result`: allow uses `encodeAllow`; deny and indeterminate use `encodeDeny`.
/// Claude is the only rich encoder; Grok / Pi / OpenCode stay on short `encodeDeny`.
/// Codex live deny is official older `decision: block` + exit 2, not Claude permission deny.
/// Product Ask pauses only when `HostNativeAsk.verdict(host:result:cwd:bound:)`
/// returns `.ask` (spend-first host, unlockable pack deny or `mandatoryHuman`,
/// cwd + nonempty matching view). Adapters honor `decision:ask` only.
/// Claude first-call official ask is leftover-ask-as-permit and is never emitted.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview? = nil,
    cwd: WorkingDirectory? = nil,
    afterSpend: Bool = false
) -> HookWire {
    switch codec.host {
    case .claude:
        if afterSpend {
            return encodePostSpend(from: result, command: command, using: codec)
        }
        // Official `permissionDecision: "ask"` is leftover-ask-as-permit. Stay deny.
        return encodeClaudeFirstCall(from: result, command: command, using: codec, bound: bound)
    case .grok, .pi, .opencode, .openclaw, .hermes, .codex, .cursor:
        if afterSpend {
            return encodePostSpend(from: result, command: command, using: codec)
        }
        return encodeFirstCall(
            from: result,
            command: command,
            using: codec,
            bound: bound,
            cwd: cwd
        )
    }
}

private func encodeClaudeFirstCall<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview?
) -> HookWire {
    switch result.decision {
    case .allow:
        guard let bound else {
            return ClaudeHostCodec().encodeRichDeny(from: result, command: command)
        }
        switch bound {
        case .allow:
            return codec.encodeAllow()
        case .deny(let deny), .mandatoryHuman(let deny):
            return codec.encodeDeny(
                reason: hostDenyLine(command: command, reason: deny.reason),
                rule: displayRuleID(deny.ruleID),
                next: hookUnlockNext
            )
        }
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
    case .deny:
        return ClaudeHostCodec().encodeRichDeny(from: result, command: command)
    }
}

private func encodePostSpend<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C
) -> HookWire {
    switch result.decision {
    case .allow:
        return codec.encodeAllow()
    case .deny(let deny):
        return codec.encodeDeny(
            reason: hostDenyLine(command: command, reason: deny.reason),
            rule: displayRuleID(deny.ruleID),
            next: nil
        )
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
    }
}

private func encodeFirstCall<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview?,
    cwd: WorkingDirectory?
) -> HookWire {
    switch result.decision {
    case .allow:
        let bound = bound ?? .allow
        switch HostNativeAsk.verdict(
            host: codec.host,
            result: result,
            cwd: cwd,
            bound: bound
        ) {
        case .allow:
            return codec.encodeAllow()
        case .deny:
            switch bound {
            case .deny(let deny), .mandatoryHuman(let deny):
                return codec.encodeDeny(
                    reason: hostDenyLine(command: command, reason: deny.reason),
                    rule: displayRuleID(deny.ruleID),
                    next: hookUnlockNext
                )
            case .allow:
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
            }
        case .ask:
            return encodeAsked(from: bound, command: command, using: codec)
        }
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
    case .deny(let deny):
        let bound = bound ?? .deny(deny)
        switch HostNativeAsk.verdict(
            host: codec.host,
            result: result,
            cwd: cwd,
            bound: bound
        ) {
        case .allow, .deny:
            // A deny result must never become silent allow.
            return codec.encodeDeny(
                reason: hostDenyLine(command: command, reason: deny.reason),
                rule: displayRuleID(deny.ruleID),
                next: nil
            )
        case .ask:
            return encodeAsked(from: bound, command: command, using: codec)
        }
    }
}

private func encodeAsked<C: HostCodec>(
    from bound: BoundReview,
    command: ShellCommand,
    using codec: C
) -> HookWire {
    switch bound {
    case .deny(let deny), .mandatoryHuman(let deny):
        return codec.encodeAsk(
            reason: hostAskLine(command: command, ruleID: deny.ruleID),
            rule: displayRuleID(deny.ruleID),
            next: hookUnlockNext
        )
    case .allow:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
    }
}
