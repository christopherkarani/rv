import RVDomain

/// First-call encode. Product Ask is `HostAskVerdict`; codecs only encode.
///
/// Step 8B: there is no post-spend intent. Host-native spend is removed;
/// an `.ask` verdict records a pending row (in `hookBody`) and encodes
/// deny-with-guidance on every host.
public enum HookWireIntent: Sendable, Equatable {
    case firstCall(
        verdict: HostAskVerdict,
        unlockCode: AllowOnceUnlockMint?,
        askRecorded: Bool = true
    )
}

/// Returns the host wire for `intent`.
public func hookWire(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: any HostCodec,
    intent: HookWireIntent
) -> HookWire {
    switch intent {
    case .firstCall(let verdict, let unlockCode, let askRecorded):
        return encodeFirstCall(
            from: result,
            command: command,
            using: codec,
            verdict: verdict,
            unlockCode: unlockCode,
            askRecorded: askRecorded
        )
    }
}

/// Convenience: project `HostAskVerdict` then encode `.firstCall`.
public func hookWire(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: any HostCodec,
    cwd: WorkingDirectory? = nil
) -> HookWire {
    hookWire(
        from: result,
        command: command,
        using: codec,
        intent: firstCallIntent(from: result, cwd: cwd)
    )
}

private func firstCallIntent(
    from result: EvaluationResult,
    cwd: WorkingDirectory?
) -> HookWireIntent {
    let auth = HookAuthorization.project(result: result, cwd: cwd)
    return .firstCall(verdict: auth.verdict, unlockCode: nil)
}

private func encodeFirstCall(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: any HostCodec,
    verdict: HostAskVerdict,
    unlockCode: AllowOnceUnlockMint?,
    askRecorded: Bool
) -> HookWire {
    switch verdict {
    case .allow:
        return codec.encodeAllow()
    case .ask:
        return codec.encodeDeny(
            askDenyPresentation(
                from: result,
                command: command,
                unlockCode: unlockCode,
                askRecorded: askRecorded
            )
        )
    case .deny:
        return codec.encodeDeny(
            denyPresentation(from: result, command: command, unlockCode: unlockCode)
        )
    }
}

/// Composes the live evaluated deny. An evaluated allow or indeterminate
/// reaching deny dispatch is an incomplete evaluation, so it renders the
/// incomplete sentence, never allow (REQ-T4).
func denyPresentation(
    from result: EvaluationResult,
    command: ShellCommand,
    unlockCode: AllowOnceUnlockMint?
) -> HookDenyPresentation {
    switch result.decision {
    case .allow, .indeterminate:
        return HookDenyPresentation(reason: incompleteEvalSentence)
    case .deny(let deny):
        return HookDenyPresentation(
            reason: hostDenyLine(command: command, reason: deny.reason, unlock: unlockCode),
            rule: deny.ruleID,
            next: unlockHookVoiceNext(unlockCode),
            matched: denyMatch(from: result)
        )
    }
}

/// Composes the ask-denial: same deny content plus the approval-pending
/// guidance. The policy verdict stays ASK; only the wire renders deny
/// because no host can pause for a human. The TTY unlock line still
/// applies, so a minted code and the RVOperatorUI row are offered
/// together. The guidance joins AFTER `hostDenyLine`: annotating the
/// reason would lose it to the two-sentence truncation on multi-sentence
/// reasons. When the pending row failed to record, the guidance and the
/// ask agent text say so instead of promising an approval that cannot
/// exist (M-25).
func askDenyPresentation(
    from result: EvaluationResult,
    command: ShellCommand,
    unlockCode: AllowOnceUnlockMint?,
    askRecorded: Bool
) -> HookDenyPresentation {
    switch result.decision {
    case .allow, .indeterminate:
        return HookDenyPresentation(reason: incompleteEvalSentence)
    case .deny(let deny):
        let line =
            "\(hostDenyLine(command: command, reason: deny.reason, unlock: unlockCode)) \(askPendingLine(recorded: askRecorded))"
        return HookDenyPresentation(
            reason: line,
            rule: deny.ruleID,
            next: unlockHookVoiceNext(unlockCode),
            matched: denyMatch(from: result),
            agentText: cursorAgentAskMessage(recorded: askRecorded)
        )
    }
}

/// Composes the file-tool deny, or `nil` when the file result allows —
/// file allow stays allow, unlike evaluated allow (REQ-T4).
func fileDenyPresentation(from result: EvaluationResult) -> HookDenyPresentation? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate:
        return HookDenyPresentation(reason: incompleteEvalSentence)
    case .deny(let deny):
        return HookDenyPresentation(
            reason: hostFileDenyLine(reason: deny.reason),
            rule: deny.ruleID,
            matched: denyMatch(from: result)
        )
    }
}

private func denyMatch(from result: EvaluationResult) -> RuleMatch? {
    guard case .deny(_, let matched) = result.outcome else { return nil }
    return matched
}
