import RVDomain

/// Label on the observe-mode line of `rv test` / `rv explain`.
package let observeNoteLabel = "Observe mode"

/// Robot `mode` / `effective` when observe mode was read for a verdict
/// that is not an allow: `effective` is `allow` when observe let it run,
/// `deny` when observe still stopped it.
package let observeRobotMode = "observe"
package let observeRobotEffective = "allow"
package let observeRobotStoppedEffective = "deny"

/// Verdict words shared by every observe surface (`rv test`, `rv explain`,
/// `rv blocks`): a real stop and a watched one never read alike.
package let stoppedInEveryModeWords = "✕ Stopped, in every mode"
package let watchedWouldStopWords = "◐ Watched, would stop"
package let watchedWouldAskWords = "◐ Watched, would ask"

/// How observe mode treated a verdict that is not an allow.
public enum ObserveOutcome: Sendable, Equatable {
    /// Observe let the would-be verdict run; enforce would have authorized
    /// it this way (`HookAuthorization.project`, the same projection the
    /// observed denial row's `would_be` comes from).
    case watched(HookAuthorization)
    /// The observe floor kept it (catastrophic, or rv's own protection):
    /// it did not run, in observe as in enforce.
    case stopped
}

/// The observe-mode line for a verdict, or nil when it is an allow (an
/// allow under observe is byte-identical to enforce). `.watched(.ask)`
/// reads "would ask", any other watched verdict "would stop"; an
/// indeterminate is never asked about. `leadingWords` false drops the
/// verdict words, for a frame whose decision line already says them
/// (`rv explain`).
package func observeNote(for verdict: Decision, outcome: ObserveOutcome, leadingWords: Bool = true) -> String? {
    let words = observeDecisionWords(for: outcome)
    let rule: String
    switch verdict {
    case .allow:
        return nil
    case .deny(let deny):
        rule = " (\(deny.ruleID.rawValue))"
    case .indeterminate:
        rule = ""
    }
    let tail: String
    switch (verdict, outcome) {
    case (.indeterminate, .watched):
        tail = ": rv could not finish evaluating it. It logs it and lets it run."
    case (_, .watched):
        tail = "\(rule). It logs it and lets it run."
    case (_, .stopped):
        tail = "\(rule). \(stoppedTail)"
    }
    guard leadingWords == false else { return words + tail }
    switch (verdict, outcome) {
    case (.indeterminate, .watched):
        return "rv could not finish evaluating it. It logs it and lets it run."
    case (_, .watched):
        return "Enforce would \(outcome == .watched(.ask) ? "ask first" : "stop it")\(rule). It logs it and lets it run."
    case (_, .stopped):
        return "It still stops catastrophic commands and anything that touches rv itself\(rule)."
    }
}

/// The verdict words for the decision line under observe.
package func observeDecisionWords(for outcome: ObserveOutcome) -> String {
    switch outcome {
    case .watched(let authorization):
        authorization == .ask ? watchedWouldAskWords : watchedWouldStopWords
    case .stopped:
        stoppedInEveryModeWords
    }
}

private let stoppedTail = "Observe mode still stops catastrophic commands and anything that touches rv itself."
