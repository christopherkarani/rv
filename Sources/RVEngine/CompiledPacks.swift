import RVDomain

public struct CompiledNamedPattern<Compiled: Sendable>: Sendable {
    public var name: String
    public var compiled: Compiled
}

public struct CompiledDestructive<Compiled: Sendable>: Sendable {
    public var rule: DestructiveRule
    public var compiled: Compiled
}

public struct CompiledPack<Compiled: Sendable>: Sendable {
    public var snapshot: PackSnapshot
    public var safe: [CompiledNamedPattern<Compiled>]
    public var destructive: [CompiledDestructive<Compiled>]
}

public struct CompiledPacks<Compiled: Sendable>: Sendable {
    public var packs: [CompiledPack<Compiled>]
    public var quarantined: [RuleID]

    public init(packs: [CompiledPack<Compiled>], quarantined: [RuleID] = []) {
        self.packs = packs
        self.quarantined = quarantined
    }

    public static func compile<E: PatternEngine>(
        packs: [PackSnapshot],
        using patterns: E
    ) throws -> CompiledPacks<Compiled> where Compiled == E.Compiled {
        var compiledPacks: [CompiledPack<E.Compiled>] = []
        var quarantined: [RuleID] = []

        for pack in packs {
            var safe: [CompiledNamedPattern<E.Compiled>] = []
            for named in pack.safe {
                do {
                    safe.append(
                        CompiledNamedPattern(name: named.name, compiled: try patterns.compile(named.pattern))
                    )
                } catch {
                    quarantined.append(RuleID(pack: pack.id, pattern: named.name))
                }
            }

            var destructive: [CompiledDestructive<E.Compiled>] = []
            for rule in pack.destructive {
                let ruleID = RuleID(pack: pack.id, pattern: rule.name)
                do {
                    destructive.append(
                        CompiledDestructive(rule: rule, compiled: try patterns.compile(rule.pattern))
                    )
                } catch {
                    if rule.name == "reset-hard" || rule.name == "fork-bomb" {
                        throw PatternCompileError.invalidPattern(
                            name: ruleID.rawValue,
                            message: "required pattern failed to compile"
                        )
                    }
                    quarantined.append(ruleID)
                }
            }

            compiledPacks.append(
                CompiledPack(snapshot: pack, safe: safe, destructive: destructive)
            )
        }

        return CompiledPacks(packs: compiledPacks, quarantined: quarantined)
    }
}
