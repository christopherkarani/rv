import Foundation
import RVDomain

public struct ExplainSemanticView: Equatable, Sendable {
    public var action: String
    public var scope: String
    public var effect: String?
    public var remote: String?
    public var ref: String?
    public var pathspec: String?
    public var path: String?
    public var kind: String?
    public var category: String?
    public var catalogRule: String?
    public var wrappers: [String]?

    public init(
        action: String,
        scope: String,
        effect: String? = nil,
        remote: String? = nil,
        ref: String? = nil,
        pathspec: String? = nil,
        path: String? = nil,
        kind: String? = nil,
        category: String? = nil,
        catalogRule: String? = nil,
        wrappers: [String]? = nil
    ) {
        self.action = action
        self.scope = scope
        self.effect = effect
        self.remote = remote
        self.ref = ref
        self.pathspec = pathspec
        self.path = path
        self.kind = kind
        self.category = category
        self.catalogRule = catalogRule
        self.wrappers = wrappers
    }
}

public struct ExplainViewModel: Equatable, Sendable {
    public var command: ShellCommand
    public var normalized: String
    public var decision: Decision
    public var packID: PackID?
    public var ruleID: RuleID?
    public var patternName: String?
    public var severity: Severity?
    public var fact: String
    public var explanation: String?
    public var regex: String?
    public var nextAction: String?
    public var steps: [ExplainStep]
    public var suggestions: [ExplainSuggestion]
    public var semantic: ExplainSemanticView?
    /// Observe-mode note, when observe mode was read for a verdict that is
    /// not an allow: watched (it ran) or stopped (in every mode).
    package var observeNote: String?
    /// The observe note says the observe floor stopped it (in every mode),
    /// not that observe let it run.
    package var observeStopped = false
    /// Typed rules that also match but did not decide, shown before Next.
    package var alsoMatches: [ExplainAlsoMatch] = []
    /// Packs that are off but would stop the command (G2), shown before Next.
    package var offPacks: [ExplainOffPack] = []

    public var heading: String { explainHeading }
    public var decisionWord: String { decision.displayName }
    /// Under observe, the decision line names what happened instead of the
    /// bare verdict word: `◐ Would stop`
    /// (it ran) or `✕ Stopped, in every mode` (it did not).
    package var observeDecisionWords: String?
    public var explainDecisionWord: String { observeDecisionWords ?? decision.emphasizedName }
    public var decisionTone: DecisionTone { decision.tone }
    public var ruleDisplay: String? { ruleID.map(\.slashDisplay) }
    public var packDisplay: String? { packID?.rawValue }
    public var severityDisplay: String? { severity?.rawValue }

    public init(
        command: ShellCommand,
        normalized: String,
        decision: Decision,
        packID: PackID?,
        ruleID: RuleID?,
        fact: String,
        nextAction: String?,
        steps: [ExplainStep],
        patternName: String? = nil,
        severity: Severity? = nil,
        explanation: String? = nil,
        regex: String? = nil,
        suggestions: [ExplainSuggestion] = [],
        semantic: ExplainSemanticView? = nil,
        observeNote: String? = nil,
        observeStopped: Bool = false
    ) {
        self.command = command
        self.normalized = normalized
        self.decision = decision
        self.packID = packID
        self.ruleID = ruleID
        self.patternName = patternName
        self.severity = severity
        self.fact = fact
        self.explanation = explanation
        self.regex = regex
        self.nextAction = nextAction
        self.steps = steps
        self.suggestions = suggestions
        self.semantic = semantic
        self.observeNote = observeNote
        self.observeStopped = observeStopped && observeNote != nil
    }
}

/// `observed`: what observe mode did with `result` (watched: the would-be
/// verdict ran; stopped: the observe floor kept it); adds the observe note.
public func explainViewModel(
    from result: EvaluationResult,
    command: ShellCommand,
    normalized: String? = nil,
    observed: ObserveOutcome? = nil
) -> ExplainViewModel {
    let fact: String
    let next: String?
    switch result.outcome {
    case .quickRejected, .plain, .safeOnly, .hit:
        fact = "allow"
        next = nil
    case .deny(let deny, _):
        fact = factSentence(from: deny.reason)
        next = denyNextAction
    case .indeterminate(let reason):
        // A stop only observe makes (stopping rvd) was evaluated, not left
        // unfinished: say why it stopped.
        fact = observed == .stoppedInObserve ? observeOnlyStopSentence : indeterminateSentence(reason)
        next = nil
    }
    // A watched verdict ran: no "run it in Terminal, or rv allow-once"
    // advice for a command observe already let through.
    let watched: Bool
    if case .watched = observed, result.decision != .allow { watched = true } else { watched = false }
    let packID = result.outcome.explainPackID
    let ruleID = result.outcome.explainRuleID
    let match = result.matched

    var model = ExplainViewModel(
        command: command,
        normalized: normalized ?? command.rawValue,
        decision: result.decision,
        packID: packID,
        ruleID: ruleID,
        fact: fact,
        nextAction: watched ? nil : next,
        steps: explainSteps(from: result),
        patternName: match?.patternName,
        severity: match?.severity,
        explanation: match?.explanation,
        regex: match?.regex,
        suggestions: ruleID.map { suggestions(for: $0) } ?? [],
        semantic: explainSemantic(from: result.analysis),
        observeNote: observed.flatMap { observeNote(for: result.decision, outcome: $0, leadingWords: false) },
        observeStopped: (observed?.isStop ?? false) && result.decision != .allow
    )
    if result.decision != .allow {
        model.observeDecisionWords = observed.map { observeDecisionWords(for: $0, decisionLine: true) }
    }
    return model
}

package func explainSemantic(from analysis: SemanticAnalysis) -> ExplainSemanticView? {
    let layers = analysis.wrappers.map(\.rawValue)
    let wrapperLabels = layers.isEmpty ? nil : layers
    switch analysis.innermost {
    case .git(let action):
        return ExplainSemanticView(
            action: action.explainAction,
            scope: action.explainScope,
            effect: action.explainEffect,
            remote: action.explainRemote,
            ref: action.explainRef,
            pathspec: action.explainPathspec,
            wrappers: wrapperLabels
        )
    case .filesystem(let action):
        return ExplainSemanticView(
            action: action.explainAction,
            scope: action.explainScope,
            effect: action.explainEffect,
            path: action.explainPath,
            kind: action.explainKind,
            category: action.explainCategory,
            catalogRule: action.explainCatalogRule,
            wrappers: wrapperLabels
        )
    case .unwrapLimited:
        return ExplainSemanticView(
            action: "unwrap limit exceeded",
            scope: "fail-closed",
            wrappers: wrapperLabels
        )
    case .wrapper:
        return nil
    case .unknown:
        if let wrapperLabels {
            return ExplainSemanticView(
                action: "unknown",
                scope: "wrapper",
                wrappers: wrapperLabels
            )
        }
        return nil
    }
}

// MARK: - rv why <code>

/// What the CLI knows about one rule when it tells a decision's story:
/// the pack's reason and its guidance. Plain values; the CLI reads packs.
public struct DecisionRuleFacts: Equatable, Sendable {
    /// The pack pattern's reason (`Git reset --hard destroys uncommitted changes`).
    public var reason: String?
    /// A command rv allows instead, ready to copy.
    public var saferCommand: String?
    /// Who has to act when there is no safer command.
    public var whoActs: String?

    public init(reason: String? = nil, saferCommand: String? = nil, whoActs: String? = nil) {
        self.reason = reason
        self.saferCommand = saferCommand
        self.whoActs = whoActs
    }
}

/// `rv why <code>`: the full story of one decision rv logged, found by the
/// code `rv log` prints. Built from a log row, never by re-running the
/// command: the recorded command is redacted, so evaluating it again could
/// tell a different story.
public struct DecisionStory: Equatable, Sendable {
    /// What happened, in the v5c words, kept apart from the rule so a stop
    /// can never read as a would-stop.
    public enum Outcome: Equatable, Sendable {
        /// It did not run.
        case stopped
        /// Watch mode let it run; guarding would have stopped it.
        case wouldStop
        /// Watch mode let it run; guarding would have asked a person.
        case wouldAsk

        public var glyph: CommandVocabulary.Glyph {
            switch self {
            case .stopped: .stopped
            case .wouldStop, .wouldAsk: .watched
            }
        }

        /// `✕ Stopped`, `◐ Would stop`.
        public var label: String {
            let word = glyph.eventWord ?? glyph.word
            return glyph.rawValue + " " + word.prefix(1).uppercased() + word.dropFirst()
        }
    }

    /// What kind of rule made the decision.
    public enum Source: Equatable, Sendable {
        /// A pack or typed rule.
        case rule
        /// rv guarding itself: its settings, its files, its daemon.
        case selfProtection
        /// rv could not see what the command runs, or could not finish.
        case couldNotCheck
    }

    public var code: String
    public var outcome: Outcome
    public var source: Source
    /// The recorded command (redacted), the tool and its redacted path, or the tool.
    public var command: String
    /// `Sat 21 Nov 14:02 · claude · in ~/code/app`.
    public var context: String
    /// Why, in plain words.
    public var why: String
    public var rule: String
    /// A safer command rv allows, when the rule has one.
    public var safer: String?
    /// Who has to act.
    public var who: String?
    /// The stop holds in watch mode too.
    public var holdsInEveryMode: Bool
    /// rvd kept no command text for this row.
    public var commandMissing: Bool

    /// - Parameters:
    ///   - entry: the `rv log` row the code names.
    ///   - cwd: the working directory the decision log kept, home as `~`.
    ///   - facts: the rule's reason and guidance, when its pack has them.
    public init(entry: LogEntry, cwd: String? = nil, facts: DecisionRuleFacts = DecisionRuleFacts(), calendar: Calendar) {
        self.code = entry.code ?? ""
        self.outcome = entry.stopped ? .stopped : (entry.wouldAsk ? .wouldAsk : .wouldStop)
        self.source = Self.source(rule: entry.rule)
        self.rule = DisplayedText.field(entry.rule)
        let target = DisplayedText.field(entry.target)
        if let command = entry.command, command.isEmpty == false {
            self.command = DisplayedText.field(command)
        } else {
            self.command = target.isEmpty ? entry.tool : "\(entry.tool) \(target)"
        }
        self.commandMissing = entry.tool == "Bash" && (entry.command?.isEmpty ?? true)
        let when = LogViewModel.dayLabel(entry.time, calendar: calendar) + " "
            + LogViewModel.timeLabel(entry.time, calendar: calendar)
        self.context = ([when, DisplayedText.field(entry.agent)] + (cwd.map { ["in " + DisplayedText.field($0)] } ?? []))
            .joined(separator: " · ")
        switch source {
        case .selfProtection:
            self.why = Self.selfProtectionWhy(rule: entry.rule)
            self.safer = Self.selfProtectionSafer(rule: entry.rule)
            self.who = Self.personInTerminal
            self.holdsInEveryMode = true
        case .couldNotCheck:
            self.why = Self.couldNotCheckWhy(rule: entry.rule)
            self.safer = nil
            self.who = Self.personInTerminal
            self.holdsInEveryMode = entry.stopped
        case .rule:
            self.why = facts.reason.map(DisplayedText.field) ?? "a rule in \(DisplayedText.field(Self.pack(of: entry.rule))) matched"
            self.safer = facts.saferCommand
            self.who = facts.whoActs ?? (facts.saferCommand == nil ? Self.personInTerminal : nil)
            self.holdsInEveryMode = false
        }
    }

    /// The one command worth typing next.
    public static let nextCommand = CommandVocabulary.Command.log.invocation

    static let personInTerminal = "a person, in their own terminal"

    static func source(rule: String) -> Source {
        if rule == selfProtectionRule || rule.hasSuffix(":home-rv-config") || rule.hasPrefix("rv.self") {
            return .selfProtection
        }
        if rule.hasPrefix(indeterminatePrefix) || rule.hasPrefix("observe.floor:") || rule == "rv.timeout" {
            return .couldNotCheck
        }
        return .rule
    }

    static let indeterminatePrefix = "rv.indeterminate:"
    static let selfProtectionRule = indeterminatePrefix + "selfProtection"

    private static func selfProtectionWhy(rule: String) -> String {
        rule.hasSuffix(":home-rv-config")
            ? "rv protects itself: agents can't read or change rv's own files"
            : "rv protects itself: an agent can't loosen rv, unlock itself or change rv's settings"
    }

    private static func selfProtectionSafer(rule: String) -> String? {
        rule.hasSuffix(":home-rv-config")
            ? CommandVocabulary.Command.secrets.invocation + "   names only, never values"
            : nil
    }

    private static func couldNotCheckWhy(rule: String) -> String {
        let raw = rule.hasPrefix(indeterminatePrefix) ? String(rule.dropFirst(indeterminatePrefix.count)) : rule
        switch IndeterminateReason(rawValue: raw) ?? IndeterminateReason(rawValue: rule) {
        case .observeUnanalyzable?, .unresolvedInvocation?:
            return "rv can't see what this command runs, so it stops in every mode"
        case .budgetExhausted?:
            return "rv ran out of time checking this long command"
        case .commandTooLarge?:
            return "the command is too long for rv to check"
        case .corePacksUnavailable?:
            return "rv's rules did not load, so it could not check anything"
        case .inlineProgramNeedsJudge?, .packageScriptUnresolved?:
            return "rv can't see inside this script, so it stops in every mode"
        case .selfProtection?:
            return selfProtectionWhy(rule: rule)
        case nil:
            return rule == "rv.timeout" ? "rv ran out of time checking it" : "rv could not finish checking it"
        }
    }

    private static func pack(of rule: String) -> String {
        rule.split(separator: ":", maxSplits: 1).first.map(String.init) ?? rule
    }
}

/// `rv why <code> --json`. Keys stay stable.
public struct DecisionStoryRobotPayload: Equatable, Sendable, Encodable {
    public static let schema = "rv.why.v1"
    public var schema = DecisionStoryRobotPayload.schema
    public var code: String
    public var outcome: String
    public var selfProtection: Bool
    public var command: String
    public var context: String
    public var why: String
    public var rule: String
    public var safer: String?
    public var who: String?
    public var holdsInEveryMode: Bool

    public init(_ story: DecisionStory) {
        self.code = story.code
        switch story.outcome {
        case .stopped: self.outcome = "stopped"
        case .wouldStop: self.outcome = "would_stop"
        case .wouldAsk: self.outcome = "would_ask"
        }
        self.selfProtection = story.source == .selfProtection
        self.command = story.command
        self.context = story.context
        self.why = story.why
        self.rule = story.rule
        self.safer = story.safer
        self.who = story.who
        self.holdsInEveryMode = story.holdsInEveryMode
    }
}
