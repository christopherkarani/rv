import RVDomain

/// Label on the observe-mode line of `rv test` / `rv explain`.
package let observeNoteLabel = "Observe mode"

/// Robot `mode` / `effective` when observe let a would-be verdict run.
package let observeRobotMode = "observe"
package let observeRobotEffective = "allow"

/// What observe did with a would-be verdict, or nil when enforce would
/// have allowed it too. `authorization` is enforce's projection of that
/// verdict (`HookAuthorization.project`), the same one the observed
/// denial row's `would_be` comes from: `.ask` reads "would ask", a pinned
/// deny "would block". An indeterminate is never asked about.
package func observeNote(for wouldBe: Decision, authorization: HookAuthorization) -> String? {
    let tail = "It logs it and lets it run."
    switch wouldBe {
    case .allow:
        return nil
    case .deny(let deny):
        let rule = deny.ruleID.rawValue
        return authorization == .ask
            ? "rv would ask before it runs this (\(rule)). \(tail)"
            : "rv would block this (\(rule)). \(tail)"
    case .indeterminate:
        return "rv would block this: it could not finish evaluating it. \(tail)"
    }
}
