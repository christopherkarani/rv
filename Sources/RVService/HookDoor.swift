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
        ports: HookWirePorts
    ) async -> HookEvaluateReply {
        reply(await hookWire(host: host, stdin: stdin, ports: ports))
    }

    /// Evaluate-only convenience for tests. Extra ports default to nil (fail closed).
    public static func run(
        host: HookHost,
        stdin: String,
        evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    ) async -> HookEvaluateReply {
        await run(host: host, stdin: stdin, ports: HookWirePorts(evaluate: evaluate))
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
