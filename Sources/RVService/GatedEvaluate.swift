import Foundation
import RVDomain
import RVPolicy

/// Runs the Evaluate session, then the Policy gate.
public struct GatedEvaluate: Sendable {
    public var corePacksReady: Bool { session.corePacksReady }

    private let session: EvaluateSession

    /// Creates a door around an Evaluate session.
    public init(_ session: EvaluateSession = EvaluateSession()) {
        self.session = session
    }

    /// Shows a matching grant / allowlist without spending it.
    public func peek(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        let result = session.evaluate(request)
        let allowlist = AllowlistStore(baseDirectory: store.baseDirectory)
            .loadUserSnapshot(workspacePath: cwd, now: now)
        return await PolicyGate.peek(
            result,
            cwd: cwd,
            allowlist: allowlist,
            store: store,
            now: now
        ).result
    }

    /// Spends a matching grant after an engine deny; honor user allowlist first.
    public func apply(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        let result = session.evaluate(request)
        let allowlist = AllowlistStore(baseDirectory: store.baseDirectory)
            .loadUserSnapshot(workspacePath: cwd, now: now)
        return await PolicyGate.apply(
            result,
            cwd: cwd,
            allowlist: allowlist,
            store: store,
            now: now
        ).result
    }
}
