import RVDomain

/// First-call vs post-spend encode. Product Ask is `HostAskVerdict`; codecs only encode.
public enum HookWireIntent: Sendable, Equatable {
    case firstCall(verdict: HostAskVerdict, unlockCode: AllowOnceUnlockCode?)
    case afterSpend
}

/// Returns the host wire for `intent`.
///
/// First call switches `HostAskVerdict` once. Live deny is
/// `encodeEvaluatedDeny`. Adapters honor `decision:ask` only.
/// Claude first-call Ask is short `{decision:ask}` for the wrapper. Official
/// `permissionDecision: "ask"` is leftover-ask-as-permit and is never emitted.
/// Ask JSON is this `HostAskCodec` overload only.
public func hookWire<C: HostAskCodec>(
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

/// Deny-only first call. A leftover `.ask` verdict is live deny, not Ask JSON.
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

/// Convenience: project `HostAskVerdict` then encode `.firstCall`.
/// Spend vs first-call is `hookWire(..., intent: HookWireIntent)` only.
public func hookWire<C: HostAskCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview? = nil,
    cwd: WorkingDirectory? = nil
) -> HookWire {
    hookWire(
        from: result,
        command: command,
        using: codec,
        intent: firstCallIntent(
            from: result,
            host: codec.host,
            bound: bound,
            cwd: cwd
        )
    )
}

/// Convenience for deny-only codecs. Leftover `.ask` is live deny.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview? = nil,
    cwd: WorkingDirectory? = nil
) -> HookWire {
    hookWire(
        from: result,
        command: command,
        using: codec,
        intent: firstCallIntent(
            from: result,
            host: codec.host,
            bound: bound,
            cwd: cwd
        )
    )
}

private func firstCallIntent(
    from result: EvaluationResult,
    host: HookHost,
    bound: BoundReview?,
    cwd: WorkingDirectory?
) -> HookWireIntent {
    let bound = bound ?? BoundReview.packProjected(from: result)
    let verdict = HostNativeAsk.hostAskVerdict(
        host: host,
        result: result,
        cwd: cwd,
        bound: bound
    )
    return .firstCall(verdict: verdict, unlockCode: nil)
}

private func encodeFirstCall<C: HostAskCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    verdict: HostAskVerdict,
    unlockCode: AllowOnceUnlockCode?
) -> HookWire {
    switch verdict {
    case .allow:
        // HostAskVerdict is the wire decision. Deny-or-TTY maps
        // `mandatoryHuman` to allow while EvaluationResult may still be deny.
        return codec.encodeAllow()
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

private func encodeFirstCall<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    verdict: HostAskVerdict,
    unlockCode: AllowOnceUnlockCode?
) -> HookWire {
    switch verdict {
    case .allow:
        return codec.encodeAllow()
    case .ask:
        return encodeLiveDeny(
            from: result,
            command: command,
            using: codec,
            unlockCode: nil
        )
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
    unlockCode: AllowOnceUnlockCode?
) -> HookWire {
    codec.encodeEvaluatedDeny(
        from: result,
        command: command,
        unlockCode: unlockCode
    )
}

private func encodeAsked<C: HostAskCodec>(
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
