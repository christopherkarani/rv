import RVDomain

/// First-call always carries a `BoundReview`. Post-spend cannot pass an unlock
/// code and never encodes Ask.
public enum HookEncodePhase: Sendable, Equatable {
    case firstCall(bound: BoundReview, cwd: WorkingDirectory?, unlockCode: String?)
    case postSpend
}

/// Returns the host wire for `result`: allow uses `encodeAllow`; deny and indeterminate use `encodeDeny`.
/// Claude is the only rich encoder; Grok / Pi / OpenCode stay on short `encodeDeny`.
/// Codex live deny is official older `decision: block` + exit 2, not Claude permission deny.
/// Product Ask pauses only when `HostNativeAsk.verdict(host:result:cwd:bound:)`
/// returns `.ask` (spend-first host, unlockable pack deny or `mandatoryHuman`,
/// cwd + nonempty matching view). Adapters honor `decision:ask` only.
/// Claude first-call Ask is short `{decision:ask}` for the wrapper. Official
/// `permissionDecision: "ask"` is leftover-ask-as-permit and is never emitted.
public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    phase: HookEncodePhase
) -> HookWire {
    switch phase {
    case .postSpend:
        return encodePostSpend(from: result, command: command, using: codec)
    case .firstCall(let bound, let cwd, let unlockCode):
        switch codec.host {
        case .claude:
            return encodeClaudeFirstCall(
                from: result,
                command: command,
                using: codec,
                bound: bound,
                cwd: cwd,
                unlockCode: unlockCode
            )
        case .grok, .pi, .opencode, .openclaw, .hermes, .codex, .cursor:
            return encodeFirstCall(
                from: result,
                command: command,
                using: codec,
                bound: bound,
                cwd: cwd,
                unlockCode: unlockCode
            )
        }
    }
}

public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview,
    cwd: WorkingDirectory? = nil,
    unlockCode: String? = nil
) -> HookWire {
    hookWire(
        from: result,
        command: command,
        using: codec,
        phase: .firstCall(bound: bound, cwd: cwd, unlockCode: unlockCode)
    )
}

public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    cwd: WorkingDirectory? = nil,
    unlockCode: String? = nil
) -> HookWire {
    hookWire(
        from: result,
        command: command,
        using: codec,
        phase: .firstCall(
            bound: HostNativeAsk.bound(from: result),
            cwd: cwd,
            unlockCode: unlockCode
        )
    )
}

private func encodeClaudeFirstCall<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview,
    cwd: WorkingDirectory?,
    unlockCode: String?
) -> HookWire {
    switch result.decision {
    case .allow:
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
                    reason: hostDenyLine(command: command, reason: deny.reason, unlockCode: unlockCode),
                    rule: displayRuleID(deny.ruleID),
                    next: mintedUnlockNext(unlockCode) ?? hookUnlockNext
                )
            case .allow:
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
            }
        case .ask:
            return encodeAsked(from: bound, command: command, using: codec)
        }
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
    case .deny:
        switch HostNativeAsk.verdict(
            host: codec.host,
            result: result,
            cwd: cwd,
            bound: bound
        ) {
        case .ask:
            return encodeAsked(from: bound, command: command, using: codec)
        case .allow, .deny:
            return ClaudeHostCodec().encodeRichDeny(
                from: result,
                command: command,
                unlockCode: unlockCode
            )
        }
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
    bound: BoundReview,
    cwd: WorkingDirectory?,
    unlockCode: String?
) -> HookWire {
    switch result.decision {
    case .allow:
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
                    reason: hostDenyLine(command: command, reason: deny.reason, unlockCode: unlockCode),
                    rule: displayRuleID(deny.ruleID),
                    next: mintedUnlockNext(unlockCode) ?? hookUnlockNext
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
        switch HostNativeAsk.verdict(
            host: codec.host,
            result: result,
            cwd: cwd,
            bound: bound
        ) {
        case .allow, .deny:
            // A deny result must never become silent allow.
            return codec.encodeDeny(
                reason: hostDenyLine(command: command, reason: deny.reason, unlockCode: unlockCode),
                rule: displayRuleID(deny.ruleID),
                next: mintedUnlockNext(unlockCode)
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
