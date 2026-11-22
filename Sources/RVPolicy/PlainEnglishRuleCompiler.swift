import RVDomain

/// Plain sentences → a typed rule, with no model. "never force push to main",
/// "ask before git reset --hard", "block rm -rf". It reads a verdict word,
/// one command rv can type, and that command's branch or flags. Anything it
/// does not understand is refused with the reason, never guessed: a word left
/// over is named back, so a rule never quietly drops part of what was said.
///
/// Rules stay restrict-only whatever the verdict (`ActionPolicyEngine`), so
/// nothing drafted here can let through what rv or a pack stops.
public struct PlainEnglishRuleCompiler: EnglishCompiler {
    /// What a sentence drafts to.
    public enum Draft: Sendable, Equatable {
        case rule(TypedRulePreview)
        /// rv already stops this with a built-in rule; nothing to save.
        case builtIn(BuiltinRule)
        /// Not draftable. `reason` is one line for the person.
        case refused(EnglishCompileRefusal, reason: String)
    }

    public init() {}

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        switch draft(english) {
        case .rule(let preview):
            return .preview(preview)
        case .builtIn:
            return .refuse(.alreadyBuiltIn)
        case .refused(let refusal, _):
            return .refuse(refusal)
        }
    }

    public func draft(_ english: String) -> Draft {
        let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .refused(.empty, reason: "nothing to draft; say a rule, like \"never force-push to main\"")
        }
        let words = Self.words(trimmed)
        guard let (verdict, rest) = Self.verdict(words) else {
            return .refused(
                .uncompilable,
                reason: "start with never, ask before, or allow, like \"never force-push to main\"")
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

    /// Hyphens inside plain words split ("force-push" → force push); flags
    /// (`-f`, `--hard`) stay whole. Quotes and end punctuation drop.
    static func words(_ sentence: String) -> [Word] {
        var result: [Word] = []
        let stripped = sentence.map { "\"'`“”‘’,;:!?".contains($0) ? " " : $0 }
        for raw in String(stripped).split(whereSeparator: \.isWhitespace) {
            var token = String(raw)
            while token.count > 1, token.hasSuffix(".") { token.removeLast() }
            if token.hasPrefix("-") {
                result.append(Word(text: token, key: token.lowercased()))
                continue
            }
            for part in token.split(separator: "-") where part.isEmpty == false {
                result.append(Word(text: String(part), key: stem(part.lowercased())))
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
        "running": "run", "runs": "run",
        "branches": "branch", "repositories": "repository", "folders": "folder",
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
        ]
        let ask = [
            "always ask before", "always ask me before", "ask me before", "ask first before", "ask before",
            "ask first for", "ask for", "ask", "confirm before", "require approval for", "require approval before",
            "check with me before",
        ]
        let allow = ["always allow", "allow", "let", "permit"]
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

    // MARK: Action

    /// Words that never change which commands a rule matches.
    private static let filler: Set<String> = [
        "the", "a", "an", "any", "anyone", "anybody", "anything", "everything", "all", "every", "ever", "again",
        "agent", "agents", "claude", "codex", "cursor", "me", "my", "our", "i", "you", "we", "they", "it", "them",
        "please", "to", "on", "onto", "into", "in", "of", "from", "for", "with", "by", "here", "this", "that",
        "repo", "repository", "project", "origin", "remote", "upstream", "file", "files", "folder", "folders",
        "command", "commands", "run", "do", "doing", "use", "using", "git", "always", "anywhere", "rv",
        "changes", "change", "uncommitted", "unstaged", "local", "work", "worktree", "working", "tree", "copy",
        "things", "stuff", "before", "first",
    ]

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

    private static let pathScopes: Set<String> = ["outside", "beyond", "above"]

    static func action(_ words: [Word], verdict: TypedRuleVerdict, english: String) -> Draft {
        let keys = words.map(\.key)
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
            return .refused(
                .uncompilable,
                reason: "can't tell which command this is about; name one: git push, git reset, git clean, "
                    + "git restore, rm or mv")
        }
        if keys.contains(where: pathScopes.contains), kind == .delete || kind == .move {
            return .builtIn(.outOfRepoWrite)
        }
        if kind == .delete, keys.contains("branch") {
            return .refused(.unsupportedPredicate, reason: "a rule can't cover deleting branches yet")
        }
        if keys.contains("except") || keys.contains("unless") || keys.contains("but") {
            return .refused(.uncompilable, reason: "a rule can't have exceptions; draft the narrower rule instead")
        }
        switch kind {
        case .push:
            return push(words, verdict: verdict, english: english)
        case .reset:
            return reset(words, verdict: verdict, english: english)
        case .clean:
            // Every git clean, whatever its flags: a wider stop, shown in the preview.
            let flags = Set(keys.filter { $0.hasPrefix("-") })
            return simple(
                words, used: flags.union(["clean", "force", "directories", "ignored"]),
                predicate: .gitClean(force: nil, directories: nil), pack: .typedGit, name: "clean",
                thing: "git clean", verdict: verdict, english: english)
        case .discard:
            return simple(
                words, used: ["discard", "restore", "checkout", "--", "."],
                predicate: .gitDiscardWorktree(pathspec: nil), pack: .typedGit, name: "discard",
                thing: "discarding uncommitted changes", verdict: verdict, english: english)
        case .delete:
            return delete(words, verdict: verdict, english: english)
        case .move:
            return simple(
                words, used: ["move", "mv", "rename"], predicate: .filesystemMove, pack: typedFilesystem,
                name: "move", thing: "moving files", verdict: verdict, english: english)
        }
    }

    private static let typedFilesystem = PackID(rawValue: "typed.filesystem")

    /// The first word nothing in the rule accounts for.
    private static func leftover(_ words: [Word], used: Set<String>) -> Draft? {
        guard let word = words.first(where: { filler.contains($0.key) == false && used.contains($0.key) == false })
        else { return nil }
        return .refused(
            .uncompilable,
            reason: "can't fit \"\(DisplayedText.field(word.text))\" into a rule; "
                + "a rule names one command, and for git push the branch")
    }

    private static func push(_ words: [Word], verdict: TypedRuleVerdict, english: String) -> Draft {
        let keys = words.map(\.key)
        var used: Set<String> = ["push", "force", "-f", "--force", "lease", "--force-with-lease", "branch"]
        let force: GitPushForceConstraint
        if keys.contains("lease") || keys.contains("--force-with-lease") {
            used.formUnion(["with"])
            force = .exactly(.forceWithLease)
        } else if keys.contains("force") || keys.contains("-f") || keys.contains("--force") {
            force = .exactly(.force)
        } else {
            force = .any
        }
        var branch: String?
        var anyBranch = false
        for (index, word) in words.enumerated() {
            if ["all", "any", "every"].contains(word.key), index + 1 < words.count, words[index + 1].key == "branch" {
                anyBranch = true
            }
        }
        if anyBranch == false, let candidate = branchWord(words) {
            guard candidate.text.contains(where: { "*?[".contains($0) }) == false else {
                return .refused(
                    .uncompilable, reason: "a rule names one branch, not a pattern; try \"never force-push to main\"")
            }
            guard isBranchName(candidate.text) else {
                return .refused(
                    .uncompilable, reason: "\"\(DisplayedText.field(candidate.text))\" is not a branch name")
            }
            branch = candidate.text
            used.insert(candidate.key)
        }
        if let refused = leftover(words, used: used) { return refused }
        // The same id and sentence the model path gives a git push form.
        guard case .preview(let preview) = FoundationModelsEnglishCompileMapping.preview(
            force: force, branch: branch, verdict: verdict, sentence: "", english: english)
        else {
            return .refused(.uncompilable, reason: "can't draft that git push rule")
        }
        return .rule(preview)
    }

    /// The word after to/on/onto/into/origin, or right after push and its
    /// flags ("force push main").
    private static func branchWord(_ words: [Word]) -> Word? {
        let pointers: Set<String> = ["to", "on", "onto", "into", "origin", "upstream", "remote"]
        let skip: Set<String> = ["the", "origin", "upstream", "remote", "branch", "a", "an", "my", "our"]
        let flags: Set<String> = ["force", "-f", "--force", "lease", "--force-with-lease", "with", "git"]
        func next(after index: Int) -> Word? {
            var cursor = index + 1
            while cursor < words.count, skip.contains(words[cursor].key) { cursor += 1 }
            guard cursor < words.count else { return nil }
            let word = words[cursor]
            if filler.contains(word.key) || flags.contains(word.key) || actionWords[word.key] != nil { return nil }
            return word
        }
        for (index, word) in words.enumerated() where pointers.contains(word.key) {
            if let found = next(after: index) { return found }
        }
        if let push = words.firstIndex(where: { $0.key == "push" }) {
            var cursor = push + 1
            while cursor < words.count, flags.contains(words[cursor].key) { cursor += 1 }
            if cursor < words.count {
                let word = words[cursor]
                if filler.contains(word.key) == false, word.key.hasPrefix("-") == false { return word }
            }
        }
        return nil
    }

    private static func isBranchName(_ text: String) -> Bool {
        text.hasPrefix("-") == false && text.count <= 200
            && text.allSatisfy { $0.isLetter || $0.isNumber || "._/-".contains($0) }
    }

    private static func reset(_ words: [Word], verdict: TypedRuleVerdict, english: String) -> Draft {
        let keys = words.map(\.key)
        var mode: GitResetMode?
        var used: Set<String> = ["reset"]
        for candidate in [GitResetMode.hard, .soft, .mixed, .merge, .keep]
        where keys.contains(candidate.rawValue) || keys.contains("--" + candidate.rawValue) {
            guard mode == nil else {
                return .refused(.uncompilable, reason: "one reset mode per rule; draft each one on its own")
            }
            mode = candidate
            used.formUnion([candidate.rawValue, "--" + candidate.rawValue])
        }
        if let refused = leftover(words, used: used) { return refused }
        let name = mode.map { "reset-\($0.rawValue)" } ?? "reset"
        let thing = mode.map { "git reset --\($0.rawValue)" } ?? "git reset"
        return preview(
            .gitReset(mode: mode), pack: .typedGit, name: name, thing: thing, verdict: verdict, english: english)
    }

    private static func delete(_ words: [Word], verdict: TypedRuleVerdict, english: String) -> Draft {
        let keys = words.map(\.key)
        var recursive: Bool?
        var force: Bool?
        var used: Set<String> = ["delete", "remove", "rm", "erase", "wipe", "unlink", "rmdir", "recursively", "recursive", "force"]
        for key in keys where key.hasPrefix("-") && key.hasPrefix("--") == false {
            let letters = Set(key.dropFirst())
            guard letters.isSubset(of: ["r", "R", "f"]) else { continue }
            if letters.contains("r") || letters.contains("R") { recursive = true }
            if letters.contains("f") { force = true }
            used.insert(key)
        }
        if keys.contains("--recursive") || keys.contains("recursively") || keys.contains("recursive") {
            recursive = true
            used.insert("--recursive")
        }
        if keys.contains("--force") || keys.contains("force") {
            force = true
            used.insert("--force")
        }
        if let refused = leftover(words, used: used) { return refused }
        var flags = ""
        if recursive == true { flags += "r" }
        if force == true { flags += "f" }
        let name = flags.isEmpty ? "delete" : "delete-" + flags
        let thing = flags.isEmpty ? "deleting files" : "rm -\(flags)"
        return preview(
            .filesystemDelete(recursive: recursive, force: force), pack: typedFilesystem, name: name, thing: thing,
            verdict: verdict, english: english)
    }

    private static func simple(
        _ words: [Word], used: Set<String>, predicate: PolicyPredicate, pack: PackID, name: String, thing: String,
        verdict: TypedRuleVerdict, english: String
    ) -> Draft {
        if let refused = leftover(words, used: used) { return refused }
        return preview(predicate, pack: pack, name: name, thing: thing, verdict: verdict, english: english)
    }

    private static func preview(
        _ predicate: PolicyPredicate, pack: PackID, name: String, thing: String, verdict: TypedRuleVerdict,
        english: String
    ) -> Draft {
        let sentence: String
        switch verdict {
        case .deny: sentence = "Always block \(thing)"
        case .ask: sentence = "Ask before \(thing)"
        case .allow: sentence = "Always allow \(thing)"
        }
        return .rule(TypedRulePreview(
            sentence: sentence,
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
