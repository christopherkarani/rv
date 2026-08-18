import RVDomain
import RVEngine
import RVIPC
import RVPacks

public struct InProcessFallback: Sendable {
    public let corePacksReady: Bool

    private let snapshots: [PackSnapshot]
    private let compiled: CompiledPacks<ICUCompiledPattern>
    private let engine: ICUPatternEngine
    private let catalog: PackCatalog

    public init(snapshots: [PackSnapshot]? = nil, catalog: PackCatalog = PackCatalog()) {
        let loaded = snapshots ?? (try? PackRegistry.loadDayOne()) ?? []
        let engine = ICUPatternEngine()
        let warmed = warmup(snapshots: loaded, engine: engine)
        self.snapshots = loaded
        self.engine = engine
        self.compiled = warmed.compiled
        self.corePacksReady = warmed.ready
        self.catalog = catalog
    }

    public static var missingCore: InProcessFallback {
        InProcessFallback(snapshots: [])
    }

    public static var uncompilableCore: InProcessFallback {
        InProcessFallback(snapshots: uncompilableResetHardSnapshots())
    }

    public func evaluate(_ request: EvaluationRequest) -> EvaluationResult {
        if !corePacksReady {
            return EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
        }
        var resolved = request
        if resolved.enabledPacks.isEmpty {
            resolved.enabledPacks = catalog.enabledIDs
        }
        return engineEvaluate(resolved)
    }

    private func engineEvaluate(_ request: EvaluationRequest) -> EvaluationResult {
        callEngine(request, packs: snapshots, engine: engine, compiled: compiled)
    }

    public func explain(_ request: EvaluationRequest) -> ExplainReply {
        let normalized = Normalize.matchingView(of: request.command.rawValue)
        let result = evaluate(request)
        let stageName: String
        if result.quickRejected {
            stageName = "quickReject"
        } else if result.matched != nil {
            stageName = "destructive"
        } else if result.matchedSafe != nil {
            stageName = "safe"
        } else {
            stageName = "default"
        }
        let suggestion: String?
        switch result.decision {
        case .deny:
            suggestion = "Run it in Terminal, or rv allow-once."
        case .indeterminate:
            suggestion = "Run it in Terminal."
        case .allow:
            suggestion = nil
        }
        return ExplainReply(
            result: result,
            normalized: normalized,
            ruleID: result.matched?.ruleID,
            packID: result.matched?.packID,
            suggestion: suggestion,
            stages: [
                ExplainStage(name: "normalize", elapsedMs: 0),
                ExplainStage(name: stageName, elapsedMs: 0),
            ]
        )
    }

    public func classify(_ request: EvaluationRequest) -> ClassifyReply {
        let result = evaluate(request)
        let risk: ClassifyRisk
        switch result.decision {
        case .allow:
            risk = result.matched.flatMap { ClassifyRisk(rawValue: $0.severity.rawValue) } ?? .safe
        case .deny:
            risk = result.matched.flatMap { ClassifyRisk(rawValue: $0.severity.rawValue) } ?? .high
        case .indeterminate:
            risk = .high
        }
        return ClassifyReply(
            decision: result.decision,
            risk: risk,
            ruleID: result.matched?.ruleID,
            packID: result.matched?.packID
        )
    }

    public func listPacks() -> ListPacksReply {
        let packs = catalog.records.map { PackRecord(id: $0.id, enabled: $0.enabled, bundled: $0.bundled) }
        return ListPacksReply(
            packs: packs,
            enabledCount: packs.filter(\.enabled).count,
            totalCount: packs.count
        )
    }
}

private func warmup(
    snapshots: [PackSnapshot],
    engine: ICUPatternEngine
) -> (compiled: CompiledPacks<ICUCompiledPattern>, ready: Bool) {
    do {
        let compiled = try CompiledPacks.compile(packs: snapshots, using: engine)
        func usable(_ id: PackID) -> Bool {
            guard let pack = snapshots.first(where: { $0.id == id }) else { return false }
            return !pack.safe.isEmpty || !pack.destructive.isEmpty
        }
        func hasRule(_ id: PackID, name: String) -> Bool {
            guard let pack = compiled.packs.first(where: { $0.snapshot.id == id }) else {
                return false
            }
            return pack.destructive.contains { $0.rule.name == name }
        }
        let ready = usable(.coreGit) && usable(.coreFilesystem)
            && hasRule(.coreGit, name: "reset-hard")
            && hasRule(.coreFilesystem, name: "fork-bomb")
        return (compiled, ready)
    } catch {
        return (CompiledPacks(packs: []), false)
    }
}

private func uncompilableResetHardSnapshots() -> [PackSnapshot] {
    [
        PackSnapshot(
            id: .coreFilesystem,
            name: "filesystem",
            description: "core filesystem",
            keywords: ["rm"],
            safe: [NamedPattern(name: "keep", pattern: "rm")],
            destructive: [
                DestructiveRule(
                    name: "fork-bomb",
                    pattern: "(",
                    severity: .critical,
                    reason: "uncompilable required pattern"
                ),
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "core git",
            keywords: ["git"],
            safe: [NamedPattern(name: "keep", pattern: "git")],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: "(",
                    severity: .critical,
                    reason: "uncompilable required pattern"
                ),
            ]
        ),
    ]
}

private func callEngine(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    engine: ICUPatternEngine,
    compiled: CompiledPacks<ICUCompiledPattern>
) -> EvaluationResult {
    evaluate(request, packs: packs, patterns: engine, compiled: compiled)
}
