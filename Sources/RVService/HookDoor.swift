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

    public static func run(
        host: HookHost,
        stdin: String,
        evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        evaluateFile: (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)? = nil,
        spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil,
        mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockCode?)? = nil,
        recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil,
        clearHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil
    ) async throws -> HookEvaluateReply {
        reply(
            await hookWire(
                host: host,
                stdin: stdin,
                evaluate: evaluate,
                evaluateFile: evaluateFile,
                spendHostAsk: spendHostAsk,
                mintOnDeny: mintOnDeny,
                recordHostAsk: recordHostAsk,
                clearHostAsk: clearHostAsk
            )
        )
    }

    /// Create one awaiting row for a product Ask. Missing session is a no-op.
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
            continuation: .hostNative,
            timeoutPolicy: .keepWaiting
        )
        _ = try await store.create(pending, now: now)
    }

    /// Cancel every awaiting row with this identity + fingerprint after spend.
    package static func clearPending(
        request: HookRequest,
        action: ProposedAction,
        store: (any PendingApprovalCoordinating)?,
        now: Date
    ) async throws {
        guard let store, let session = request.session else { return }
        let identity = ApprovalIdentity(
            session: session,
            agent: request.host
        )
        let fingerprint = action.fingerprint
        let awaiting = try await store.list(now: now)
        for record in awaiting {
            guard record.identity == identity, record.fingerprint == fingerprint else {
                continue
            }
            do {
                _ = try await store.cancel(id: record.id, now: now)
            } catch {
                continue
            }
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
            spend: { command, cwd in
                let result = await world.spend(command: command, cwd: cwd, host: ledger)
                recordDecision?(result)
                return result
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
            clearHostAsk: { request, action in
                try await HookDoor.clearPending(
                    request: request,
                    action: action,
                    store: pending,
                    now: clock()
                )
            }
        )
    }
}
