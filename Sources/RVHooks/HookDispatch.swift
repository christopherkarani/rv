import RVDomain

/// The single codec-dispatch body: decode stdin with the host's concrete codec,
/// evaluate, and map the result to host wire. `.foreign` allows; `.malformed` denies.
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    evaluateFile: (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)? = nil,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
            evaluateFile: evaluateFile,
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
    evaluateFile: (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)?,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)?,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)?,
    recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)?,
    clearHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)?
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        if let file = request.file {
            return await hookFileBody(
                request: request,
                file: file,
                codec: codec,
                evaluateFile: evaluateFile
            )
        }
        if request.hostAsk == .spend {
            guard let spendHostAsk else {
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
            }
            let result = await spendHostAsk(request.command, request.cwd)
            let wire = hookWire(
                from: result,
                command: request.command,
                using: codec,
                intent: .afterSpend
            )
            if let clearHostAsk {
                await ignoreHostAskFailure {
                    try await clearHostAsk(request, pendingAction(from: result, request: request))
                }
            }
            return wire
        }
        let result = await evaluate(request.command, request.cwd)
        let bound = BoundReview.packProjected(from: result)
        let verdict = HostNativeAsk.verdict(
            host: codec.host,
            result: result,
            cwd: request.cwd,
            bound: bound
        )
        let unlockCode = await mintUnlockCodeIfNeeded(
            result: result,
            verdict: verdict,
            cwd: request.cwd,
            mintOnDeny: mintOnDeny
        )
        if let recordHostAsk, encodesHostAsk(result: result, verdict: verdict) {
            await ignoreHostAskFailure {
                try await recordHostAsk(request, pendingAction(from: result, request: request))
            }
        }
        return hookWire(
            from: result,
            command: request.command,
            using: codec,
            intent: .firstCall(verdict: verdict, unlockCode: unlockCode)
        )
    case .foreign:
        return codec.encodeAllow()
    case .malformed(let malformation):
        return codec.encodeDeny(reason: malformedHookSentence(malformation), rule: nil, next: .none)
    }
}

private func hookFileBody<C: HostCodec>(
    request: HookRequest,
    file: FileToolAction,
    codec: C,
    evaluateFile: (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)?
) async -> HookWire {
    if file.path.isEmpty {
        return codec.encodeDeny(
            reason: malformedHookSentence(.missingCommand),
            rule: nil,
            next: .none
        )
    }
    guard let evaluateFile else {
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    }
    let result = await evaluateFile(file, request.cwd)
    return hookWire(
        from: result,
        command: request.command,
        using: codec,
        cwd: request.cwd
    )
}

private func pendingAction(from result: EvaluationResult, request: HookRequest) -> ProposedAction {
    result.pendingAction(
        host: request.host,
        session: request.session,
        cwd: request.cwd,
        command: request.command
    )
}

/// Matches `encodeAsked`: Ask JSON only for allow/deny results whose product
/// verdict is `.ask`. Indeterminate stays deny and must not create a wait.
private func encodesHostAsk(result: EvaluationResult, verdict: HostAskVerdict) -> Bool {
    switch result.decision {
    case .indeterminate:
        return false
    case .allow, .deny:
        switch verdict {
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
    result: EvaluationResult,
    verdict: HostAskVerdict,
    cwd: WorkingDirectory?,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)?
) async -> String? {
    guard let mintOnDeny else { return nil }
    guard case .deny = result.decision else { return nil }
    switch verdict {
    case .ask:
        return nil
    case .allow, .deny:
        return await mintOnDeny(result, cwd)
    }
}
