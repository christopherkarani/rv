import Foundation
import RVDomain
import RVEngine
import RVHistory
import RVHooks
import RVIPC
import RVPolicy

/// Server-side host codec door. Maps host stdin through gated evaluate to host wire.
public struct HookDoor: Sendable {
    /// Deny reason when the daemon ran past `HookDeadline.budget`: the client
    /// has already given up, so nothing was committed on its behalf.
    static let timeoutReason = "rv timed out evaluating this action and committed nothing; retry it."

    /// `deadline` defaults to a budget starting now. The daemon passes one
    /// started at frame receipt. Pass it with a `deadlineGuarded` world (as
    /// `live` builds) so mint and pending ports honor it too.
    public static func run(
        host: HookHost,
        stdin: String,
        world: HookEvaluateWorld,
        deadline: HookDeadline = HookDeadline()
    ) async throws -> HookEvaluateReply {
        guard deadline.permitsSideEffects() else {
            return timeoutReply(host: host)
        }
        let wire = await HookDeadline.$current.withValue(deadline) {
            await hookWire(host: host, stdin: stdin, world: world)
        }
        // A skipped side effect means the wire may promise a pending row or
        // unlock code that does not exist; the client gave up anyway. A
        // grant spent in time is the exception: its allow is delivered.
        if deadline.requiresTimeoutReply {
            return timeoutReply(host: host)
        }
        return reply(wire)
    }

    private static func timeoutReply(host: HookHost) -> HookEvaluateReply {
        reply(productionHostCodec(host).encodeDeny(reason: timeoutReason, rule: nil, next: .none))
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
        let payloadDigest: ContentPayloadDigest?
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
        return deadlineGuarded(HookEvaluateWorld(
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
            // exact text, never in the view). The exact text itself stays
            // in rvd's memory for the owner's allow-once prompt only.
            mintOnDenyWithCommand: { result, cwd, command in
                await world.mintUnlockCode(
                    for: result,
                    cwd: cwd,
                    maskedSegments: Normalize.maskedSegments(of: command),
                    invocationPrefix: Normalize.invocationPrefix(of: command),
                    invocationDisplay: Normalize.invocationDisplay(of: command),
                    rawCommand: command.rawValue
                )
            }
        ))
    }

    /// Gates the ports whose effects only make sense if the client sees the
    /// reply (unlock-code mint, pending-approval row) on the task's bound
    /// `HookDeadline`. Grant spend and the denial ledger are gated inside
    /// `GatedEvaluate`, where they happen.
    package static func deadlineGuarded(_ world: HookEvaluateWorld) -> HookEvaluateWorld {
        let mintWithCommand = world.mintOnDenyWithCommand.map { mint in
            { @Sendable (result: EvaluationResult, cwd: WorkingDirectory?, command: ShellCommand) in
                guard HookDeadline.permitsSideEffects() else { return AllowOnceUnlockMint?.none }
                return await mint(result, cwd, command)
            }
        }
        return HookEvaluateWorld(
            evaluate: world.evaluate,
            evaluateFile: world.evaluateFile,
            mintOnDeny: { result, cwd in
                guard HookDeadline.permitsSideEffects() else { return nil }
                return await world.mintOnDeny(result, cwd)
            },
            recordHostAsk: { request, action in
                guard HookDeadline.permitsSideEffects() else { return }
                try await world.recordHostAsk(request, action)
            },
            mintOnDenyWithCommand: mintWithCommand
        )
    }
}
