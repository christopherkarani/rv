import Foundation
import RVDomain
import RVPolicy

/// Runs the Evaluate session, then the Policy gate.
public struct GatedEvaluate: Sendable {
    public var corePacksReady: Bool { session.corePacksReady }

    private let session: EvaluateSession

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
        await evaluateThenGate(request, cwd: cwd, store: store, now: now, PolicyGate.peek)
    }

    /// Spends a matching grant after an engine deny.
    public func apply(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await evaluateThenGate(request, cwd: cwd, store: store, now: now, PolicyGate.apply)
    }

    private func evaluateThenGate(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date,
        _ gate: (EvaluationResult, String?, AllowOnceStore, Date) async -> PolicyDecision
    ) async -> EvaluationResult {
        await gate(session.evaluate(request), cwd, store, now).result
    }
}
