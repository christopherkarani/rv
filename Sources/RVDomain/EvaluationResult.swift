public struct MatchSpan: Sendable, Equatable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct RuleMatch: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var packID: PackID
    public var patternName: String
    public var severity: Severity
    public var reason: String
    public var explanation: String?
    public var regex: String?
    public var span: MatchSpan?
    public var matchedText: String?
    public var searchText: String?

    public init(
        ruleID: RuleID,
        packID: PackID,
        patternName: String,
        severity: Severity,
        reason: String,
        explanation: String? = nil,
        regex: String? = nil,
        span: MatchSpan? = nil,
        matchedText: String? = nil,
        searchText: String? = nil
    ) {
        self.ruleID = ruleID
        self.packID = packID
        self.patternName = patternName
        self.severity = severity
        self.reason = reason
        self.explanation = explanation
        self.regex = regex
        self.span = span
        self.matchedText = matchedText
        self.searchText = searchText
    }
}

public struct SafeMatch: Sendable, Equatable, Codable {
    public var packID: PackID
    public var patternName: String

    public init(packID: PackID, patternName: String) {
        self.packID = packID
        self.patternName = patternName
    }

    /// pack:pattern, same construction as `RuleMatch.ruleID`.
    public var ruleID: RuleID {
        RuleID(pack: packID, pattern: patternName)
    }
}

/// How an evaluation reached its verdict. Closed over exactly the field
/// combinations `evaluate` produces; parallel-field states are unrepresentable.
public enum EvaluationOutcome: Sendable, Equatable {
    /// allow, quick-reject fired before any walker ran.
    case quickRejected
    /// allow, no hits.
    case plain
    /// allow, safe rule hit only.
    case safeOnly(SafeMatch)
    /// allow, destructive rule hit below block severity, plus optional safe hit.
    case hit(RuleMatch, safe: SafeMatch?)
    /// deny, with the matching rule when the walker recorded it.
    case deny(Deny, matched: RuleMatch?)
    case indeterminate(IndeterminateReason)
}

extension EvaluationOutcome {
    /// The public verdict this outcome projects onto.
    public var decision: Decision {
        switch self {
        case .quickRejected, .plain, .safeOnly, .hit:
            return .allow
        case .deny(let deny, _):
            return .deny(deny)
        case .indeterminate(let reason):
            return .indeterminate(reason)
        }
    }

    /// Explain/classify rule identity. Deny uses `Deny.ruleID`, never `matched?.ruleID`.
    public var explainRuleID: RuleID? {
        switch self {
        case .hit(let match, _):
            return match.ruleID
        case .deny(let deny, _):
            return deny.ruleID
        case .quickRejected, .plain, .safeOnly, .indeterminate:
            return nil
        }
    }

    /// Explain/classify pack identity. Deny uses `Deny.ruleID.pack`.
    public var explainPackID: PackID? {
        switch self {
        case .hit(let match, _):
            return match.packID
        case .safeOnly(let safe):
            return safe.packID
        case .deny(let deny, _):
            return deny.ruleID.pack
        case .quickRejected, .plain, .indeterminate:
            return nil
        }
    }

    var matched: RuleMatch? {
        switch self {
        case .hit(let match, _):
            return match
        case .deny(_, let match):
            return match
        case .quickRejected, .plain, .safeOnly, .indeterminate:
            return nil
        }
    }

    var matchedSafe: SafeMatch? {
        switch self {
        case .hit(_, let safe):
            return safe
        case .safeOnly(let safe):
            return safe
        case .quickRejected, .plain, .deny, .indeterminate:
            return nil
        }
    }

    var quickRejected: Bool {
        if case .quickRejected = self { return true }
        return false
    }

    static func composing(
        decision: Decision,
        matched: RuleMatch?,
        matchedSafe: SafeMatch?,
        quickRejected: Bool
    ) throws(EvaluationResultDecodingError) -> EvaluationOutcome {
        switch decision {
        case .allow:
            if quickRejected {
                if matched == nil, matchedSafe == nil {
                    return .quickRejected
                }
            } else if let matched {
                return .hit(matched, safe: matchedSafe)
            } else if let matchedSafe {
                return .safeOnly(matchedSafe)
            } else {
                return .plain
            }
        case .deny(let deny):
            if !quickRejected, matchedSafe == nil {
                return .deny(deny, matched: matched)
            }
        case .indeterminate(let reason):
            if matched == nil, matchedSafe == nil, !quickRejected {
                return .indeterminate(reason)
            }
        }
        throw EvaluationResultDecodingError(
            decision: decision,
            matchedPresent: matched != nil,
            matchedSafePresent: matchedSafe != nil,
            quickRejected: quickRejected
        )
    }
}

/// Wire-level rejection of EvaluationResult field combinations no producer emits.
public struct EvaluationResultDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    public let decision: Decision
    public let matchedPresent: Bool
    public let matchedSafePresent: Bool
    public let quickRejected: Bool

    public var description: String {
        "impossible EvaluationResult combination: decision=\(decision) "
            + "matched=\(matchedPresent) matchedSafe=\(matchedSafePresent) "
            + "quickRejected=\(quickRejected)"
    }

    init(
        decision: Decision,
        matchedPresent: Bool,
        matchedSafePresent: Bool,
        quickRejected: Bool
    ) {
        self.decision = decision
        self.matchedPresent = matchedPresent
        self.matchedSafePresent = matchedSafePresent
        self.quickRejected = quickRejected
    }
}

public struct EvaluationResult: Sendable, Equatable {
    public var outcome: EvaluationOutcome
    /// T1-normalized command text this result was decided on.
    public var matchingView: MatchingView
    /// Typed analyzer hit. `.unknown` is omitted from the evaluate wire.
    public var analysis: SemanticAnalysis
    /// In-process hard-policy bind for the hook door. Not on the Codable wire.
    public var boundReview: BoundReview?

    public var decision: Decision { outcome.decision }

    public init(
        outcome: EvaluationOutcome,
        matchingView: MatchingView = MatchingView(""),
        analysis: SemanticAnalysis = .unknown
    ) {
        self.init(
            outcome: outcome,
            matchingView: matchingView,
            analysis: analysis,
            boundReview: nil
        )
    }

    public init(
        outcome: EvaluationOutcome,
        matchingView: MatchingView,
        analysis: SemanticAnalysis,
        boundReview: BoundReview?
    ) {
        self.outcome = outcome
        self.matchingView = matchingView
        self.analysis = analysis
        self.boundReview = boundReview
    }

    /// Codable / IPC projection. Never carries `boundReview`.
    public var wire: EvaluationResult {
        EvaluationResult(outcome: outcome, matchingView: matchingView, analysis: analysis)
    }

    /// Hook-door evaluation. `bound` is always present: the in-process
    /// field, or the pack projection when the field is nil. `live.result`
    /// is this session — pack projection does not write the field.
    public var live: LiveEvaluation {
        LiveEvaluation(self)
    }

    /// Host-door pending identity. Fingerprint is `ActionFingerprint.make`, never
    /// analyzer `shell:git.*` / `shell:fs.*`. Effects come from analyzed git or
    /// filesystem actions; unknown and unwrap-limited may be empty.
    public func pendingAction(
        host: HookHost,
        session: SessionID?,
        cwd: WorkingDirectory?,
        command: ShellCommand
    ) -> ProposedAction {
        let analyzed: (ActionEffects, ActionResources, SemanticAction?)
        switch analysis.innermost {
        case .git(let git):
            analyzed = (git.effects, git.resources, .git(git))
        case .filesystem(let filesystem):
            analyzed = (filesystem.effects, filesystem.resources, .filesystem(filesystem))
        case .wrapper, .unwrapLimited, .unknown:
            analyzed = (ActionEffects(), ActionResources(), nil)
        }
        return .shell(
            ShellAction(
                fingerprint: ActionFingerprint.make(
                    host: host,
                    session: session,
                    cwd: cwd,
                    command: command
                ),
                effects: analyzed.0,
                resources: analyzed.1,
                scope: ActionScope(workingDirectory: cwd),
                supportingCommand: command,
                analysis: analyzed.2
            )
        )
    }
}

/// Hook-door evaluation. `bound` is always present.
///
/// The Evaluate session field stays optional so a pack deny can still reach
/// the Policy gate and mint. Ask and encode read `bound`: the session field
/// if present, otherwise `BoundReview.packProjected`. `result` is that
/// session, not a reconstructed bind — pack projection must not skip
/// allow-once. IPC `wire` still strips the field; `bound` rebuilds pack
/// projection from the decoded decision.
public struct LiveEvaluation: Sendable, Equatable {
    /// Evaluate session this hook-door view was projected from.
    public var result: EvaluationResult

    public var outcome: EvaluationOutcome { result.outcome }
    public var matchingView: MatchingView { result.matchingView }
    public var analysis: SemanticAnalysis { result.analysis }
    public var bound: BoundReview { BoundReview.packProjected(from: result) }
    public var decision: Decision { result.decision }

    /// Codable / IPC projection. Never carries `bound`.
    public var wire: EvaluationResult { result.wire }

    public init(
        outcome: EvaluationOutcome,
        matchingView: MatchingView,
        analysis: SemanticAnalysis,
        bound: BoundReview
    ) {
        self.result = EvaluationResult(
            outcome: outcome,
            matchingView: matchingView,
            analysis: analysis,
            boundReview: bound
        )
    }

    /// Creates the hook-door evaluation from an Evaluate session result.
    public init(_ result: EvaluationResult) {
        self.result = result
    }
}

extension EvaluationResult: Codable {
    enum CodingKeys: String, CodingKey {
        case decision
        case matched
        case matchedSafe
        case quickRejected
        case matchingView
        case analysis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decision = try container.decode(Decision.self, forKey: .decision)
        let matched = try container.decodeIfPresent(RuleMatch.self, forKey: .matched)
        let matchedSafe = try container.decodeIfPresent(SafeMatch.self, forKey: .matchedSafe)
        let quickRejected = try container.decodeIfPresent(Bool.self, forKey: .quickRejected) ?? false
        outcome = try .composing(
            decision: decision,
            matched: matched,
            matchedSafe: matchedSafe,
            quickRejected: quickRejected
        )
        matchingView = try container.decodeIfPresent(MatchingView.self, forKey: .matchingView)
            ?? MatchingView("")
        analysis = try container.decodeIfPresent(SemanticAnalysis.self, forKey: .analysis) ?? .unknown
        boundReview = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome.decision, forKey: .decision)
        if let matched = outcome.matched {
            try container.encode(matched, forKey: .matched)
        }
        if let matchedSafe = outcome.matchedSafe {
            try container.encode(matchedSafe, forKey: .matchedSafe)
        }
        try container.encode(outcome.quickRejected, forKey: .quickRejected)
        try container.encode(matchingView, forKey: .matchingView)
        if analysis != .unknown {
            try container.encode(analysis, forKey: .analysis)
        }
    }
}
