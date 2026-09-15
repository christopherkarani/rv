import RVDomain

/// The single codec-dispatch body: decode stdin with the host's concrete codec,
/// evaluate, and map the result to host wire. `.foreign` allows; `.malformed` denies.
public func hookWire(
    host: HookHost,
    stdin: String,
    ports: HookWirePorts
) async -> HookWire {
    switch host {
    case .grok:
        return await hookBody(stdin: stdin, codec: GrokHostCodec(), ports: ports)
    case .pi:
        return await hookBody(stdin: stdin, codec: PiHostCodec(), ports: ports)
    case .opencode:
        return await hookBody(stdin: stdin, codec: OpenCodeHostCodec(), ports: ports)
    case .claude:
        return await hookBody(stdin: stdin, codec: ClaudeHostCodec(), ports: ports)
    case .openclaw:
        return await hookBody(stdin: stdin, codec: OpenClawHostCodec(), ports: ports)
    case .hermes:
        return await hookBody(stdin: stdin, codec: HermesHostCodec(), ports: ports)
    case .codex:
        return await hookBody(stdin: stdin, codec: CodexHostCodec(), ports: ports)
    case .cursor:
        return await hookBody(stdin: stdin, codec: CursorHostCodec(), ports: ports)
    }
}

/// Evaluate-only convenience. Extra ports default to nil (fail closed).
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
) async -> HookWire {
    await hookWire(host: host, stdin: stdin, ports: HookWirePorts(evaluate: evaluate))
}

private func hookBody<C: HostCodec>(
    stdin: String,
    codec: C,
    ports: HookWirePorts
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        if let file = request.file {
            return await hookFileBody(
                request: request,
                file: file,
                codec: codec,
                evaluateFile: ports.evaluateFile
            )
        }
        if request.hostAsk == .spend {
            guard let spendHostAsk = ports.spendHostAsk else {
                return codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
            }
            let result = await spendHostAsk(request.command, request.cwd)
            let wire = hookWire(
                from: result,
                command: request.command,
                using: codec,
                intent: .afterSpend
            )
            if let clearHostAsk = ports.clearHostAsk {
                await ignoreHostAskFailure {
                    try await clearHostAsk(request, pendingAction(from: result, request: request))
                }
            }
            return wire
        }
        let result = await ports.evaluate(request.command, request.cwd)
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
            mintOnDeny: ports.mintOnDeny
        )
        if let recordHostAsk = ports.recordHostAsk, encodesHostAsk(result: result, verdict: verdict) {
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
