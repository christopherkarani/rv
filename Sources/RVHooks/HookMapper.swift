import RVDomain

/// First-call vs post-spend encode. Product Ask is `HostAskVerdict`; codecs only encode.
public enum HookWireIntent: Sendable, Equatable {
    case firstCall(verdict: HostAskVerdict, unlockCode: String?)
    case afterSpend
}

/// Returns the host wire for `intent`.
///
/// First call switches `HostAskVerdict` once. Claude live deny is rich JSON;
/// other hosts use `encodeDeny`. Adapters honor `decision:ask` only.
/// Claude first-call Ask is short `{decision:ask}` for the wrapper. Official
/// `permissionDecision: "ask"` is leftover-ask-as-permit and is never emitted.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    intent: HookWireIntent
) -> HookWire {
    switch intent {
    case .afterSpend:
        return encodePostSpend(from: result, command: command, using: codec)
    case .firstCall(let verdict, let unlockCode):
        return encodeFirstCall(
            from: result,
            command: command,
            using: codec,
            verdict: verdict,
            unlockCode: unlockCode
        )
    }
}

/// Convenience: project `HostAskVerdict` then encode. Tests and leftover
/// `bound:` / `afterSpend:` call sites stay on this door.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview? = nil,
    cwd: WorkingDirectory? = nil,
    afterSpend: Bool = false,
    unlockCode: String? = nil
) -> HookWire {
    if afterSpend {
        return hookWire(from: result, command: command, using: codec, intent: .afterSpend)
    }
    let bound = bound ?? BoundReview.packProjected(from: result)
    let verdict = HostNativeAsk.verdict(
        host: codec.host,
        result: result,
        cwd: cwd,
        bound: bound
    )
    return hookWire(
        from: result,
        command: command,
        using: codec,
        intent: .firstCall(verdict: verdict, unlockCode: unlockCode)
    )
}

private func encodeFirstCall<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    verdict: HostAskVerdict,
    unlockCode: String?
) -> HookWire {
    switch verdict {
    case .allow:
        switch result.decision {
        case .allow:
            return codec.encodeAllow()
        case .deny, .indeterminate:
            return encodeLiveDeny(
                from: result,
                command: command,
                using: codec,
                unlockCode: unlockCode
            )
        }
    case .ask:
        return encodeAsked(from: result, command: command, using: codec)
    case .deny:
        return encodeLiveDeny(
            from: result,
            command: command,
            using: codec,
            unlockCode: unlockCode
        )
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
            rule: deny.ruleID,
            next: .none
        )
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    }
}

private func encodeLiveDeny<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    unlockCode: String?
) -> HookWire {
    switch result.decision {
    case .allow:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    case .deny(let deny):
        if codec.host == .claude {
            return ClaudeHostCodec().encodeRichDeny(
                from: result,
                command: command,
                unlockCode: unlockCode
            )
        }
        return codec.encodeDeny(
            reason: hostDenyLine(command: command, reason: deny.reason, unlockCode: unlockCode),
            rule: deny.ruleID,
            next: unlockHookVoiceNext(unlockCode)
        )
    }
}

private func encodeAsked<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C
) -> HookWire {
    switch BoundReview.packProjected(from: result) {
    case .deny(let deny), .mandatoryHuman(let deny):
        return codec.encodeAsk(
            reason: hostAskLine(command: command, ruleID: deny.ruleID),
            rule: deny.ruleID,
            next: .ttyHint
        )
    case .allow:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    }
}
