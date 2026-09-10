import RVDomain

/// The single codec-dispatch body: decode stdin with the host's concrete codec,
/// evaluate, and map the result to host wire. `.foreign` allows; `.malformed` denies.
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)? = nil,
    recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil,
    clearHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil
) async -> HookWire {
    switch host {
    case .grok:
        return await hookBody(
            stdin: stdin,
            codec: GrokHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .pi:
        return await hookBody(
            stdin: stdin,
            codec: PiHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .opencode:
        return await hookBody(
            stdin: stdin,
            codec: OpenCodeHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .claude:
        return await hookBody(
            stdin: stdin,
            codec: ClaudeHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .openclaw:
        return await hookBody(
            stdin: stdin,
            codec: OpenClawHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .hermes:
        return await hookBody(
            stdin: stdin,
            codec: HermesHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .codex:
        return await hookBody(
            stdin: stdin,
            codec: CodexHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    case .cursor:
        return await hookBody(
            stdin: stdin,
            codec: CursorHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk,
            mintOnDeny: mintOnDeny,
            recordHostAsk: recordHostAsk,
            clearHostAsk: clearHostAsk
        )
    }
}

private func hookBody<C: HostCodec>(
    stdin: String,
    codec: C,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)?,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)?,
    recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)?,
    clearHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)?
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        let action = codec.proposedAction(from: request)
        if request.hostAsk == .spend {
            guard let spendHostAsk else {
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
            }
            let result = await spendHostAsk(request.command, request.cwd)
            let wire = hookWire(
                from: result,
                command: request.command,
                using: codec,
                phase: .postSpend
            )
            if let clearHostAsk {
                await ignoreHostAskFailure {
                    try await clearHostAsk(request, action)
                }
            }
            return wire
        }
        let result = await evaluate(request.command, request.cwd)
        let bound = HostNativeAsk.bound(from: result)
        let unlockCode = await mintUnlockCodeIfNeeded(
            host: codec.host,
            result: result,
            bound: bound,
            cwd: request.cwd,
            mintOnDeny: mintOnDeny
        )
        if let recordHostAsk,
           encodesHostAsk(host: codec.host, result: result, bound: bound, cwd: request.cwd)
        {
            await ignoreHostAskFailure {
                try await recordHostAsk(request, action)
            }
        }
        return hookWire(
            from: result,
            command: request.command,
            using: codec,
            phase: .firstCall(bound: bound, cwd: request.cwd, unlockCode: unlockCode)
        )
    case .foreign:
        return codec.encodeAllow()
    case .malformed(let malformation):
        return codec.encodeDeny(reason: malformedHookSentence(malformation), rule: nil, next: nil)
    }
}

/// Matches `encodeAsked`: Ask JSON only for allow/deny results whose product
/// verdict is `.ask`. Indeterminate stays deny and must not create a wait.
private func encodesHostAsk(
    host: HookHost,
    result: EvaluationResult,
    bound: BoundReview,
    cwd: WorkingDirectory?
) -> Bool {
    switch result.decision {
    case .indeterminate:
        return false
    case .allow, .deny:
        switch HostNativeAsk.verdict(host: host, result: result, cwd: cwd, bound: bound) {
        case .ask:
            return true
        case .allow, .deny:
            return false
        }
    }
}

private func ignoreHostAskFailure(_ body: () async throws -> Void) async {
    do {
        try await body()
    } catch {
        return
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
