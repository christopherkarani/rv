import RVDomain
import RVHooks
import RVIPC

/// Server-side host codec door. Maps host stdin through gated evaluate to host wire.
public struct HookDoor: Sendable {
    public static func run(
        host: String,
        stdin: String,
        evaluate: @Sendable (ShellCommand, String?) async -> EvaluationResult
    ) async throws -> HookEvaluateReply {
        switch host {
        case HookHost.grok.rawValue:
            return reply(await run(stdin: stdin, codec: GrokHostCodec(), evaluate: evaluate))
        case HookHost.pi.rawValue:
            return reply(await run(stdin: stdin, codec: PiHostCodec(), evaluate: evaluate))
        case HookHost.opencode.rawValue:
            return reply(await run(stdin: stdin, codec: OpenCodeHostCodec(), evaluate: evaluate))
        default:
            throw IPCError.engine("unknown host")
        }
    }

    private static func run<C: HostCodec>(
        stdin: String,
        codec: C,
        evaluate: @Sendable (ShellCommand, String?) async -> EvaluationResult
    ) async -> HookWire {
        switch codec.decode(stdin) {
        case .request(let request):
            let result = await evaluate(request.command, request.cwd)
            return hookWire(from: result, command: request.command, using: codec)
        case .foreign, .malformed:
            return codec.encodeAllow()
        }
    }

    private static func reply(_ wire: HookWire) -> HookEvaluateReply {
        HookEvaluateReply(stdout: wire.stdout, exitCode: wire.exitCode)
    }
}
