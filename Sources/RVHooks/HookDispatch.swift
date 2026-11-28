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
        firstCall: { result, command, verdict, unlockCode, askRecorded, voice in
            hookWire(
                from: result,
                command: command,
                using: codec,
                intent: .firstCall(
                    verdict: verdict,
                    unlockCode: unlockCode,
                    askRecorded: askRecorded
                ),
                voice: voice
            )
        }
    )
}

private func hookBody(
    stdin: String,
    codec: any HostCodec,
    world: HookEvaluateWorld,
    firstCall: (
        EvaluationResult, ShellCommand, HostAskVerdict, AllowOnceUnlockMint?, Bool, StopVoice
    ) -> HookWire
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        return await HookSessionAttribution.$current.withValue(request.session) {
            await hookRequestBody(request: request, codec: codec, world: world, firstCall: firstCall)
        }
    case .foreign:
        return codec.encodeAllow()
    case .malformed(let malformation):
        return codec.encodeDeny(hookCallStopPresentation(.malformed(malformation), voice: world.voice))
    }
}

/// A stop about the hook call itself (unreadable payload, no command,
/// rvd's deadline), in the stop shape.
public func hookCallStopPresentation(_ stop: HookCallStop, voice: StopVoice = .plain) -> HookDenyPresentation {
    let notice = hookCallStopNotice(stop, voice: voice)
    return HookDenyPresentation(reason: notice.text, nextText: notice.who)
}

private func hookRequestBody(
    request: HookRequest,
    codec: any HostCodec,
    world: HookEvaluateWorld,
    firstCall: (
        EvaluationResult, ShellCommand, HostAskVerdict, AllowOnceUnlockMint?, Bool, StopVoice
    ) -> HookWire
) async -> HookWire {
    switch request {
    case .file(_, let file, _, _):
        return await hookFileBody(
            request: request,
            file: file,
            codec: codec,
            evaluateFile: world.evaluateFile,
            voice: world.voice,
            saferAllowed: world.saferAllowed
        )
    case .shell(_, let command, let cwd, _):
        let result = await world.evaluate(command, cwd)
        let auth = HookAuthorization.project(result: result, cwd: cwd)
        let unlockCode = await mintUnlockCodeIfNeeded(
            result: result,
            authorization: auth,
            cwd: cwd,
            command: command,
            mintOnDeny: world.mintOnDeny,
            mintOnDenyWithCommand: world.mintOnDenyWithCommand
        )
        // M-25: the ask guidance promises a pending row, so the record
        // outcome rides into the wire; a failed record renders the
        // unrecorded guidance instead of a promise no row can keep.
        var askRecorded = true
        if auth.shouldRecordPending {
            askRecorded = await recordHostAskIgnoringFailure {
                try await world.recordHostAsk(
                    request,
                    pendingAction(from: result, request: request, command: command)
                )
            }
        }
        // The pack's safer command shows only when rv allows it here.
        let voice = await world.voice.vetted(for: result, cwd: cwd, by: world.saferAllowed)
        return firstCall(result, command, auth.verdict, unlockCode, askRecorded, voice)
    }
}

private func hookFileBody(
    request: HookRequest,
    file: FileToolAction,
    codec: any HostCodec,
    evaluateFile: @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult,
    voice: StopVoice,
    saferAllowed: (@Sendable (ShellCommand, WorkingDirectory?) async -> Bool)?
) async -> HookWire {
    if file.path.isEmpty {
        return codec.encodeDeny(hookCallStopPresentation(.malformed(.missingCommand), voice: voice))
    }
    let result = await evaluateFile(file, request.cwd)
    let vetted = await voice.vetted(for: result, cwd: request.cwd, by: saferAllowed)
    return hookFileWire(from: result, using: codec, path: file.path, voice: vetted)
}

/// File wire: `HookMapper` composes the presentation; a file result that
/// allows composes none and stays allow.
func hookFileWire(
    from result: EvaluationResult,
    using codec: any HostCodec,
    path: FileToolPath? = nil,
    voice: StopVoice = .plain
) -> HookWire {
    guard let presentation = fileDenyPresentation(from: result, path: path, voice: voice) else {
        return codec.encodeAllow()
    }
    return codec.encodeDeny(presentation)
}

private func pendingAction(
    from result: EvaluationResult,
    request: HookRequest,
    command: ShellCommand
) -> ProposedAction {
    result.pendingAction(
        host: request.host,
        session: request.approvalSession,
        cwd: request.cwd,
        command: command
    )
}

private func recordHostAskIgnoringFailure(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return true
    } catch {
        return false
    }
}

private func mintUnlockCodeIfNeeded(
    result: EvaluationResult,
    authorization: HookAuthorization,
    cwd: WorkingDirectory?,
    command: ShellCommand,
    mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?,
    mintOnDenyWithCommand: (
        @Sendable (EvaluationResult, WorkingDirectory?, ShellCommand) async -> AllowOnceUnlockMint?
    )?
) async -> AllowOnceUnlockMint? {
    guard authorization.shouldMintUnlock else { return nil }
    // M-07: prefer the command-carrying port so the daemon binds the
    // minted row's payload digest; the legacy port mints unbound rows.
    if let mintOnDenyWithCommand {
        return await mintOnDenyWithCommand(result, cwd, command)
    }
    return await mintOnDeny(result, cwd)
}
