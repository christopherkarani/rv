import RVDomain

/// Live hook door. Production call sites pass `HookEvaluateWorld`.
public func hookWire(
    host: HookHost,
    stdin: String,
    world: HookEvaluateWorld
) async -> HookWire {
    await hookWire(
        host: host,
        stdin: stdin,
        evaluate: world.evaluate,
        evaluateFile: world.evaluateFile,
        spendHostAsk: world.spend,
        mintOnDeny: world.mintOnDeny,
        recordHostAsk: world.recordHostAsk,
        clearHostAsk: world.clearHostAsk
    )
}

/// Test/legacy adapter. Missing file/spend/mint/record ports fail closed as today.
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
        switch request {
        case .file(_, let file, _, _):
            return await hookFileBody(
                request: request,
                file: file,
                codec: codec,
                evaluateFile: evaluateFile
            )
        case .spend(_, let command, let cwd, _):
            guard let spendHostAsk else {
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
            }
            let result = await spendHostAsk(command, cwd)
            let wire = hookWire(
                from: result,
                command: command,
                using: codec,
                intent: .afterSpend
            )
            if let clearHostAsk {
                await ignoreHostAskFailure {
                    try await clearHostAsk(
                        request,
                        pendingAction(from: result, request: request, command: command)
                    )
                }
            }
            return wire
        case .shell(_, let command, let cwd, _):
            let result = await evaluate(command, cwd)
            let bound = BoundReview.packProjected(from: result)
            let verdict = HostNativeAsk.hostAskVerdict(
                host: codec.host,
                result: result,
                cwd: cwd,
                bound: bound
            )
            let unlockCode = await mintUnlockCodeIfNeeded(
                result: result,
                verdict: verdict,
                cwd: cwd,
                mintOnDeny: mintOnDeny
            )
            if let recordHostAsk, encodesHostAsk(result: result, verdict: verdict) {
                await ignoreHostAskFailure {
                    try await recordHostAsk(
                        request,
                        pendingAction(from: result, request: request, command: command)
                    )
                }
            }
            return hookWire(
                from: result,
                command: command,
                using: codec,
                intent: .firstCall(
                    verdict: verdict,
                    unlockCode: unlockCode.flatMap(AllowOnceUnlockCode.init(validating:))
                )
            )
        }
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
    return hookFileWire(from: result, using: codec)
}

private func hookFileWire<C: HostCodec>(
    from result: EvaluationResult,
    using codec: C
) -> HookWire {
    switch result.decision {
    case .allow:
        return codec.encodeAllow()
    case .indeterminate:
        return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    case .deny(let deny):
        let reason = hostFileDenyLine(reason: deny.reason)
        if codec.host == .claude, case .deny(_, let matched?) = result.outcome {
            return HookWire(
                stdout: claudeRichDenyJSON(hostDenyText: reason, match: matched),
                exitCode: codec.host.denyExitCode
            )
        }
        return codec.encodeDeny(reason: reason, rule: deny.ruleID, next: .none)
    }
}

private func pendingAction(
    from result: EvaluationResult,
    request: HookRequest,
    command: ShellCommand
) -> ProposedAction {
    result.pendingAction(
        host: request.host,
        session: request.session,
        cwd: request.cwd,
        command: command
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
