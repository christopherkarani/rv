import RVDomain

/// Git and shell aliases are wrappers whose body is the real command:
/// `git -c alias.z='reset --hard' z` runs `git reset --hard`, and
/// `git config alias.z 'reset --hard'` arms that command for every later
/// `git z`. rv never reads git config, so a body is judged where it is
/// visible: at an inline `-c alias.X=` use, at `git config alias.X`
/// definition time, and at a same-line shell `alias name=value` use.
///
/// The expansion is an extra command the gate evaluates next to the
/// original (it can only tighten). A body or name rv cannot read
/// statically (shell expansion, a cycle, nesting past the bound) is
/// `.unverifiable`, which denies.
enum AliasExpansion: Sendable, Equatable {
    /// No alias construct is used or defined.
    case none
    /// The commands the aliases expand to, `;`-joined, with the line's
    /// `cd` segments kept in order so relative paths resolve the same.
    case expanded(String)
    /// An alias construct whose body cannot be resolved statically.
    case unverifiable
}

/// Nesting bound for alias chains (`a` → `b` → body) and re-expansion.
private let maxAliasDepth = 8

func expandAliases(_ command: String) -> AliasExpansion {
    // Config keys are case-insensitive (`ALIAS.z`), so is the fast path.
    guard command.lowercased().contains("alias") else { return .none }
    var resolver = AliasResolver()
    var out: [String] = []
    var expandedAny = false
    for segment in aliasSegments(command) {
        guard let resolved = resolver.resolve(segment, depth: 0) else { return .unverifiable }
        if resolved.expanded {
            expandedAny = true
            out.append(contentsOf: resolved.commands)
        } else if isDirectoryChange(segment) {
            out.append(segment)
        }
    }
    return expandedAny ? .expanded(out.joined(separator: " ; ")) : .none
}

/// Tightens an allowed `result` for `command` by the alias bodies it uses
/// or defines: an unverifiable alias denies, and an expansion `judge` does
/// not allow replaces the allow. Any other verdict passes through.
func gateAliases(
    _ result: EvaluationResult,
    command: ShellCommand,
    packs: [PackSnapshot],
    judge: (ShellCommand) -> EvaluationResult
) -> EvaluationResult {
    guard result.decision == .allow else { return result }
    switch expandAliases(command.rawValue) {
    case .none:
        return result
    case .unverifiable:
        return aliasUnverifiableDeny(searchText: result.matchingView.rawValue, packs: packs)
    case .expanded(let text):
        var inner = judge(ShellCommand(rawValue: text))
        guard inner.decision != .allow else { return result }
        inner.matchingView = result.matchingView
        return inner
    }
}

private let aliasUnverifiablePattern = "git-alias-semantic-unverified"

private func aliasUnverifiableDeny(searchText: String, packs: [PackSnapshot]) -> EvaluationResult {
    let ruleID = RuleID(pack: .coreGit, pattern: aliasUnverifiablePattern)
    let packReason = packs.first { $0.id == .coreGit }?
        .destructive.first { $0.name == aliasUnverifiablePattern }?.reason
    let reason = packReason ?? "The alias body cannot be resolved statically."
    let match = RuleMatch(
        ruleID: ruleID,
        severity: .high,
        reason: reason,
        regex: nil,
        matchedText: nil,
        searchText: searchText
    )
    return EvaluationResult(
        outcome: .deny(Deny(ruleID: ruleID, reason: reason), matched: match),
        matchingView: MatchingView(searchText)
    )
}

/// Top-level segments with assignment prefixes and wrappers peeled, the
/// same view the git segment parser reads (`sudo git …`, `bash -c '…'`).
private func aliasSegments(_ command: String) -> [String] {
    splitSegments(command)
        .flatMap { splitSegments(ShellPipeline.stripLeadingAssignmentPrefixes($0)) }
        .flatMap(peeledSegments)
}

private func isDirectoryChange(_ segment: String) -> Bool {
    let head = firstWord(segment).word
    return head == "cd" || head == "pushd" || head == "popd"
}

/// Total segments resolved per command: fan-out (`alias a='b;b;b'`) is
/// multiplicative across depth, so depth alone does not bound the work.
private let maxAliasSteps = 256

private struct AliasResolver {
    /// Same-line shell aliases, in definition order.
    var shellAliases: [String: String] = [:]
    private var steps = 0

    /// The commands `segment` runs once aliases resolve, plus whether any
    /// alias was involved. Nil when an alias cannot be verified.
    mutating func resolve(_ segment: String, depth: Int) -> (commands: [String], expanded: Bool)? {
        steps += 1
        guard depth <= maxAliasDepth, steps <= maxAliasSteps else { return nil }
        let words = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }.map(\.lexeme)
        guard let head = words.first else { return ([segment], false) }
        if basename(head) == "alias" {
            return recordShellAliases(Array(words.dropFirst())) ? ([segment], false) : nil
        }
        if let value = shellAliases[head] {
            return resolveExpansion(shellAliasExpansion(value, rest: Array(words.dropFirst())), depth: depth)
        }
        guard unescapeBackslashPairs(basename(head)).lowercased() == "git" else {
            return ([segment], false)
        }
        return resolveGit(words, segment: segment, depth: depth)
    }

    private mutating func resolveExpansion(_ text: String, depth: Int) -> (commands: [String], expanded: Bool)? {
        var commands: [String] = []
        for piece in aliasSegments(text) {
            guard let inner = resolve(piece, depth: depth + 1) else { return nil }
            commands.append(contentsOf: inner.commands)
        }
        return (commands, true)
    }

    /// `alias g=git ll='ls -la'`. False when a name or value is dynamic.
    private mutating func recordShellAliases(_ words: [String]) -> Bool {
        for word in words where word.hasPrefix("-") == false {
            guard let eq = word.firstIndex(of: "="), eq > word.startIndex else { continue }
            let name = String(word[..<eq])
            let value = String(word[word.index(after: eq)...])
            if isDynamicWord(name) || isDynamicWord(value) { return false }
            shellAliases[name] = value
        }
        return true
    }

    /// Alias values are shell text, re-read by the shell. A value ending in
    /// a blank also alias-expands the next word (`alias s='sudo '`).
    private func shellAliasExpansion(_ value: String, rest: [String]) -> String {
        var text = value
        var rest = rest[...]
        while text.last?.isWhitespace == true, let next = rest.first, let more = shellAliases[next] {
            text += more
            rest = rest.dropFirst()
        }
        return ([text] + rest.map(shellQuotedWord)).joined(separator: " ")
    }

    private mutating func resolveGit(
        _ words: [String],
        segment: String,
        depth: Int
    ) -> (commands: [String], expanded: Bool)? {
        guard let globals = parseGitAliasGlobals(words) else { return nil }
        guard globals.subcommandIndex < words.count else { return ([segment], false) }
        let subcommand = words[globals.subcommandIndex]
        let args = Array(words[(globals.subcommandIndex + 1)...])
        if let body = globals.aliases[subcommand.lowercased()] {
            let prefix = ["git"] + globals.words
            return resolveExpansion(aliasBodyCommand(body, gitPrefix: prefix, args: args), depth: depth)
        }
        if isDynamicWord(subcommand), globals.aliases.isEmpty == false { return nil }
        guard subcommand.lowercased() == "config" else { return ([segment], false) }
        switch gitConfigAliasDefinition(args) {
        case .notADefinition:
            return ([segment], false)
        case .dynamic:
            return nil
        case .body(let body):
            // The original is judged on its own; the expansion adds the body.
            return resolveExpansion(aliasBodyCommand(body, gitPrefix: ["git"], args: []), depth: depth)
        }
    }
}

/// `!cmd` bodies are shell text run with the alias arguments appended;
/// other bodies are git arguments re-split by git.
private func aliasBodyCommand(_ body: String, gitPrefix: [String], args: [String]) -> String {
    let quotedArgs = args.map(shellQuotedWord)
    if body.hasPrefix("!") {
        return ([String(body.dropFirst())] + quotedArgs).joined(separator: " ")
    }
    return (gitPrefix.map(shellQuotedWord) + [body] + quotedArgs).joined(separator: " ")
}

private struct GitAliasGlobals {
    /// Global option words, kept for re-emission (alias chains stay visible).
    var words: [String] = []
    /// `-c alias.NAME=BODY` definitions, lowercased name to body.
    var aliases: [String: String] = [:]
    var subcommandIndex = 1
}

/// Git global options that take the next word as their value.
private let gitValueGlobals: Set<String> = [
    "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix",
    "--attr-source", "--list-cmds", "--config-env",
]

/// Parses `git` global options. Nil when an alias definition is dynamic or
/// comes from the environment (`--config-env=alias.x=VAR`).
private func parseGitAliasGlobals(_ words: [String]) -> GitAliasGlobals? {
    var globals = GitAliasGlobals()
    var index = 1
    while index < words.count, words[index].hasPrefix("-") {
        let word = words[index]
        if word.hasPrefix("--config-env=") {
            if word.dropFirst("--config-env=".count).lowercased().hasPrefix("alias.") { return nil }
        }
        guard gitValueGlobals.contains(word) else {
            globals.words.append(word)
            index += 1
            continue
        }
        guard index + 1 < words.count else { break }
        let value = words[index + 1]
        if word == "--config-env", value.lowercased().hasPrefix("alias.") { return nil }
        if word == "-c", value.lowercased().hasPrefix("alias.") {
            let entry = value.dropFirst("alias.".count)
            let name = String(entry.prefix { $0 != "=" }).lowercased()
            let body = entry.firstIndex(of: "=").map { String(entry[entry.index(after: $0)...]) } ?? ""
            if isDynamicWord(name) || isDynamicWord(body) { return nil }
            if body.isEmpty == false { globals.aliases[name] = body }
        }
        globals.words.append(contentsOf: [word, value])
        index += 2
    }
    globals.subcommandIndex = index
    return globals
}

private enum GitConfigAliasDefinition {
    case notADefinition
    case dynamic
    case body(String)
}

/// `git config [scope] alias.NAME BODY` (also `set`, `--add`,
/// `--replace-all`). Reads, unsets, and lists define nothing.
private func gitConfigAliasDefinition(_ args: [String]) -> GitConfigAliasDefinition {
    let readOnlyFlags: Set<String> = [
        "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool",
        "--unset", "--unset-all", "-l", "--list", "--rename-section", "--remove-section",
        "-e", "--edit",
    ]
    let valueFlags: Set<String> = ["-f", "--file", "--blob", "--type", "--default", "--comment", "--value"]
    var positionals: [String] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        if readOnlyFlags.contains(arg) { return .notADefinition }
        if valueFlags.contains(arg) {
            index += 2
            continue
        }
        if arg.hasPrefix("-") == false || arg == "-" {
            positionals.append(arg)
        }
        index += 1
    }
    if let verb = positionals.first?.lowercased() {
        if ["get", "unset", "list", "rename-section", "remove-section", "edit"].contains(verb) {
            return .notADefinition
        }
        if verb == "set" { positionals.removeFirst() }
    }
    guard positionals.count >= 2 else { return .notADefinition }
    let key = positionals[0]
    if isDynamicWord(key), positionals[1].isEmpty == false { return .dynamic }
    guard key.lowercased().hasPrefix("alias.") else { return .notADefinition }
    let body = positionals[1]
    if isDynamicWord(body) { return .dynamic }
    return .body(body)
}

private func isDynamicWord(_ word: String) -> Bool {
    word.contains("$") || word.contains("`")
}

/// Re-emits one word so the expansion re-tokenizes to the same argv.
private func shellQuotedWord(_ word: String) -> String {
    let safe = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,@%+^".contains($0) }
    if safe, word.isEmpty == false { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
