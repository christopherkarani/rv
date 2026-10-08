import Foundation
import RVDomain
import RVEngine
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
        // M6: shell asks bind the hidden payload in the dedupe key so
        // same-view different-payload asks mint separate waits. File
        // asks carry no shell payload; their fingerprint already covers
        // the action exactly.
        let payloadDigest: String?
        if case .shell(_, let command, _, _) = request {
            payloadDigest = maskedPayloadContentDigest(Normalize.maskedSegments(of: command))
        } else {
            payloadDigest = nil
        }
        let pending = PendingApprovalRequest(
            id: PendingApprovalStore.makeID(),
            identity: ApprovalIdentity(
                session: session,
                agent: request.host
            ),
            action: action,
            reason: .hostAsk,
            continuation: .retry(action.fingerprint),
            timeoutPolicy: .autoDeny,
            payloadDigest: payloadDigest
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
            },
            // M-07: the hook holds exact text, so its mint binds the
            // hidden payload; the row stores the digest only. B1: the mint
            // also binds the erased invocation prefix (wrappers live in the
            // exact text, never in the view).
            mintOnDenyWithCommand: { result, cwd, command in
                await world.mintUnlockCode(
                    for: result,
                    cwd: cwd,
                    maskedSegments: Normalize.maskedSegments(of: command),
                    invocationPrefix: Normalize.invocationPrefix(of: command),
                    invocationDisplay: Normalize.invocationDisplay(of: command)
                )
            }
        )
    }
}
