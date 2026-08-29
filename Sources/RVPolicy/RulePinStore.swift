import Foundation
import RVDomain

public struct RulePinStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

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
        let view = matchingView ?? RulePinning.matchingView(of: record.action)
        guard let view, view.isEmpty == false else {
            throw RulePinError.missingMatchingView
        }
        let ruleID = RulePinning.ruleID(record: record, polarity: polarity)
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
}
