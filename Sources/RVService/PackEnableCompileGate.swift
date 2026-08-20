import RVDomain
import RVEngine
import RVPacks

/// T9 enable gate: critical/high ICU misses must not silently skip-and-serve.
enum PackEnableCompileGate {
    static func assertBlockingPatternsCompile(packIDs: Set<String>) throws {
        let engine = ICUPatternEngine()
        for id in packIDs.sorted() {
            let snapshot = try PackRegistry.loadDocument(id: id).snapshot
            if let ruleID = firstUncompilableBlockingRule(in: [snapshot], using: engine) {
                throw PacksCommandError.criticalPatternUncompilable(ruleID.rawValue)
            }
        }
    }

    static func firstUncompilableBlockingRule<E: PatternEngine>(
        in snapshots: [PackSnapshot],
        using engine: E
    ) -> RuleID? {
        for pack in snapshots.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            for rule in pack.destructive where rule.severity.blocksByDefault {
                do {
                    _ = try engine.compile(rule.pattern)
                } catch {
                    return RuleID(pack: pack.id, pattern: rule.name)
                }
            }
        }
        return nil
    }
}
