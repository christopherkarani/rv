import RVDomain
import RVHooks
import RVIPC

/// Server-side host codec door. Maps host stdin through gated evaluate to host wire.
public struct HookDoor: Sendable {
    public static func run(
        host: HookHost,
        stdin: String,
        evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    ) async throws -> HookEvaluateReply {
        reply(await hookWire(host: host, stdin: stdin, evaluate: evaluate))
    }

    private static func reply(_ wire: HookWire) -> HookEvaluateReply {
        HookEvaluateReply(stdout: wire.stdout, exitCode: wire.exitCode)
    }
}
