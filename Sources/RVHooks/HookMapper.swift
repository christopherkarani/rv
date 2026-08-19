import RVDomain

public func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C
) -> HookWire {
    switch result.decision {
    case .allow:
        return codec.encodeAllow()
    case .deny(let deny):
        let reason = hostDenyText(from: result, command: command) ?? incompleteEvalSentence
        return HookWire(
            stdout: hookDenyJSON(
                reason: reason,
                rule: displayRuleID(deny.ruleID),
                next: hookUnlockNext
            ),
            exitCode: codec.host.denyExitCode
        )
    case .indeterminate:
        return HookWire(
            stdout: hookDenyJSON(reason: incompleteEvalSentence),
            exitCode: codec.host.denyExitCode
        )
    }
}
