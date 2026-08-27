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
        now: Date
    ) throws -> RuleSaveOutcome {
        let expected = RulePinning.draft(record: record, polarity: polarity)
        if draft != expected {
            throw RulePinError.draftMismatch
        }
        if polarity == .allow, RulePinning.hardStop(in: record.action) != nil {
            throw RulePinError.hardStop
        }
        let ruleID = RulePinning.ruleID(record: record, polarity: polarity)
        guard let matchingView = RulePinning.matchingView(of: record.action) else {
            return RuleSaveOutcome(ruleID: ruleID)
        }
        switch polarity {
        case .allow:
            try AllowlistStore(baseDirectory: baseDirectory).pin(
                AllowlistEntry(
                    selector: .exactCommand(matchingView),
                    reason: "Always-allow pin",
                    addedAt: now
                )
            )
        case .block:
            try DenylistStore(baseDirectory: baseDirectory).pin(
                DenylistEntry(
                    matchingView: matchingView,
                    reason: "Always-block pin",
                    addedAt: now
                )
            )
        }
        return RuleSaveOutcome(ruleID: ruleID)
    }
}
