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
        return codec.encodeEvaluatedAskDeny(
            from: result,
            command: command,
            unlockCode: unlockCode,
            askRecorded: askRecorded
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

private func encodeLiveDeny(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: any HostCodec,
    unlockCode: AllowOnceUnlockMint?
) -> HookWire {
    codec.encodeEvaluatedDeny(
        from: result,
        command: command,
        unlockCode: unlockCode
    )
}
