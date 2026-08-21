import Foundation
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
        let loaded: [PackSnapshot]
        if let snapshots {
            loaded = snapshots
        } else {
            // Prefer full catalog; fall back to day-one if index is missing.
            loaded = (try? PackRegistry.loadAll()) ?? ((try? PackRegistry.loadDayOne()) ?? [])
        }
        let enabled: [PackID]
        if let enabledPacks {
            enabled = enabledPacks
        } else {
            // Config extras plus day-one. Catalog disable of core must not
            // uncompile required rules (request evaluate set stays day-one).
            var ids = (try? PacksFacade.effectiveIDs(home: processHOME())) ?? dayOnePackIDs
            for id in dayOnePackIDs where !ids.contains(id) {
                ids.append(id)
            }
            enabled = ids
        }
        let engine = ICUPatternEngine()
        let warmed = CoreWarmup.prepare(
            snapshots: loaded,
            enabledPacks: enabled,
            engine: engine
        )
        self.snapshots = loaded
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

private func processHOME() -> String {
    ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? ""
}
