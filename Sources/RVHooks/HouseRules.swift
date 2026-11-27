import RVDomain

/// B4 house rules: what an agent hears from rv at session start, before
/// its first command (North Star "hello", v3 Everyday Magic). Mode, the
/// repo's own rules, the keys it may use through `rv run --secret`, and how
/// to take a stop, in at most `tokenBudget` tokens.
///
/// Plain data in, one string out. The facts are gathered by the door that
/// answers the hook (`RVService`); this type only words them. Nothing here
/// loosens anything: it names rules and key names (never values) and tells
/// the agent that only a person approves.
public struct HouseRules: Equatable, Sendable {
    /// The host's guard mode, in the v5c words (`CommandVocabulary.PlannedWord`).
    public enum Mode: Equatable, Sendable {
        /// Observe: risky commands run and are logged; only catastrophic
        /// commands and changes to rv's own files stop (decision Q5).
        case watching
        /// Enforce: risky commands are stopped.
        case guarding
    }

    /// One rule from the repo's `.rv/policy.toml` that stops or holds a
    /// command. Allow rules loosen, so they are not house rules.
    public struct RepoRule: Equatable, Sendable {
        public var verdict: TypedRuleVerdict
        public var id: RuleID

        public init(verdict: TypedRuleVerdict, id: RuleID) {
            self.verdict = verdict
            self.id = id
        }
    }

    public var mode: Mode
    public var repoRules: [RepoRule]
    /// Secret names this agent may use through `rv run --secret`. Names only.
    public var keys: [String]

    public init(mode: Mode, repoRules: [RepoRule] = [], keys: [String] = []) {
        self.mode = mode
        self.repoRules = repoRules
        self.keys = keys
    }

    /// The whole message must fit in this many tokens (`estimatedTokens`).
    public static let tokenBudget = 80

    /// The most rules and keys named before the rest become a count.
    static let maximumRulesShown = 2
    static let maximumKeysShown = 3
    /// Longer rule ids and key names are left out rather than cut: a cut
    /// name is a wrong name.
    static let maximumNameLength = 40

    /// The message, at most `tokenBudget` tokens by `estimatedTokens`.
    /// When names would push it over, fewer are named and the rest are
    /// counted, so the budget always holds.
    public var text: String {
        let rules = repoRules.filter { $0.verdict != .allow }.compactMap(Self.shownRule)
        let keys = keys.filter(Self.isShownName)
        var rulesShown = min(rules.count, Self.maximumRulesShown)
        var keysShown = min(keys.count, Self.maximumKeysShown)
        while true {
            let candidate = compose(rules: rules, rulesShown: rulesShown, keys: keys, keysShown: keysShown)
            if Self.estimatedTokens(candidate) <= Self.tokenBudget { return candidate }
            if keysShown > 1 {
                keysShown -= 1
            } else if rulesShown > 0 {
                rulesShown -= 1
            } else if keysShown > 0 {
                keysShown -= 1
            } else {
                return candidate
            }
        }
    }

    private func compose(rules: [String], rulesShown: Int, keys: [String], keysShown: Int) -> String {
        var lines = [modeLine]
        if rules.isEmpty == false {
            lines.append("repo: " + Self.list(rules, shown: rulesShown, noun: "rules"))
        }
        if keys.isEmpty == false {
            lines.append("keys: " + Self.list(keys, shown: keysShown, noun: "keys")
                + " via " + Self.runSecret)
        }
        lines.append("stopped? Follow its next step; don't rephrase. A person approves.")
        return lines.joined(separator: "\n")
    }

    private var modeLine: String {
        let rv = CommandVocabulary.Glyph.rv.rawValue + " " + CommandVocabulary.program
        switch mode {
        case .watching:
            return "\(rv) is \(CommandVocabulary.PlannedWord.watching): only catastrophic commands and rv's files stop."
        case .guarding:
            return "\(rv) is \(CommandVocabulary.PlannedWord.guarding): risky commands are stopped."
        }
    }

    /// `rv run --secret NAME -- cmd`, the one way an agent uses a key.
    static let runSecret = CommandVocabulary.Command.run.invocation + " --secret NAME -- cmd"

    /// "a, b +3"; with nothing shown, "5 rules".
    private static func list(_ names: [String], shown: Int, noun: String) -> String {
        guard shown > 0 else { return "\(names.count) \(noun)" }
        let head = names.prefix(shown).joined(separator: ", ")
        let rest = names.count - shown
        return rest > 0 ? "\(head) +\(rest)" : head
    }

    /// "no core.repo/push-main" for a deny, "ask core.repo/migrate" for an
    /// ask; nil when the id has characters rv will not print in its own
    /// voice (the repo file is writable by anyone who can write the repo).
    private static func shownRule(_ rule: RepoRule) -> String? {
        let id = rule.id.slashDisplay
        guard isShownName(id) else { return nil }
        return (rule.verdict == .deny ? "no " : "ask ") + id
    }

    private static func isShownName(_ name: String) -> Bool {
        guard name.isEmpty == false, name.utf8.count <= maximumNameLength else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || "._/-".unicodeScalars.contains(scalar)
        }
    }

    /// A deliberately high token estimate, so a message under it is under
    /// the budget for any tokenizer an agent host uses: every run of ASCII
    /// letters or digits counts one token per four characters (rounded
    /// up), every other non-space character counts one, a non-ASCII one
    /// (the ◆ glyph) two, and a line break one.
    public static func estimatedTokens(_ text: String) -> Int {
        var count = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                run += 1
                continue
            }
            count += (run + 3) / 4
            run = 0
            if scalar == " " { continue }
            count += scalar.isASCII ? 1 : 2
        }
        return count + (run + 3) / 4
    }
}

/// Claude Code and Codex SessionStart context: `additionalContext` is added
/// to what the agent reads before its first turn. Exit 0; no decision key,
/// so nothing here can allow or deny a tool.
func sessionStartContextJSON(_ text: String) -> String {
    "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\(jsonQuoted(text))}}\n"
}
