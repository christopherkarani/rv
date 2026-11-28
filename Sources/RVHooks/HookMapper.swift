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

/// Returns the host wire for `intent`, in `voice` (owner name and pack
/// advice; `.plain` says "your user" and offers no safer command).
public func hookWire(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: any HostCodec,
    intent: HookWireIntent,
    voice: StopVoice = .plain
) -> HookWire {
    switch intent {
    case .firstCall(let verdict, let unlockCode, let askRecorded):
        return encodeFirstCall(
            from: result,
            command: command,
            using: codec,
            verdict: verdict,
            unlockCode: unlockCode,
            askRecorded: askRecorded,
            voice: voice
        )
    }
}

/// Convenience: project `HostAskVerdict` then encode `.firstCall`.
public func hookWire(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: any HostCodec,
    cwd: WorkingDirectory? = nil,
    voice: StopVoice = .plain
) -> HookWire {
    hookWire(
        from: result,
        command: command,
        using: codec,
        intent: firstCallIntent(from: result, cwd: cwd),
        voice: voice
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
    askRecorded: Bool,
    voice: StopVoice
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
                askRecorded: askRecorded,
                voice: voice
            )
        )
    case .deny:
        return codec.encodeDeny(
            denyPresentation(from: result, command: command, unlockCode: unlockCode, voice: voice)
        )
    }
}

/// Composes the live evaluated deny. An evaluated allow or indeterminate
/// reaching deny dispatch is an incomplete evaluation, so it renders the
/// incomplete stop, never allow (REQ-T4).
func denyPresentation(
    from result: EvaluationResult,
    command: ShellCommand,
    unlockCode: AllowOnceUnlockMint?,
    voice: StopVoice = .plain
) -> HookDenyPresentation {
    switch result.decision {
    case .allow:
        return incompletePresentation(nil, command: command, voice: voice)
    case .indeterminate(let reason):
        return incompletePresentation(reason, command: command, voice: voice)
    case .deny(let deny):
        let notice = stopNotice(command: command, deny: deny, kind: .deny, unlock: unlockCode, voice: voice)
        return HookDenyPresentation(
            reason: notice.text,
            rule: deny.ruleID,
            next: unlockHookVoiceNext(unlockCode),
            matched: denyMatch(from: result),
            nextText: notice.who
        )
    }
}

/// Composes the ask-denial: the same stop, with one `who`. The policy
/// verdict stays ASK; only the wire renders deny because no host can pause
/// for a human. A minted code is the one step offered (the RVOperatorUI
/// row exists too, and the owner sees it there); with no code, a recorded
/// row on macOS names the RV app, and a row that failed to record (M-25)
/// promises nothing and sends the owner to their own terminal.
func askDenyPresentation(
    from result: EvaluationResult,
    command: ShellCommand,
    unlockCode: AllowOnceUnlockMint?,
    askRecorded: Bool,
    voice: StopVoice = .plain
) -> HookDenyPresentation {
    switch result.decision {
    case .allow:
        return incompletePresentation(nil, command: command, voice: voice)
    case .indeterminate(let reason):
        return incompletePresentation(reason, command: command, voice: voice)
    case .deny(let deny):
        let notice = stopNotice(
            command: command, deny: deny, kind: .ask(recorded: askRecorded), unlock: unlockCode, voice: voice)
        return HookDenyPresentation(
            reason: notice.text,
            rule: deny.ruleID,
            next: unlockHookVoiceNext(unlockCode),
            matched: denyMatch(from: result),
            nextText: notice.who
        )
    }
}

/// Composes the file-tool deny, or `nil` when the file result allows —
/// file allow stays allow, unlike evaluated allow (REQ-T4).
func fileDenyPresentation(
    from result: EvaluationResult,
    path: FileToolPath? = nil,
    voice: StopVoice = .plain
) -> HookDenyPresentation? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate(let reason):
        let notice = indeterminateStopNotice(reason, command: nil, voice: voice)
        return HookDenyPresentation(reason: noticeText(notice, path: path), nextText: notice.who)
    case .deny(let deny):
        let notice = fileStopNotice(path: path, deny: deny, voice: voice)
        return HookDenyPresentation(
            reason: notice.text,
            rule: deny.ruleID,
            matched: denyMatch(from: result),
            nextText: notice.who
        )
    }
}

private func noticeText(_ notice: StopNotice, path: FileToolPath?) -> String {
    var notice = notice
    notice.subject = path.map(hookDenyPathPreview)
    return notice.text
}

/// An unfinished evaluation: the indeterminate stop, never an allow.
private func incompletePresentation(
    _ reason: IndeterminateReason?,
    command: ShellCommand,
    voice: StopVoice
) -> HookDenyPresentation {
    let notice = indeterminateStopNotice(reason, command: command, voice: voice)
    return HookDenyPresentation(reason: notice.text, nextText: notice.who)
}

private func denyMatch(from result: EvaluationResult) -> RuleMatch? {
    guard case .deny(_, let matched) = result.outcome else { return nil }
    return matched
}
