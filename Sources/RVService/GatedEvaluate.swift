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

    /// Shows a matching grant without spending it.
    public func peek(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await PolicyGate.peek(
            session.evaluate(request),
            cwd: cwd,
            store: store,
            now: now
        ).result
    }

    /// Spends a matching grant after an engine deny.
    public func apply(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await PolicyGate.apply(
            session.evaluate(request),
            cwd: cwd,
            store: store,
            now: now
        ).result
    }
}
