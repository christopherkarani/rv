import Foundation
import RVDomain
import RVHooks
import RVIPC
import RVPolicy

/// Server-side host codec door. Maps host stdin through gated evaluate to host wire.
public struct HookDoor: Sendable {
    public static func run(
        host: HookHost,
        stdin: String,
        evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil,
        mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)? = nil,
        recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil,
        clearHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil
    ) async throws -> HookEvaluateReply {
        reply(
            await hookWire(
                host: host,
                stdin: stdin,
                evaluate: evaluate,
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
                session: SessionIdentity(rawValue: session.rawValue),
                agent: AgentIdentity(rawValue: request.host.rawValue)
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
            session: SessionIdentity(rawValue: session.rawValue),
            agent: AgentIdentity(rawValue: request.host.rawValue)
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
