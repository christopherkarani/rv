import RVDomain
import RVEngine
import RVPacks

public struct EvaluateSession: Sendable {
    public let corePacksReady: Bool

    private let snapshots: [PackSnapshot]
    private let compiled: CompiledPacks<ICUCompiledPattern>
    private let engine: ICUPatternEngine

    /// Compile-set constructor. `nil` compiles day-one only (empty walk ∪ day-one),
    /// not process HOME. A non-nil list is compiled as given and is not unioned
    /// with day-one — pass walk lists through `PackCoverage` first.
    public init(
        snapshots: [PackSnapshot]? = nil,
        enabledPacks: [PackID]? = nil
    ) {
        if let enabledPacks {
            self.init(
                loadedSnapshots: EvaluationWorld.resolveSnapshots(snapshots),
                compiledIDs: enabledPacks
            )
        } else {
            self.init(
                snapshots: snapshots,
                compiledPacks: PackCoverage.unioningDayOne(WalkedPackIDs(ids: [])).compiled
            )
        }
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

    public func evaluate(
        _ request: EvaluationRequest,
        safety: SafetyLevel = .normal,
        allowPaths: SecretAllowPathSet = .empty,
        home: String? = nil
    ) -> EvaluationResult {
        if !corePacksReady {
            return EvaluationResult(
                outcome: .indeterminate(.corePacksUnavailable),
                matchingView: Normalize.matchingView(of: request.command.rawValue)
            )
        }
        return engineEvaluate(
            request,
            packs: snapshots,
            safety: safety,
            allowPaths: allowPaths,
            home: home,
            engine: engine,
            compiled: compiled
        )
    }

    /// The evaluation door on this session's compiled packs: pack evaluate,
    /// then unwrap, analyze, and apply semantic policy. Path / cwd / repo I/O
    /// stays with the caller via `filesystemProbe`.
    ///
    /// Missing core packs stay `indeterminate` for every command, including empty
    /// input that bare `evaluate` would allow. The Engine door still runs so
    /// unwrap / probe / analyze attach; the session then floors the outcome.
    public func evaluateWithSemantics(
        _ request: EvaluationRequest,
        safety: SafetyLevel = .normal,
        allowPaths: SecretAllowPathSet = .empty,
        home: String? = nil,
        gitContext: GitAnalysisContext = .empty,
        filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisContext = { _ in .empty },
        policy: EffectiveActionPolicy = .empty
    ) -> EvaluationResult {
        let result = engineEvaluateWithSemantics(
            request,
            packs: snapshots,
            safety: safety,
            allowPaths: allowPaths,
            home: home,
            engine: engine,
            compiled: compiled,
            gitContext: gitContext,
            filesystemProbe: filesystemProbe,
            policy: policy
        )
        guard corePacksReady else {
            return EvaluationResult(
                outcome: .indeterminate(.corePacksUnavailable),
                matchingView: Normalize.matchingView(of: request.command.rawValue),
                analysis: result.analysis
            )
        }
        return result
    }
}

// The `RVEngine` anchor enum shadows the module name and the members shadow
// the globals inside the struct, so the Engine doors are reached through
// file-private shims. Not indirection for its own sake — name collision.
private func engineEvaluate(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    safety: SafetyLevel,
    allowPaths: SecretAllowPathSet,
    home: String?,
    engine: ICUPatternEngine,
    compiled: CompiledPacks<ICUCompiledPattern>
) -> EvaluationResult {
    evaluate(
        request,
        packs: packs,
        safety: safety,
        allowPaths: allowPaths,
        home: home,
        patterns: engine,
        compiled: compiled
    )
}

private func engineEvaluateWithSemantics(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    safety: SafetyLevel,
    allowPaths: SecretAllowPathSet,
    home: String?,
    engine: ICUPatternEngine,
    compiled: CompiledPacks<ICUCompiledPattern>,
    gitContext: GitAnalysisContext,
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisContext,
    policy: EffectiveActionPolicy
) -> EvaluationResult {
    evaluateWithSemantics(
        request,
        packs: packs,
        safety: safety,
        allowPaths: allowPaths,
        home: home,
        patterns: engine,
        compiled: compiled,
        gitContext: gitContext,
        filesystemProbe: filesystemProbe,
        policy: policy
    )
}
