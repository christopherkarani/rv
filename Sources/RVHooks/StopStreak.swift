import RVDomain

// MARK: - rv notices the third try (North Star B5)
//
// An agent that rephrases a stopped command usually lands on the same rule
// again (`git restore .`, then `git checkout -- .`, then `git checkout .`).
// From the third stop of one rule in a row in one session, the stop says
// so, calmly, on its own line before `who`:
//
//     ✕ Stopped   git checkout . (core.git/checkout-discard)
//     why     discards uncommitted changes
//     again   3 stops for this in a row. Rephrasing won't get through; stop here.
//     who     ask Chris to run  rv allow-once a7c835
//
// The note is not a second instruction: `who` stays the one step, and the
// note never names a command. It changes no verdict. Only rvd counts (in
// memory, `HookEvaluateWorld.countStop`); a stop with no session id, or a
// world with no counter, reads as a first stop. The hook-local pass
// (`rv-hook-local`) has no counter: every deny a person can lift goes on
// to rvd and is counted there, but a pinned deny it answers itself reads
// as a first stop.

/// One agent session's stops of one rule, as rvd counts them.
public struct StopStreakKey: Hashable, Sendable {
    public var host: HookHost
    public var session: SessionID
    /// The deny's rule id, or `rv.indeterminate:<reason>`.
    public var rule: String

    public init(host: HookHost, session: SessionID, rule: String) {
        self.host = host
        self.session = session
        self.rule = rule
    }
}

/// The stop count from which a stop carries the note.
public let stopStreakNoticeFrom = 3

/// The `again` line's text for a streak, or nil below `stopStreakNoticeFrom`.
public func stopStreakNote(_ streak: Int) -> String? {
    guard streak >= stopStreakNoticeFrom else { return nil }
    return "\(streak) stops for this in a row. Rephrasing won't get through; stop here."
}

/// The key a stop of `result` counts under, or nil when nothing stopped
/// (an allow, including an observe would-be) or the call has no session.
func stopStreakKey(
    _ result: EvaluationResult, verdict: HostAskVerdict? = nil, host: HookHost, session: SessionID?
) -> StopStreakKey? {
    guard let session, verdict != .allow else { return nil }
    switch result.decision {
    case .allow:
        return nil
    case .deny(let deny):
        return StopStreakKey(host: host, session: session, rule: deny.ruleID.rawValue)
    case .indeterminate(let reason):
        return StopStreakKey(
            host: host, session: session, rule: "rv.indeterminate:\(reason?.rawValue ?? "incomplete")")
    }
}

extension HookEvaluateWorld {
    /// `voice` with the streak of the stop `result` shows, counted once.
    func voice(countingStopOf result: EvaluationResult, verdict: HostAskVerdict?, request: HookRequest) -> StopVoice {
        guard let countStop,
              let key = stopStreakKey(result, verdict: verdict, host: request.host, session: request.session)
        else { return voice }
        var voice = voice
        voice.streak = countStop(key)
        return voice
    }
}
