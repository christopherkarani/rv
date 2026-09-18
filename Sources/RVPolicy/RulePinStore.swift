import Foundation
import RVDomain

public struct RulePinStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Exact-command pins require a T1 `matchingView` (Policy does not peel).
    /// Typed git-push pins ignore it; their identity is the predicate.
    public func save(
        record: PendingApproval,
        polarity: PinnedRulePolarity,
        draft: String,
        now: Date,
        matchingView: MatchingView? = nil
    ) throws -> RuleSaveOutcome {
        let expected = RulePinning.draft(record: record, polarity: polarity)
        if draft != expected {
            throw RulePinError.draftMismatch
        }
        if polarity == .allow, RulePinning.hardStop(in: record.action) != nil {
            throw RulePinError.hardStop
        }
        if let predicate = typedPredicate(from: draft) {
            let ruleID = RulePinning.ruleID(polarity: polarity, predicate: predicate)
            try persistTypedRule(
                TypedRule(
                    id: ruleID,
                    predicate: predicate,
                    verdict: polarity == .block ? .deny : .allow,
                    origin: .machine
                )
            )
            return RuleSaveOutcome(ruleID: ruleID)
        }
        guard let view = matchingView, view.isEmpty == false else {
            throw RulePinError.missingMatchingView
        }
        let ruleID = RulePinning.ruleID(polarity: polarity, matchingView: view)
        switch polarity {
        case .allow:
            try AllowlistStore(baseDirectory: baseDirectory).pin(
                AllowlistEntry(
                    selector: .exactCommand(view),
                    reason: "Always-allow pin",
                    addedAt: now
                )
            )
        case .block:
            try DenylistStore(baseDirectory: baseDirectory).pin(
                DenylistEntry(
                    matchingView: view,
                    reason: "Always-block pin",
                    addedAt: now
                )
            )
        }
        return RuleSaveOutcome(ruleID: ruleID)
    }

    /// v2 git-push draft from `RulePinning`. Fingerprint v1 drafts have no predicate.
    private func typedPredicate(from draft: String) -> PolicyPredicate? {
        guard let data = draft.data(using: .utf8) else {
            return nil
        }
        struct TypedPinDraftBody: Decodable {
            var predicate: PolicyPredicate
            var v: Int
        }
        do {
            let body = try JSONDecoder().decode(TypedPinDraftBody.self, from: data)
            guard body.v == 2 else {
                return nil
            }
            return body.predicate
        } catch {
            return nil
        }
    }

    private func persistTypedRule(_ rule: TypedRule) throws {
        let store = TypedRuleStore(baseDirectory: baseDirectory)
        var rules = try store.loadMachine()
        if let index = rules.firstIndex(where: { $0.predicate == rule.predicate }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        try store.saveMachine(rules)
    }
}
