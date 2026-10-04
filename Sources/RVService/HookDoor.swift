import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import RVPolicy

/// Server-side host codec door. Maps host stdin through gated evaluate to host wire.
public struct HookDoor: Sendable {
    public static func run(
        host: HookHost,
        stdin: String,
        world: HookEvaluateWorld
    ) async throws -> HookEvaluateReply {
        reply(await hookWire(host: host, stdin: stdin, world: world))
    }

    /// Create one awaiting row for a product Ask. Missing session is a no-op.
    /// A full store drops the row (spam protection): the consult still
    /// answers ask-denial and the TTY code path is unaffected, so the
    /// human can still approve the exact action out of band.
    package static func recordPending(
        request: HookRequest,
        action: ProposedAction,
        store: (any PendingApprovalCoordinating)?,
        now: Date
    ) async throws {
        guard let store, let session = request.session else { return }
        let pending = PendingApprovalRequest(
            id: PendingApprovalStore.makeID(),
            identity: ApprovalIdentity(
                session: session,
                agent: request.host
            ),
            action: action,
            reason: .hostAsk,
            continuation: .retry(action.fingerprint),
            timeoutPolicy: .autoDeny
        )
        do {
            _ = try await store.create(pending, now: now)
        } catch PendingApprovalError.storeFull {
            return
        }
    }

    private static func reply(_ wire: HookWire) -> HookEvaluateReply {
        HookEvaluateReply(stdout: wire.stdout, exitCode: wire.exitCode, stderr: wire.stderr)
    }
}

extension HookEvaluateWorld {
    /// Production ports over a `LiveEvaluateWorld`. Miss and warm rvd share this.
    package static func live(
        world: LiveEvaluateWorld,
        host: HookHost,
        pending: (any PendingApprovalCoordinating)?,
        clock: @escaping @Sendable () -> Date,
        recordDecision: (@Sendable (EvaluationResult) -> Void)? = nil
    ) -> HookEvaluateWorld {
        let ledger = LedgerHost.hook(host)
        return HookEvaluateWorld(
            evaluate: { command, cwd in
                let result = await world.apply(command: command, cwd: cwd, host: ledger)
                recordDecision?(result)
                return result
            },
            evaluateFile: { action, cwd in
                world.runFile(action: action, cwd: cwd, host: ledger)
            },
            mintOnDeny: { result, cwd in
                await world.mintUnlockCode(for: result, cwd: cwd)
            },
            recordHostAsk: { request, action in
                try await HookDoor.recordPending(
                    request: request,
                    action: action,
                    store: pending,
                    now: clock()
                )
            }
        )
    }
}
