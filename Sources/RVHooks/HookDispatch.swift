import RVDomain

/// The single codec-dispatch body: decode stdin with the host's concrete codec,
/// evaluate, and map the result to host wire. `.foreign` allows; `.malformed` denies.
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil
) async -> HookWire {
    switch host {
    case .grok:
        return await hookBody(
            stdin: stdin,
            codec: GrokHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
    case .pi:
        return await hookBody(
            stdin: stdin,
            codec: PiHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
    case .opencode:
        return await hookBody(
            stdin: stdin,
            codec: OpenCodeHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
    case .claude:
        return await hookBody(
            stdin: stdin,
            codec: ClaudeHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
    case .openclaw:
        return await hookBody(
            stdin: stdin,
            codec: OpenClawHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
    case .hermes:
        return await hookBody(
            stdin: stdin,
            codec: HermesHostCodec(),
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
    }
}

private func hookBody<C: HostCodec>(
    stdin: String,
    codec: C,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)?
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
        return hookWire(from: result, command: request.command, using: codec)
    case .foreign:
        return codec.encodeAllow()
    case .malformed(let malformation):
        return codec.encodeDeny(reason: malformedHookSentence(malformation), rule: nil, next: nil)
    }
}
