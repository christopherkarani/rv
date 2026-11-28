import RVDomain
import RVPacks

/// A rule's words from the shipped pack JSON, for `rv why`: the pattern's
/// reason and its guidance. Reads JSON only; nothing is compiled.
package struct RuleFacts: Equatable, Sendable {
    package var reason: String?
    package var saferCommand: String?
    package var whoActs: String?

    package static func lookup(_ id: RuleID) -> RuleFacts {
        let reason = (try? PackRegistry.loadAll())?
            .first { $0.id == id.pack }?
            .destructive.first { $0.name == id.pattern }?
            .reason
        let guidance = (try? PackRegistry.loadRuleGuidance())?[id]
        return RuleFacts(reason: reason, saferCommand: guidance?.saferCommand, whoActs: guidance?.whoActs)
    }
}
