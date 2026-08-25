import RVDomain

/// The single codec-dispatch body: decode stdin with the host's concrete codec,
/// evaluate, and map the result to host wire. `.foreign` allows; `.malformed` denies.
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
) async -> HookWire {
    switch host {
    case .grok:
        return await hookBody(stdin: stdin, codec: GrokHostCodec(), evaluate: evaluate)
    case .pi:
        return await hookBody(stdin: stdin, codec: PiHostCodec(), evaluate: evaluate)
    case .opencode:
        return await hookBody(stdin: stdin, codec: OpenCodeHostCodec(), evaluate: evaluate)
    case .claude:
        preconditionFailure("CL-T3 owns HookDispatch claude wire")
    }
}

private func hookBody<C: HostCodec>(
    stdin: String,
    codec: C,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
) async -> HookWire {
    switch codec.decode(stdin) {
    case .request(let request):
        let result = await evaluate(request.command, request.cwd)
        return hookWire(from: result, command: request.command, using: codec)
    case .foreign:
        return codec.encodeAllow()
    case .malformed(let malformation):
        return codec.encodeDeny(reason: malformedHookSentence(malformation), rule: nil, next: nil)
    }
}
