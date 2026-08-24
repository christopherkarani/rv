import RVDomain
import RVEngine
import RVPacks

public struct EvaluateSession: Sendable {
    public let corePacksReady: Bool

    private let snapshots: [PackSnapshot]
    private let compiled: CompiledPacks<ICUCompiledPattern>
    private let engine: ICUPatternEngine

    public init(
        snapshots: [PackSnapshot]? = nil,
        enabledPacks: [PackID]? = nil
    ) {
        // Nil enabledPacks is the day-one compile set only — not process HOME.
        let compiledIDs = enabledPacks
            ?? PackCoverage.unioningDayOne(WalkedPackIDs(ids: [])).compiled.ids
        self.init(
            loadedSnapshots: EvaluationWorld.resolveSnapshots(snapshots),
            compiledIDs: compiledIDs
        )
    }

    /// Compile-set constructor. Walk lists must go through `PackCoverage` first.
    package init(snapshots: [PackSnapshot]?, compiledPacks: CompiledPackIDs) {
        self.init(
            loadedSnapshots: EvaluationWorld.resolveSnapshots(snapshots),
            compiledIDs: compiledPacks.ids
        )
    }

    private init(loadedSnapshots: [PackSnapshot], compiledIDs: [PackID]) {
        let engine = ICUPatternEngine()
        let warmed = CoreWarmup.prepare(
            snapshots: loadedSnapshots,
            enabledPacks: compiledIDs,
            engine: engine
        )
        self.snapshots = loadedSnapshots
        self.engine = engine
        self.compiled = warmed.compiled
        self.corePacksReady = warmed.ready
    }

    /// Sorted IDs that were compiled for this session. Empty `enabledPacks` compiles none.
    package var compiledPackIDs: [PackID] {
        compiled.packs.map(\.snapshot.id).sorted { $0.rawValue < $1.rawValue }
    }

    public static var missingCore: EvaluateSession {
        EvaluateSession(snapshots: [], enabledPacks: dayOnePackIDs)
    }

    public static var uncompilableCore: EvaluateSession {
        EvaluateSession(
            snapshots: BrokenCoreSnapshots.uncompilableResetHard(),
            enabledPacks: dayOnePackIDs
        )
    }

    public func evaluate(_ request: EvaluationRequest) -> EvaluationResult {
        if !corePacksReady {
            return EvaluationResult(
                outcome: .indeterminate(.corePacksUnavailable),
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
