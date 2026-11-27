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
/// `rv blocks`), from the locked term cut: a real stop and a would-be one
/// never read alike. Only `rv explain`'s decision line says
/// `stoppedInEveryModeWords`; a row or note says `stoppedWords`.
/// Glyphs from `CommandVocabulary.Glyph`.
package let stoppedWords = "\(CommandVocabulary.Glyph.stopped.rawValue) Stopped"
package let stoppedInEveryModeWords = stoppedWords + ", in every mode"
package let wouldStopWords = "\(CommandVocabulary.Glyph.watched.rawValue) Would stop"
package let wouldAskWords = "\(CommandVocabulary.Glyph.watched.rawValue) Would ask"

/// How observe mode treated a verdict that is not an allow.
public enum ObserveOutcome: Sendable, Equatable {
    /// Observe let the would-be verdict run; enforce would have authorized
    /// it this way (`HookAuthorization.project`, the same projection the
    /// observed denial row's `would_be` comes from).
    case watched(HookAuthorization)
    /// The observe floor kept it (catastrophic, or rv's own protection):
    /// it did not run, in observe as in enforce.
    case stopped
    /// The observe floor stopped what enforce lets run (stopping rvd,
    /// writing rv's install): without rvd an observe hook would let every
    /// later call through, while enforce fails closed. Never "in every
    /// mode".
    case stoppedInObserve

    /// It did not run.
    package var isStop: Bool { self == .stopped || self == .stoppedInObserve }
}

/// The observe-mode line for a verdict, or nil when it is an allow (an
/// allow under observe is byte-identical to enforce). `.watched(.ask)`
/// reads "would ask", any other watched verdict "would stop"; an
/// indeterminate is never asked about. `leadingWords` false drops the
/// verdict words, for a frame whose decision or result line already says
/// them (`rv explain`, `rv test`); `rule` false drops the rule id too, for
/// a result line that already names it.
package func observeNote(
    for verdict: Decision, outcome: ObserveOutcome, leadingWords: Bool = true, rule includesRule: Bool = true
) -> String? {
    let words = observeDecisionWords(for: outcome)
    let rule: String
    switch verdict {
    case .allow:
        return nil
    case .deny(let deny):
        rule = includesRule ? " (\(deny.ruleID.rawValue))" : ""
    case .indeterminate:
        rule = ""
    }
    let tail: String
    switch (verdict, outcome) {
    case (.indeterminate, .watched):
        tail = ": rv could not finish evaluating it. It logs it and lets it run."
    case (_, .watched):
        tail = "\(rule). It logs it and lets it run."
    case (.indeterminate, .stopped):
        tail = ". Enforce stops it too."
    case (_, .stopped):
        tail = "\(rule). \(stoppedTail)"
    case (_, .stoppedInObserve):
        tail = "\(rule). \(observeOnlyTail)"
    }
    guard leadingWords == false else { return words + tail }
    switch (verdict, outcome) {
    case (.indeterminate, .watched):
        return "rv could not finish evaluating it. It logs it and lets it run."
    case (_, .watched):
        return "Enforce would \(outcome == .watched(.ask) ? "ask first" : "stop it")\(rule). It logs it and lets it run."
    case (.indeterminate, .stopped):
        return "Enforce stops it too."
    case (_, .stopped):
        return "It always stops a disk wipe, rm -rf ~ or /, and rv's own files\(rule)."
    case (_, .stoppedInObserve):
        return "Enforce lets it run: without rvd, every call asks first\(rule)."
    }
}

/// The verdict words under observe. `decisionLine`: `rv explain`'s
/// decision line, the one place a stop says "in every mode".
package func observeDecisionWords(for outcome: ObserveOutcome, decisionLine: Bool = false) -> String {
    switch outcome {
    case .watched(let authorization):
        authorization == .ask ? wouldAskWords : wouldStopWords
    case .stopped:
        decisionLine ? stoppedInEveryModeWords : stoppedWords
    case .stoppedInObserve:
        stoppedWords
    }
}

/// Exactly what observe always stops (`ObserveCatastrophe`, `ObserveFloor`).
private let stoppedTail = "Observe mode always stops a disk wipe, rm -rf ~ or /, and rv's own files."
/// A stop observe makes and enforce does not (enforce fails closed without rvd).
private let observeOnlyTail = "rv keeps itself running while it watches."

/// `rv explain`'s reason for a stop only observe makes.
package let observeOnlyStopSentence =
    "rv keeps itself running while it watches, so observe mode sends this to Terminal. Run it in Terminal."
