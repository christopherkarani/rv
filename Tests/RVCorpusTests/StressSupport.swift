import Foundation
import RVDomain
import RVEngine
import RVPacks

struct StressHarness: Sendable {
    var packs: [PackSnapshot]
    var engine: ICUPatternEngine
    var compiled: CompiledPacks<ICUCompiledPattern>

    static func dayOne() throws -> StressHarness {
        try StressHarness(packs: PackRegistry.loadDayOne())
    }

    static func catalog() throws -> StressHarness {
        try StressHarness(packs: PackRegistry.loadAll())
    }

    init(packs: [PackSnapshot]) throws {
        self.packs = packs
        engine = ICUPatternEngine()
        compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    }

    func pin(_ command: String, enabled: [PackID] = dayOnePackIDs) -> EvaluationResult {
        evaluate(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: enabled),
            packs: packs,
            engine: engine,
            compiled: compiled
        )
    }

    func door(_ command: String, enabled: [PackID] = dayOnePackIDs) -> EvaluationResult {
        evaluateWithSemantics(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: enabled),
            packs: packs,
            engine: engine,
            compiled: compiled
        )
    }
}

func describeDecision(_ result: EvaluationResult) -> String {
    switch result.decision {
    case .allow:
        if let ruleID = result.matched?.ruleID.rawValue {
            return "allow+\(ruleID)"
        }
        return "allow"
    case .deny(let deny):
        return "deny \(deny.ruleID.rawValue)"
    case .indeterminate(let reason):
        return "indeterminate \(reason.rawValue)"
    }
}

func corpusFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus")
        .appendingPathComponent(name)
}

func loadStressCorpus(_ name: String) throws -> [CorpusCase] {
    let data = try Data(contentsOf: corpusFixtureURL(name))
    return try JSONDecoder().decode(CorpusFile.self, from: data)
        .cases
}

func uniquePackIDs(_ ids: [PackID]) -> [PackID] {
    var seen = Set<PackID>()
    var out: [PackID] = []
    for id in ids where seen.insert(id).inserted {
        out.append(id)
    }
    return out
}
