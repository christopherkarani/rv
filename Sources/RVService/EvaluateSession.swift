import RVDomain
import RVEngine
import RVPacks

public struct EvaluateSession: Sendable {
    public let corePacksReady: Bool

    private let snapshots: [PackSnapshot]
    private let compiled: CompiledPacks<ICUCompiledPattern>
    private let engine: ICUPatternEngine

    public init(snapshots: [PackSnapshot]? = nil) {
        let loaded = snapshots ?? (try? PackRegistry.loadDayOne()) ?? []
        let engine = ICUPatternEngine()
        let warmed = CoreWarmup.prepare(snapshots: loaded, engine: engine)
        self.snapshots = loaded
        self.engine = engine
        self.compiled = warmed.compiled
        self.corePacksReady = warmed.ready
    }

    public static var missingCore: EvaluateSession {
        EvaluateSession(snapshots: [])
    }

    public static var uncompilableCore: EvaluateSession {
        EvaluateSession(snapshots: BrokenCoreSnapshots.uncompilableResetHard())
    }

    public func evaluate(_ request: EvaluationRequest) -> EvaluationResult {
        if !corePacksReady {
            return EvaluationResult(
                decision: .indeterminate(.corePacksUnavailable),
                matchingView: Normalize.matchingView(of: request.command.rawValue)
            )
        }
        return callEngineEvaluate(
            request,
            packs: snapshots,
            engine: engine,
            compiled: compiled
        )
    }
}

private func callEngineEvaluate(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    engine: ICUPatternEngine,
    compiled: CompiledPacks<ICUCompiledPattern>
) -> EvaluationResult {
    evaluate(request, packs: packs, patterns: engine, compiled: compiled)
}
