import RVDomain

/// Plain sentences → a typed rule, with no model. "never force push to main",
/// "ask before git reset --hard", "block rm -rf". It reads a verdict word,
/// one command rv can type, and that command's branch or flags.
///
/// Every word has to land in a slot. A word the grammar cannot place is
/// named back in a refusal, never dropped: dropping a word ("work" in "never
/// force push to work") would save a rule wider than the sentence.
///
/// Rules stay restrict-only whatever the verdict (`ActionPolicyEngine`), so
/// nothing drafted here can let through what rv or a pack stops.
/// A compile result and, for a refusal, the one line that says why.
public struct ReasonedCompileResult: Sendable, Equatable {
    public var result: EnglishCompileResult
    public var reason: String?

    public init(result: EnglishCompileResult, reason: String?) {
        self.result = result
        self.reason = reason
    }
}

/// A compiler that can say why it refused, for `rv policy draft` (text and
/// `--json`).
public protocol ReasonedEnglishCompiler: EnglishCompiler {
    func compileWithReason(_ english: String) async throws -> ReasonedCompileResult
}

public struct PlainEnglishRuleCompiler: ReasonedEnglishCompiler {
    /// What a sentence drafts to.
    public enum Draft: Sendable, Equatable {
        case rule(TypedRulePreview)
        /// rv already stops this with a built-in rule; nothing to save.
        case builtIn(BuiltinRule)
        /// Read and not draftable. Final: `reason` is one line for the person.
        case refused(EnglishCompileRefusal, reason: String)
        /// No verdict or no command the grammar knows. The only drafts a
        /// model may take a second look at (`EnglishCompileChain`).
        case unreadable(reason: String)

        /// The one-line reason for a refusal; nil for a rule or built-in.
        public var reason: String? {
            switch self {
            case .refused(_, let reason), .unreadable(let reason): return reason
            case .rule, .builtIn: return nil
            }
        }
    }

    public init() {}

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        Self.result(draft(english))
    }

    public func compileWithReason(_ english: String) async throws -> ReasonedCompileResult {
        let draft = draft(english)
        return ReasonedCompileResult(result: Self.result(draft), reason: draft.reason)
    }

    static func result(_ draft: Draft) -> EnglishCompileResult {
        switch draft {
        case .rule(let preview):
            return .preview(preview)
        case .builtIn:
            return .refuse(.alreadyBuiltIn)
        case .refused(let refusal, _):
            return .refuse(refusal)
        case .unreadable:
            return .refuse(.uncompilable)
        }
    }

    public func draft(_ english: String) -> Draft {
        let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .refused(.empty, reason: "nothing to draft; say a rule, like \"never force-push to main\"")
        }
        let words = Self.words(trimmed)
        guard let (verdict, rest) = Self.verdict(words) else {
            return .unreadable(
                reason: "no never, ask or allow at the start; start with never, ask before, or allow, "
                    + "like \"never force-push to main\"")
        }
        return Self.action(rest, verdict: verdict, english: trimmed)
    }

    // MARK: Words

    /// One token of the sentence: the spelling as typed (for branch names)
    /// and a lowercased, stemmed form for matching.
    struct Word: Equatable {
        var text: String
        var key: String
    }

    /// Words that may be written joined by hyphens ("force-push", "hard-reset").
    private static let joinable: Set<String> = [
        "force", "forced", "forcing", "push", "pushing", "pushes", "pushed", "hard", "reset", "with", "lease", "git",
    ]

    /// Flags (`-f`, `--hard`) stay whole, and so does any hyphenated word
    /// that is not made of command words: a branch like `work-in-progress`
    /// is one name. Quotes and end punctuation drop.
    static func words(_ sentence: String) -> [Word] {
        var result: [Word] = []
        let stripped = sentence.map { "\"'`“”‘’,;:!?".contains($0) ? " " : $0 }
        for raw in String(stripped).split(whereSeparator: \.isWhitespace) {
            var token = String(raw)
            while token.count > 1, token.hasSuffix(".") { token.removeLast() }
            let parts = token.split(separator: "-").map(String.init)
            if token.hasPrefix("-") == false, parts.count > 1, parts.allSatisfy({ joinable.contains($0.lowercased()) }) {
                result += parts.map { Word(text: $0, key: stem($0.lowercased())) }
            } else {
                result.append(Word(text: token, key: token.hasPrefix("-") ? token.lowercased() : stem(token.lowercased())))
            }
        }
        return result
    }

    private static let stems: [String: String] = [
        "pushing": "push", "pushes": "push", "pushed": "push",
        "forcing": "force", "forced": "force",
        "resetting": "reset", "resets": "reset",
        "cleaning": "clean", "cleans": "clean",
        "deleting": "delete", "deletes": "delete", "deleted": "delete",
        "removing": "remove", "removes": "remove", "removed": "remove",
        "erasing": "erase", "wiping": "wipe",
        "moving": "move", "moves": "move", "moved": "move",
        "renaming": "rename", "renames": "rename",
        "discarding": "discard", "discards": "discard",
        "restoring": "restore", "restores": "restore",
        "running": "run", "runs": "run", "using": "use", "doing": "do",
        "branches": "branch", "repositories": "repository",
    ]

    private static func stem(_ word: String) -> String {
        stems[word] ?? word
    }

    // MARK: Verdict

    /// Longest phrase first, so "never allow" wins over "never".
    private static let verdictPhrases: [([String], TypedRuleVerdict)] = {
        let deny = [
            "never allow", "never let", "do not allow", "don't allow", "dont allow", "do not let", "don't let",
            "always block", "always deny", "always stop", "block", "never", "deny", "forbid", "disallow",
            "prevent", "stop", "prohibit", "refuse", "no", "do not", "don't", "dont",
            // Negated permission, so "you can't" never reads as "you can".
            "you can't", "you cannot", "you may not", "you must not", "you mustn't", "you should not",
            "you shouldn't", "can't", "cannot", "may not", "must not", "it is not ok to", "it's not ok to",
            "it is not okay to", "it's not okay to", "it is not fine to", "it's not fine to", "not ok to",
            "it is never ok to", "it's never ok to",
            "under no circumstances", "under no circumstance", "under no circumstances should", "do not ever",
            "don't ever", "dont ever", "never ever",
        ]
        let ask = [
            "always ask before", "always ask me before", "ask me before", "ask first before", "ask before",
            "ask first for", "ask for", "ask", "confirm before", "require approval for", "require approval before",
            "check with me before",
        ]
        let allow = [
            "always allow", "allow", "let", "permit",
            // Common ways to say it, read here so they never reach a model.
            "it is fine to", "it's fine to", "its fine to", "it is ok to", "it's ok to", "its ok to",
            "it is okay to", "it's okay to", "it is alright to", "it's alright to", "fine to", "ok to", "okay to",
            "you may", "you can", "you are allowed to", "feel free to", "may", "can",
        ]
        let all = deny.map { ($0, TypedRuleVerdict.deny) } + ask.map { ($0, .ask) } + allow.map { ($0, .allow) }
        return all
            .map { (PlainEnglishRuleCompiler.words($0.0).map(\.key), $0.1) }
            .sorted { $0.0.count > $1.0.count }
    }()

    private static let politeness: Set<String> = ["please", "rv", "agents", "agent", "claude", "codex"]

    static func verdict(_ words: [Word]) -> (TypedRuleVerdict, [Word])? {
        var words = words[...]
        while let first = words.first, politeness.contains(first.key) { words = words.dropFirst() }
        let keys = words.map(\.key)
        for (phrase, verdict) in verdictPhrases where keys.starts(with: phrase) {
            return (verdict, Array(words.dropFirst(phrase.count)))
        }
        return nil
    }

    // MARK: Slots

    /// Words that never change which commands a rule matches, wherever they sit.
    private static let neutral: Set<String> = [
        "the", "a", "an", "please", "ever", "again", "agent", "agents", "claude", "codex", "cursor", "rv", "always",
    ]

    /// Who the rule is about, only at the start: "never let anyone push …".
    private static let subjects: Set<String> = [
        "anyone", "anybody", "agent", "agents", "claude", "codex", "cursor", "you", "them",
    ]

    /// The sentence's words and which of them a slot has used.
    struct Slots {
        let words: [Word]
        var used: Set<Int> = []

        var keys: [String] { words.map(\.key) }

        func free(_ index: Int) -> Bool {
            used.contains(index) == false
        }

        mutating func use(_ keys: Set<String>) {
            for (index, word) in words.enumerated() where keys.contains(word.key) { used.insert(index) }
        }

        /// Words no slot used and that are not neutral.
        var leftover: [Int] {
            words.indices.filter { free($0) && PlainEnglishRuleCompiler.neutral.contains(words[$0].key) == false }
        }

        /// "anyone to", "run", "git" at the start of the rest of the sentence.
        mutating func useLead(git: Bool) {
            var cursor = 0
            if cursor < words.count, PlainEnglishRuleCompiler.subjects.contains(words[cursor].key) {
                used.insert(cursor)
                cursor += 1
                if cursor < words.count, words[cursor].key == "to" {
                    used.insert(cursor)
                    cursor += 1
                }
            }
            if cursor < words.count, ["run", "use", "do"].contains(words[cursor].key) {
                used.insert(cursor)
            }
            if git { use(["git"]) }
        }
    }

    // MARK: Action

    private static let otherTools: Set<String> = [
        "npm", "npx", "yarn", "pnpm", "pip", "pip3", "cargo", "docker", "kubectl", "terraform", "dropdb", "psql",
        "mysql", "redis", "curl", "wget", "ssh", "scp", "sudo", "brew", "mcp", "aws", "gcloud", "az", "helm",
        "make", "chmod", "chown", "dd", "mkfs", "diskutil", "launchctl", "kill", "pkill", "shutdown", "reboot",
        "deploy", "publish", "database", "db", "table", "tables", "drop", "truncate", "commit", "merge", "rebase",
        "tag", "tags", "stash", "checkout", "switch", "cherry", "pick", "amend",
    ]

    private enum Kind: Equatable {
        case push, reset, clean, discard, delete, move
    }

    private static let actionWords: [String: Kind] = [
        "push": .push, "reset": .reset, "clean": .clean, "discard": .discard, "restore": .discard,
        "delete": .delete, "remove": .delete, "rm": .delete, "erase": .delete, "wipe": .delete,
        "unlink": .delete, "rmdir": .delete, "move": .move, "mv": .move, "rename": .move,
    ]

    private static let exceptions: Set<String> = ["except", "unless", "but", "besides", "excluding"]

    static func action(_ words: [Word], verdict: TypedRuleVerdict, english: String) -> Draft {
        let keys = words.map(\.key)
        if let word = words.first(where: { exceptions.contains($0.key) }) {
            return .refused(
                .uncompilable,
                reason: "a rule can't have exceptions (\"\(DisplayedText.field(word.text))\"); "
                    + "draft the narrower rule instead")
        }
        var kinds: [Kind] = []
        for key in keys {
            if let kind = actionWords[key], kinds.contains(kind) == false { kinds.append(kind) }
        }
        if kinds.isEmpty, keys.contains("checkout"), keys.contains("--") || keys.contains(".") {
            kinds = [.discard]  // git checkout -- .
        }
        if kinds.isEmpty, keys.contains("hard") || keys.contains("--hard") {
            kinds = [.reset]  // "--hard" with no other command
        }
        if kinds.isEmpty, let tool = keys.first(where: otherTools.contains) {
            return .refused(
                .unsupportedPredicate,
                reason: "a rule can't cover \(DisplayedText.field(tool)) yet; drafts cover git push, reset, "
                    + "clean and restore, and deleting or moving files")
        }
        guard kinds.count == 1, let kind = kinds.first else {
            if kinds.count > 1 {
                return .refused(.uncompilable, reason: "one command per rule; draft each one on its own")
            }
            return .unreadable(
                reason: "can't tell which command this is about; name one: git push, git reset, git clean, "
                    + "git restore, rm or mv")
        }
        if kind == .delete, keys.contains("branch") {
            return .refused(.unsupportedPredicate, reason: "a rule can't cover deleting branches yet")
        }
        var slots = Slots(words: words)
        slots.useLead(git: kind != .delete && kind != .move)
        switch kind {
        case .push:
            return push(&slots, verdict: verdict, english: english)
        case .reset:
            return reset(&slots, verdict: verdict, english: english)
        case .clean:
            return clean(&slots, verdict: verdict, english: english)
        case .discard:
            slots.use(["discard", "restore", "checkout", "--", "."])
            slots.use(["uncommitted", "unstaged", "local", "changes", "change", "edits", "work", "working", "tree",
                       "worktree", "copy", "my", "your", "our", "all", "any", "every"])
            if let refused = refusal(slots, hint: "a discard rule covers every discard of uncommitted changes, "
                + "like \"never discard uncommitted changes\"") { return refused }
            return preview(
                .gitDiscardWorktree(pathspec: nil), pack: .typedGit, name: "discard",
                verdict: verdict, english: english)
        case .delete:
            return delete(&slots, verdict: verdict, english: english)
        case .move:
            slots.use(["move", "mv", "rename"])
            slots.use(objects)
            if let draft = outsideTheRepo(&slots, verdict: verdict) { return draft }
            if let refused = refusal(slots, hint: "a move rule covers every move and can't name a path yet, "
                + "like \"ask before moving files\"") { return refused }
            return preview(
                .filesystemMove, pack: typedFilesystem, name: "move", verdict: verdict,
                english: english)
        }
    }

    private static let typedFilesystem = PackID(rawValue: "typed.filesystem")

    private static let connectors: Set<String> = ["to", "on", "onto", "into", "in", "at", "for", "of", "by", "with"]
    private static let changeWords: Set<String> = ["changes", "change", "uncommitted", "unstaged", "edits", "work"]

    /// A refusal naming the first word no slot took, or nil when every word
    /// has a place.
    private static func refusal(_ slots: Slots, hint: String) -> Draft? {
        let left = slots.leftover
        guard let first = left.first else { return nil }
        let words = slots.words
        if left.contains(where: { ["and", "or", "nor", "plus", "&"].contains(words[$0].key) }) {
            return .refused(.uncompilable, reason: "one thing per rule; draft each one on its own")
        }
        let named = left.first(where: { connectors.contains(words[$0].key) == false }) ?? first
        return .refused(
            .uncompilable,
            reason: "can't fit \"\(DisplayedText.field(words[named].text))\" into a rule; \(hint)")
    }

    // MARK: git push

    private static let pointers: Set<String> = ["to", "on", "onto", "into"]
    private static let remotes: Set<String> = ["origin", "upstream", "remote"]
    private static let everyBranch: Set<String> = ["all", "any", "every", "each"]

    /// Things a push carries that are not branch names: "never push tags"
    /// is not a rule about a branch called tags.
    private static let pushNouns: Set<String> = [
        "tag", "tags", "commit", "commits", "secret", "secrets", "credential", "credentials", "key", "keys",
        "token", "tokens", "password", "passwords", "code", "change", "changes", "file", "files", "history",
        "stuff", "thing", "things", "everything", "anything", "something", "it", "them", "this", "that",
        "anywhere",
    ]

    /// Words that describe a branch without naming one.
    private static let notBranchNames: Set<String> = [
        "local", "current", "same", "my", "your", "our", "their", "his", "her", "new", "other", "own", "default",
        "shared", "protected", "important", "public", "private", "someone", "someones", "else", "branch",
    ]

    private static func push(_ slots: inout Slots, verdict: TypedRuleVerdict, english: String) -> Draft {
        let words = slots.words
        let keys = slots.keys
        slots.use(["push"])
        let force: GitPushForceConstraint
        if keys.contains("--force-with-lease") || keys.contains("lease") {
            if keys.contains("-f") || keys.contains("--force") {
                return .refused(
                    .uncompilable, reason: "a rule covers one of --force and --force-with-lease; drop the other")
            }
            slots.use(["--force-with-lease", "lease", "force", "with"])
            force = .exactly(.forceWithLease)
        } else if keys.contains("force") || keys.contains("-f") || keys.contains("--force") {
            slots.use(["force", "-f", "--force"])
            for index in words.indices.dropFirst() where keys[index] == "force" && keys[index - 1] == "with" {
                slots.used.insert(index - 1)  // "push with force"
            }
            force = .exactly(.force)
        } else {
            force = .any
        }
        if let flag = words.indices.first(where: { slots.free($0) && keys[$0].hasPrefix("-") }) {
            return .refused(
                .unsupportedPredicate,
                reason: "a push rule can't single out \(DisplayedText.field(words[flag].text)); it names "
                    + "--force or --force-with-lease and one branch")
        }

        // The branch slot: after to/on/onto/into, or the next free word after push.
        guard let pushIndex = keys.firstIndex(of: "push") else {
            return .unreadable(reason: "can't tell which command this is about")
        }
        var cursor = pushIndex + 1
        var pointer: Int?
        if let found = words.indices.first(where: { $0 > pushIndex && slots.free($0) && pointers.contains(keys[$0]) }) {
            pointer = found
            slots.used.insert(found)
            cursor = found + 1
        } else {
            while cursor < words.count, slots.free(cursor) == false { cursor += 1 }
        }
        func skipNeutral() {
            while cursor < words.count, slots.free(cursor), neutral.contains(keys[cursor]) { cursor += 1 }
        }
        skipNeutral()
        if cursor < words.count, slots.free(cursor), keys[cursor] == "branch", cursor + 1 < words.count {
            slots.used.insert(cursor)  // "to branch main"
            cursor += 1
            skipNeutral()
        }
        if cursor < words.count, slots.free(cursor), remotes.contains(keys[cursor]) {
            slots.used.insert(cursor)  // "origin main"
            cursor += 1
            skipNeutral()
        }

        var branch: String?
        if cursor < words.count, slots.free(cursor) {
            let candidate = words[cursor]
            if everyBranch.contains(candidate.key), cursor + 1 < words.count, keys[cursor + 1] == "branch" {
                slots.used.formUnion([cursor, cursor + 1])
            } else {
                if let (refusal, reason) = branchProblem(candidate.text) {
                    return .refused(refusal, reason: reason)
                }
                branch = candidate.text
                slots.used.insert(cursor)
                if cursor + 1 < words.count, keys[cursor + 1] == "branch" { slots.used.insert(cursor + 1) }
            }
        } else if let pointer {
            return .refused(
                .uncompilable,
                reason: "no branch after \"\(DisplayedText.field(words[pointer].text))\"; say which one, "
                    + "like \"never force-push to main\"")
        }
        if let refused = refusal(slots, hint: "a push rule names force and one branch, like \"never force-push to main\"") {
            return refused
        }
        return pushDraft(force: force, branch: branch, verdict: verdict, english: english)
    }

    /// The one git push builder, for the grammar and for a model's form
    /// alike: the branch passes the same checks, the id is the model path's,
    /// and the sentence says exactly which pushes the rule covers.
    static func pushDraft(
        force: GitPushForceConstraint, branch typed: String?, verdict: TypedRuleVerdict, english: String
    ) -> Draft {
        var branch: String?
        var note: String?
        if let typed {
            if let (refusal, reason) = branchProblem(typed) { return .refused(refusal, reason: reason) }
            let name = branchName(typed)
            if name != typed {
                note = "\(DisplayedText.field(typed)) read as branch \(DisplayedText.field(name))"
            }
            branch = name
        }
        var thing = describe(.gitPush(force: force, branch: branch))
        if let note { thing += " (\(note))" }
        guard case .preview(let preview) = FoundationModelsEnglishCompileMapping.preview(
            force: force, branch: branch, verdict: verdict, sentence: sentence(verdict, thing), english: english)
        else {
            return .refused(.uncompilable, reason: "can't draft that git push rule")
        }
        return .rule(preview)
    }

    /// Why `text` can't be the branch of a push rule, or nil when it can.
    private static func branchProblem(_ text: String) -> (EnglishCompileRefusal, String)? {
        let shown = DisplayedText.field(text)
        let key = stem(text.lowercased())
        if text.unicodeScalars.contains(where: { $0.isASCII == false }) {
            // A look-alike letter ("mаin" with a Cyrillic а) would save a
            // rule that never matches the branch it appears to name.
            return (.uncompilable, "branch name has non-ASCII characters (\(shown)); type it in plain ASCII")
        }
        if pushNouns.contains(key) {
            return (
                .unsupportedPredicate,
                "\"\(shown)\" is not a branch; a push rule covers one branch, like \"never force-push to main\"")
        }
        if notBranchNames.contains(key) {
            return (.uncompilable, "\"\(shown)\" doesn't name a branch; say which one, like \"never force-push to main\"")
        }
        if text.contains(where: { "*?[".contains($0) }) {
            return (.uncompilable, "a rule names one branch, not a pattern; try \"never force-push to main\"")
        }
        guard isBranchName(branchName(text)) else {
            return (.uncompilable, "\"\(shown)\" is not a branch name")
        }
        return nil
    }

    /// `origin/main` and `refs/heads/main` name the branch `main`: a push
    /// destination never carries the remote, so the rule keeps only the branch.
    private static func branchName(_ text: String) -> String {
        for prefix in ["origin/", "upstream/", "refs/heads/"]
        where text.lowercased().hasPrefix(prefix) && text.count > prefix.count {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    private static func isBranchName(_ text: String) -> Bool {
        text.hasPrefix("-") == false && text.hasPrefix("/") == false && text.contains("..") == false
            && text.count <= 200 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }
    }

    // MARK: git reset and git clean

    private static func reset(_ slots: inout Slots, verdict: TypedRuleVerdict, english: String) -> Draft {
        let keys = slots.keys
        slots.use(["reset"])
        var mode: GitResetMode?
        for candidate in [GitResetMode.hard, .soft, .mixed, .merge, .keep]
        where keys.contains(candidate.rawValue) || keys.contains("--" + candidate.rawValue) {
            guard mode == nil else {
                return .refused(.uncompilable, reason: "one reset mode per rule; draft each one on its own")
            }
            mode = candidate
            slots.use([candidate.rawValue, "--" + candidate.rawValue])
        }
        let hint = slots.leftover.contains(where: { changeWords.contains(keys[$0]) || keys[$0] == "local" })
            ? "a reset rule names a mode; to keep uncommitted changes say \"never discard uncommitted changes\""
            : "a reset rule names a mode, like \"never git reset --hard\""
        if let refused = refusal(slots, hint: hint) { return refused }
        let name = mode.map { "reset-\($0.rawValue)" } ?? "reset"
        return preview(
            .gitReset(mode: mode), pack: .typedGit, name: name, verdict: verdict, english: english)
    }

    /// `-f` and `-d` are the flags a clean rule can name. Another flag would
    /// be dropped and the rule would cover more than was said, so it refuses.
    private static func clean(_ slots: inout Slots, verdict: TypedRuleVerdict, english: String) -> Draft {
        let words = slots.words
        slots.use(["clean"])
        var force = false
        var directories = false
        for (index, word) in words.enumerated() where slots.free(index) {
            switch word.key {
            case "--force", "force":
                force = true
            case let flag where flag.hasPrefix("-") && flag.hasPrefix("--") == false:
                let letters = Set(word.text.dropFirst())
                guard letters.isSubset(of: ["f", "d"]) else {
                    return .refused(
                        .unsupportedPredicate,
                        reason: "a rule can't single out git clean \(DisplayedText.field(word.text)); "
                            + "it names -f and -d, like \"never git clean -fd\"")
                }
                force = force || letters.contains("f")
                directories = directories || letters.contains("d")
            case let flag where flag.hasPrefix("--"):
                return .refused(
                    .unsupportedPredicate,
                    reason: "a rule can't single out git clean \(DisplayedText.field(word.text)); "
                        + "it names -f and -d, like \"never git clean -fd\"")
            default:
                continue
            }
            slots.used.insert(index)
        }
        if let refused = refusal(slots, hint: "a clean rule names -f or -d, like \"never git clean -fd\"") {
            return refused
        }
        var letters = ""
        if force { letters += "f" }
        if directories { letters += "d" }
        let name = letters.isEmpty ? "clean" : "clean-\(letters)"
        return preview(
            .gitClean(force: force ? true : nil, directories: directories ? true : nil), pack: .typedGit,
            name: name, verdict: verdict, english: english)
    }

    // MARK: Files

    /// What a delete or move rule can be about: every file.
    private static let objects: Set<String> = ["file", "files", "anything", "everything", "all", "any"]

    private static func delete(_ slots: inout Slots, verdict: TypedRuleVerdict, english: String) -> Draft {
        let words = slots.words
        let keys = slots.keys
        slots.use(["delete", "remove", "rm", "erase", "wipe", "unlink", "rmdir"])
        slots.use(objects)
        var recursive = false
        var force = false
        for (index, word) in words.enumerated() where slots.free(index) {
            switch word.key {
            case "--recursive", "recursively", "recursive":
                recursive = true
            case "--force", "force", "forcefully":
                force = true
            case let flag where flag.hasPrefix("-") && flag.hasPrefix("--") == false:
                let letters = Set(word.text.dropFirst())
                guard letters.isSubset(of: ["r", "R", "f"]) else {
                    return .refused(
                        .unsupportedPredicate,
                        reason: "a rule can't single out rm \(DisplayedText.field(word.text)); it names -r and -f, "
                            + "like \"never rm -rf\"")
                }
                recursive = recursive || letters.contains("r") || letters.contains("R")
                force = force || letters.contains("f")
            default:
                continue
            }
            slots.used.insert(index)
        }
        if let draft = outsideTheRepo(&slots, verdict: verdict) { return draft }
        let left = slots.leftover
        let hint: String
        if left.contains(where: { changeWords.contains(keys[$0]) }) {
            hint = "to keep uncommitted changes say \"never discard uncommitted changes\""
        } else if left.contains(where: { keys[$0] == "git" }) {
            hint = "a rule can't cover git rm yet; \"never rm\" covers deleting files"
        } else {
            hint = "a delete rule covers every delete and can't name a path yet, like \"never rm -rf\""
        }
        if let refused = refusal(slots, hint: hint) { return refused }
        var flags = ""
        if recursive { flags += "r" }
        if force { flags += "f" }
        let name = flags.isEmpty ? "delete" : "delete-" + flags
        return preview(
            .filesystemDelete(recursive: recursive ? true : nil, force: force ? true : nil), pack: typedFilesystem,
            name: name, verdict: verdict, english: english)
    }

    private static let scopeWords: Set<String> = ["outside", "beyond", "above"]
    private static let repoWords: Set<String> = ["repo", "repository", "project", "workspace", "worktree", "checkout"]
    private static let determiners: Set<String> = ["this", "the", "my", "our", "your", "current"]

    /// "outside [of] [this] repo": rv's built-in rule already stops that.
    /// Any other place ("outside node_modules") is a path a rule can't name,
    /// and an allow can't let through what the built-in stops. Nil when the
    /// sentence names no place, or when other words still need a slot.
    private static func outsideTheRepo(_ slots: inout Slots, verdict: TypedRuleVerdict) -> Draft? {
        let words = slots.words
        let keys = slots.keys
        guard let scope = keys.firstIndex(where: scopeWords.contains) else { return nil }
        var cursor = scope + 1
        if cursor < words.count, keys[cursor] == "of" { cursor += 1 }
        if cursor < words.count, determiners.contains(keys[cursor]) { cursor += 1 }
        var end: Int?
        if cursor < words.count, repoWords.contains(keys[cursor]) {
            end = cursor
        } else if cursor + 1 < words.count, keys[cursor] == "working", ["directory", "tree", "folder"].contains(keys[cursor + 1]) {
            end = cursor + 1
        }
        guard let end else {
            return .refused(
                .unsupportedPredicate,
                reason: "a rule can't name a path yet; rv's built-in rule covers deletes and moves outside this repo")
        }
        slots.used.formUnion(scope...end)
        guard slots.leftover.isEmpty else { return nil }
        if verdict == .allow {
            return .refused(
                .unsupported,
                reason: "an allow rule can't let through what rv stops; rv stops deletes and moves outside this repo")
        }
        return .builtIn(.outOfRepoWrite)
    }

    // MARK: Preview

    /// What a rule covers, in the words its preview uses. One describer
    /// for grammar and model rules, so a preview never just repeats the
    /// sentence it was drafted from.
    static func describe(_ predicate: PolicyPredicate) -> String {
        switch predicate {
        case .gitPush(let force, let branch):
            let target = branch.map(DisplayedText.field) ?? "any branch"
            switch force {
            case .exactly(.force): return "force-push to \(target)"
            case .exactly(.forceWithLease): return "git push --force-with-lease to \(target) (not plain --force)"
            case .exactly(.none): return "git push without force to \(target)"
            case .any: return "git push to \(target), forced or not"
            }
        case .gitReset(let mode):
            return mode.map { "git reset --\($0.rawValue)" } ?? "every git reset"
        case .gitClean(let force, let directories):
            if force == nil, directories == nil { return "every git clean" }
            var letters = ""
            if force == true { letters += "f" }
            if directories == true { letters += "d" }
            var text = letters.isEmpty ? "git clean" : "git clean -\(letters)"
            if force == false { text += " without -f" }
            if directories == false { text += " without -d" }
            return force == nil || directories == nil ? text + ", with or without other flags" : text
        case .gitDiscardWorktree(let pathspec):
            return pathspec.map { "discarding uncommitted changes to \(DisplayedText.field($0))" }
                ?? "discarding uncommitted changes"
        case .filesystemDelete(let recursive, let force):
            switch (recursive, force) {
            case (nil, nil): return "deleting files"
            case (true, nil): return "rm -r, with or without -f"
            case (nil, true): return "rm -f, with or without -r"
            case (true, true): return "rm -rf"
            default:
                var text = "rm"
                if recursive == true { text += " -r" }
                if force == true { text += " -f" }
                if recursive == false { text += " without -r" }
                if force == false { text += " without -f" }
                return text
            }
        case .filesystemMove:
            return "moving files"
        }
    }

    /// A rule a model drafted, put through the grammar's checks and its
    /// preview builder: the same branch rules and the same normalized
    /// sentence, never the model's own title.
    static func reviewed(_ preview: TypedRulePreview, english: String) -> Draft {
        let rule = preview.rule
        if let mismatch = disagreement(rule, english: english) {
            return .refused(.uncompilable, reason: "can't read this sentence for sure: \(mismatch); "
                + "say it like \"never force-push to main\"")
        }
        let draft: Draft
        if case .gitPush(let force, let branch) = rule.predicate {
            draft = pushDraft(force: force, branch: branch, verdict: rule.verdict, english: rule.english ?? english)
        } else {
            draft = .rule(TypedRulePreview(
                sentence: sentence(rule.verdict, describe(rule.predicate)), rule: rule, allowedToSave: true))
        }
        guard case .rule(let checked) = draft else { return draft }
        return .rule(TypedRulePreview(
            sentence: checked.sentence, rule: checked.rule,
            allowedToSave: checked.allowedToSave && preview.allowedToSave))
    }

    private static let denyCues: Set<String> = [
        "never", "not", "no", "t", "dont", "cannot", "block", "stop", "forbid", "prevent", "deny", "disallow",
        "prohibit", "refuse", "nobody", "mustn", "shouldn", "forbidden",
    ]
    private static let askCues: Set<String> = ["ask", "confirm", "approval", "approve", "check"]
    private static let allowCues: Set<String> = [
        "fine", "ok", "okay", "may", "can", "allow", "allowed", "permit", "permitted", "free", "alright", "sure",
        "let",
    ]

    /// Where a model's rule says something the sentence does not, or nil
    /// when the words back every field: the verdict, git push, the force
    /// kind and the branch. A model is free to read loosely; the rule it
    /// drafts is not.
    static func disagreement(_ rule: PolicyDocumentRule, english: String) -> String? {
        let tokens = Self.words(english)
        let keys = Set(tokens.map(\.key))
        guard case .gitPush(let force, let branch) = rule.predicate else {
            return "a model draft can only be a git push rule"
        }
        guard keys.contains("push") else { return "the sentence doesn't say push" }

        let expected: TypedRuleVerdict?
        if keys.contains(where: askCues.contains) {
            expected = .ask
        } else if keys.contains(where: denyCues.contains) {
            expected = .deny
        } else if keys.contains(where: allowCues.contains) {
            expected = .allow
        } else {
            expected = nil
        }
        guard let expected else { return "it doesn't say never, ask before, or allow" }
        guard rule.verdict == expected else {
            return "it reads as \(expected.rawValue), and the draft was \(rule.verdict.rawValue)"
        }

        let wantForce: GitPushForceConstraint
        if keys.contains("lease") || keys.contains("--force-with-lease") {
            wantForce = .exactly(.forceWithLease)
        } else if keys.contains("force") || keys.contains("-f") || keys.contains("--force") {
            wantForce = .exactly(.force)
        } else {
            wantForce = .any
        }
        guard force == wantForce else {
            return "it says \(forceWords(wantForce)), and the draft was \(forceWords(force))"
        }

        if let branch {
            let target = branchName(branch)
            guard tokens.contains(where: { $0.text == branch || branchName($0.text) == target }) else {
                return "it doesn't name the branch \(DisplayedText.field(branch))"
            }
        } else {
            let list = tokens.map(\.key)
            let saysEvery = list.indices.dropLast().contains { everyBranch.contains(list[$0]) && list[$0 + 1] == "branch" }
            guard saysEvery else { return "the draft covers every branch, and the sentence doesn't say so" }
        }
        return nil
    }

    private static func forceWords(_ force: GitPushForceConstraint) -> String {
        switch force {
        case .exactly(.force): return "force-push"
        case .exactly(.forceWithLease): return "--force-with-lease"
        case .exactly(.none): return "push without force"
        case .any: return "any push, forced or not"
        }
    }

    private static func sentence(_ verdict: TypedRuleVerdict, _ thing: String) -> String {
        switch verdict {
        case .deny: return "Always block \(thing)"
        case .ask: return "Ask before \(thing)"
        case .allow: return "Always allow \(thing)"
        }
    }

    private static func preview(
        _ predicate: PolicyPredicate, pack: PackID, name: String, verdict: TypedRuleVerdict, english: String
    ) -> Draft {
        .rule(TypedRulePreview(
            sentence: sentence(verdict, describe(predicate)),
            rule: PolicyDocumentRule(
                id: RuleID(pack: pack, pattern: "\(name)-\(verdict.rawValue)"),
                verdict: verdict,
                predicate: predicate,
                english: english
            ),
            allowedToSave: true
        ))
    }
}
