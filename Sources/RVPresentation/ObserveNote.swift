import RVDomain

/// Label on the observe-mode line of `rv test` / `rv explain`.
package let observeNoteLabel = "Observe mode"

/// Robot `mode` / `effective` when observe let a would-be verdict run.
package let observeRobotMode = "observe"
package let observeRobotEffective = "allow"

/// What observe did with a would-be verdict, or nil when enforce would
/// have allowed it too.
package func observeNote(for wouldBe: Decision) -> String? {
    switch wouldBe {
    case .allow:
        return nil
    case .deny(let deny):
        return "rv would block this (\(deny.ruleID.rawValue)). It logs it and lets it run."
    case .indeterminate:
        return "rv would ask before it runs. It logs it and lets it run."
    }
}
