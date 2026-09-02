import RVDomain

/// The single codec-dispatch body: decode stdin with the host's concrete codec,
/// evaluate, and map the result to host wire. `.foreign` allows; `.malformed` denies.
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)? = nil
) async -> HookWire {
    switch host {
    case .grok:
        return await hookBody(
            stdin: stdin,
            codec: GrokHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .pi:
        return await hookBody(
            stdin: stdin,
            codec: PiHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .opencode:
        return await hookBody(
            stdin: stdin,
            codec: OpenCodeHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .claude:
        return await hookBody(
            stdin: stdin,
            codec: ClaudeHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .openclaw:
        return await hookBody(
            stdin: stdin,
            codec: OpenClawHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .hermes:
        return await hookBody(
            stdin: stdin,
            codec: HermesHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .codex:
        return await hookBody(
            stdin: stdin,
            codec: CodexHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    case .cursor:
        return await hookBody(
            stdin: stdin,
            codec: CursorHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny
        )
    }
}

private func hookBody<C: HostCodec>(
    stdin: String,
    codec: C,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)?,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)?
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        if request.hostAsk == .spend {
            guard let spendHostAsk else {
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
            }
            let result = await spendHostAsk(request.command, request.cwd)
            return hookWire(from: result, command: request.command, using: codec, afterSpend: true)
        }
        let result = await evaluate(request.command, request.cwd)
        let bound: BoundReview
        let wireResult: EvaluationResult
        if let live = LiveEvaluation(result) {
            bound = live.bound
            wireResult = live.wire
        } else {
            bound = HostNativeAsk.hookBound(
                result: result,
                action: codec.proposedAction(from: request),
                context: ReviewContext(repository: RepositoryReviewContext())
            )
            wireResult = result
        }
        let unlockCode = await mintUnlockCodeIfNeeded(
            host: codec.host,
            result: result,
            bound: bound,
            cwd: request.cwd,
            mintOnDeny: mintOnDeny
        )
        return hookWire(
            from: wireResult,
            command: request.command,
            using: codec,
            bound: bound,
            cwd: request.cwd,
            unlockCode: unlockCode
        )
    case .foreign:
        return codec.encodeAllow()
    case .malformed(let malformation):
        return codec.encodeDeny(reason: malformedHookSentence(malformation), rule: nil, next: nil)
    }
}

private func mintUnlockCodeIfNeeded(
    host: HookHost,
    result: EvaluationResult,
    bound: BoundReview,
    cwd: WorkingDirectory?,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)?
) async -> String? {
    guard let mintOnDeny else { return nil }
    guard case .deny = result.decision else { return nil }
    switch HostNativeAsk.verdict(host: host, result: result, cwd: cwd, bound: bound) {
    case .ask:
        return nil
    case .allow, .deny:
        return await mintOnDeny(result, cwd)
    }
}
