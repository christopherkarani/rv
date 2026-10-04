import RVDomain

/// Live hook door. Production and tests pass `HookEvaluateWorld`.
public func hookWire(
    host: HookHost,
    stdin: String,
    world: HookEvaluateWorld
) async -> HookWire {
    let codec = productionHostCodec(host)
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

private func hookBody(
    stdin: String,
    codec: any HostCodec,
    world: HookEvaluateWorld,
    firstCall: (EvaluationResult, ShellCommand, HostAskVerdict, AllowOnceUnlockMint?) -> HookWire
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
        case .shell(_, let command, let cwd, _):
            let result = await world.evaluate(command, cwd)
            let auth = HookAuthorization.project(result: result, cwd: cwd)
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

private func hookFileBody(
    request: HookRequest,
    file: FileToolAction,
    codec: any HostCodec,
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

func hookFileWire(
    from result: EvaluationResult,
    using codec: any HostCodec
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
    mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?
) async -> AllowOnceUnlockMint? {
    guard authorization.shouldMintUnlock else { return nil }
    return await mintOnDeny(result, cwd)
}
