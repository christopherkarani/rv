import RVDomain

/// Live hook door. Production and tests pass `HookEvaluateWorld`.
public func hookWire(
    host: HookHost,
    stdin: String,
    world: HookEvaluateWorld
) async -> HookWire {
    switch productionHostCodec(host) {
    case .ask(let codec):
        return await hookBody(
            stdin: stdin,
            codec: codec,
            world: world,
            firstCall: { result, command, verdict, unlockCode in
                hookWire(
                    from: result,
                    command: command,
                    using: codec,
                    intent: .firstCall(verdict: verdict, unlockCode: unlockCode)
                )
            }
        )
    case .denyOnly(let codec):
        return await hookBody(
            stdin: stdin,
            codec: codec,
            world: world,
            firstCall: { result, command, verdict, unlockCode in
                hookWire(
                    from: result,
                    command: command,
                    using: codec,
                    intent: .firstCall(verdict: verdict, unlockCode: unlockCode)
                )
            }
        )
    }
}

private func hookBody<C: HostCodec>(
    stdin: String,
    codec: C,
    world: HookEvaluateWorld,
    firstCall: (EvaluationResult, ShellCommand, HostAskVerdict, AllowOnceUnlockCode?) -> HookWire
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        switch request {
        case .file(_, let file, _, _):
            return await hookFileBody(
                request: request,
                file: file,
                codec: codec,
                evaluateFile: world.evaluateFile
            )
        case .spend(_, let command, let cwd, _):
            let result = await world.spend(command, cwd)
            let wire = hookWire(
                from: result,
                command: command,
                using: codec,
                intent: .afterSpend
            )
            await ignoreHostAskFailure {
                try await world.clearHostAsk(
                    request,
                    pendingAction(from: result, request: request, command: command)
                )
            }
            return wire
        case .shell(_, let command, let cwd, _):
            let result = await world.evaluate(command, cwd)
            let auth = HookAuthorization.project(host: codec.host, result: result, cwd: cwd)
            let unlockCode = await mintUnlockCodeIfNeeded(
                result: result,
                authorization: auth,
                cwd: cwd,
                mintOnDeny: world.mintOnDeny
            )
            if auth.shouldRecordPending {
                await ignoreHostAskFailure {
                    try await world.recordHostAsk(
                        request,
                        pendingAction(from: result, request: request, command: command)
                    )
                }
            }
            return firstCall(result, command, auth.verdict, unlockCode)
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
    evaluateFile: @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult
) async -> HookWire {
    if file.path.isEmpty {
        return codec.encodeDeny(
            reason: malformedHookSentence(.missingCommand),
            rule: nil,
            next: .none
        )
    }
    let result = await evaluateFile(file, request.cwd)
    return hookFileWire(from: result, using: codec)
}

func hookFileWire<C: HostCodec>(
    from result: EvaluationResult,
    using codec: C
) -> HookWire {
    codec.encodeFileDeny(from: result)
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

private func ignoreHostAskFailure(_ body: () async throws -> Void) async {
    do {
        try await body()
    } catch {
        return
    }
}

private func mintUnlockCodeIfNeeded(
    result: EvaluationResult,
    authorization: HookAuthorization,
    cwd: WorkingDirectory?,
    mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockCode?
) async -> AllowOnceUnlockCode? {
    guard authorization.shouldMintUnlock else { return nil }
    return await mintOnDeny(result, cwd)
}
