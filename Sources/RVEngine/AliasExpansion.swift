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
/// statically (shell expansion, a cycle, nesting past the bound), config
/// handed through the environment, and config that includes files or
/// names a program are `unverifiable`, which denies.
///
/// An invocation whose program or git subcommand is not statically known
/// (a same-line shell function, a variable head, a dynamic `eval`, git or
/// a git-shaped call after `source`, an unknown git subcommand such as an
/// alias defined in an earlier call) is `unresolved`, which asks.
///
/// File-writing heredoc bodies are data (`maskNonExecutingHeredocBodies`):
/// they are not read as commands. An executing heredoc (`bash <<EOF`) is.
struct AliasExpansion: Sendable, Equatable {
    /// The commands the aliases expand to, `;`-joined, with the line's
    /// `cd` segments kept in order so relative paths resolve the same.
    var expansion: String?
    /// An alias or config construct that cannot be resolved statically.
    var unverifiable = false
    /// An invocation whose program or git subcommand is unknown.
    var unresolved = false

    static let unverifiableConstruct = AliasExpansion(unverifiable: true)
}

/// Nesting bound for alias chains (`a` → `b` → body) and re-expansion.
private let maxAliasDepth = 8

func expandAliases(_ command: String) -> AliasExpansion {
    let command = maskNonExecutingHeredocBodies(command)
    if gitEnvironmentInjection(command) { return .unverifiableConstruct }
    // A same-line function whose body reads no call arguments runs exactly
    // the body text, which every pass already judges as its own segments.
    // One that does (`g(){ git "$@"; }; g reset --hard`) runs a command no
    // pass ever saw.
    let functions = readsPositionalParameters(command) ? shellFunctionNames(in: command) : []
    var resolver = AliasResolver(functionNames: functions)
    var out: [String] = []
    var expandedAny = false
    var afterSource = false
    for segment in aliasSegments(command) {
        if afterSource, mayBeRedefinedGit(segment) { resolver.unresolved = true }
        guard let resolved = resolver.resolve(segment, depth: 0) else { return .unverifiableConstruct }
        if resolved.expanded {
            expandedAny = true
            out.append(contentsOf: resolved.commands)
        } else if isDirectoryChange(segment) {
            out.append(segment)
        }
        // `\source` is still the builtin: quoting only stops alias lookup.
        let head = unescapeBackslashPairs(firstWord(segment).word)
        if head == "source" || head == "." { afterSource = true }
    }
    return AliasExpansion(
        expansion: expandedAny ? out.joined(separator: " ; ") : nil,
        unresolved: resolver.unresolved
    )
}

/// Tightens an allowed `result` for `command`: an unverifiable alias or
/// config construct denies, an expansion `judge` does not allow replaces
/// the allow, and (with core.git enabled) an unresolved invocation is
/// indeterminate. Any other verdict passes through.
///
/// `floorUnresolved` is false for a pass whose allow later stages may still
/// turn into a deny (the pack pass inside the semantic door): the ask is
/// applied once, last, so it never stands in for a deny.
func gateAliases(
    _ result: EvaluationResult,
    command: ShellCommand,
    packs: [PackSnapshot],
    enabledPacks: [PackID],
    floorUnresolved: Bool = true,
    judge: (ShellCommand) -> EvaluationResult
) -> EvaluationResult {
    guard result.decision == .allow else { return result }
    let analysis = expandAliases(command.rawValue)
    if analysis.unverifiable {
        return aliasUnverifiableDeny(searchText: result.matchingView.rawValue, packs: packs)
    }
    if let text = analysis.expansion {
        var inner = judge(ShellCommand(rawValue: text))
        if inner.decision != .allow {
            inner.matchingView = result.matchingView
            return inner
        }
    }
    if floorUnresolved, analysis.unresolved, enabledPacks.contains(.coreGit) {
        return EvaluationResult(outcome: .indeterminate(.unresolvedInvocation), matchingView: result.matchingView)
    }
    return result
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
        // A bare assignment (`x=$(…)`) runs no program; a substitution in
        // it is its own segment already.
        .filter { segment in
            let words = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }
            return words.isEmpty || words.contains { isShellAssignmentWord($0.lexeme) == false }
        }
        .flatMap { splitSegments(ShellPipeline.stripLeadingAssignmentPrefixes($0)) }
        .flatMap(peeledSegments)
}

/// Git subcommands that rewrite or discard history, the tree or the
/// remote, or change config.
private let destructiveGitSubcommands: Set<String> = [
    "reset", "push", "clean", "checkout", "restore", "switch", "rebase", "branch", "stash", "rm", "mv",
    "commit", "merge", "cherry-pick", "revert", "am", "apply", "tag", "worktree", "submodule", "config",
    "filter-branch", "filter-repo", "update-ref", "reflog", "gc", "prune", "replace", "notes",
]

/// After `source`/`.`, whether a later segment's meaning may hinge on
/// what the sourced file defined, as far as this guard is concerned.
///
/// The sourced file already ran with full power, and rv allows `source X`
/// without reading X, so a definition it leaves behind can do no more
/// than the file itself could; an unknown head is allowed without a
/// source too (the agent's shell already carries the user's own aliases).
/// What the file adds is a reason to distrust this guard's own reading of
/// git: it can define `git` as a function or alias, or export config
/// (`GIT_CONFIG_*`) and helper programs the command text never shows, and
/// it can define a short alias for git (`g reset --hard`). So git, and a
/// bare word whose next word is a destructive git subcommand, stay
/// unresolved; `pytest`, `pip install …` and `nvm use 20` do not.
private func mayBeRedefinedGit(_ segment: String) -> Bool {
    let words = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }.map(\.lexeme)
    guard let head = words.first else { return false }
    let program = unescapeBackslashPairs(basename(head)).lowercased()
    if program == "git" { return true }
    guard head.contains("/") == false, words.count > 1 else { return false }
    return destructiveGitSubcommands.contains(words[1].lowercased())
}

private func isDirectoryChange(_ segment: String) -> Bool {
    let head = firstWord(segment).word
    return head == "cd" || head == "pushd" || head == "popd"
}

/// Total expansion segments resolved per command: fan-out (`alias
/// a='b;b;b'`) is multiplicative across depth, so depth alone does not
/// bound the work.
private let maxAliasSteps = 256

private struct AliasResolver {
    /// Shell functions the line defines.
    let functionNames: Set<String>
    /// Same-line shell aliases, in definition order.
    var shellAliases: [String: String] = [:]
    /// Set once any resolved command's program or git subcommand is unknown.
    var unresolved = false
    private var steps = 0

    init(functionNames: Set<String>) {
        self.functionNames = functionNames
    }

    /// The commands `segment` runs once aliases resolve, plus whether any
    /// alias was involved. Nil when an alias cannot be verified.
    mutating func resolve(_ segment: String, depth: Int) -> (commands: [String], expanded: Bool)? {
        guard depth <= maxAliasDepth else { return nil }
        let words = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }.map(\.lexeme)
        guard let head = words.first else { return ([segment], false) }
        if unescapeBackslashPairs(basename(head)) == "alias" {
            return recordShellAliases(Array(words.dropFirst())) ? ([segment], false) : nil
        }
        if let value = shellAliases[head] {
            return resolveExpansion(shellAliasExpansion(value, rest: Array(words.dropFirst())), depth: depth)
        }
        let program = unescapeBackslashPairs(basename(head))
        if functionNames.contains(head) || isDynamicWord(program) {
            unresolved = true
            return ([segment], false)
        }
        if program == "eval" {
            let body = Array(words.dropFirst())
            if body.contains(where: isDynamicWord) {
                unresolved = true
                return ([segment], false)
            }
            return resolveExpansion(body.joined(separator: " "), depth: depth)
        }
        guard program.lowercased() == "git" else {
            return ([segment], false)
        }
        return resolveGit(words, segment: segment, depth: depth)
    }

    /// Steps count only segments produced by an expansion: the line's own
    /// segments are bounded by its length, while fan-out multiplies.
    private mutating func resolveExpansion(_ text: String, depth: Int) -> (commands: [String], expanded: Bool)? {
        var commands: [String] = []
        for piece in aliasSegments(text) {
            steps += 1
            guard steps <= maxAliasSteps, let inner = resolve(piece, depth: depth + 1) else { return nil }
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
        guard knownGitSubcommands.contains(subcommand) else {
            unresolved = true
            return ([segment], false)
        }
        guard subcommand == "config" else { return ([segment], false) }
        switch gitConfigAliasDefinition(args) {
        case .notADefinition:
            return ([segment], false)
        case .dynamic:
            return nil
        case .namedProgram:
            // An exec vector the owner should see, but an everyday one.
            unresolved = true
            return ([segment], false)
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
/// comes from the environment (`--config-env=alias.x=VAR`), or a `-c` /
/// `--config-env` key includes config or names a program.
private func parseGitAliasGlobals(_ words: [String]) -> GitAliasGlobals? {
    var globals = GitAliasGlobals()
    var index = 1
    while index < words.count, words[index].hasPrefix("-") {
        let word = words[index]
        if word.hasPrefix("--config-env=") {
            if hidesConfig(String(word.dropFirst("--config-env=".count)), fromEnvironment: true) { return nil }
        }
        guard gitValueGlobals.contains(word) else {
            globals.words.append(word)
            index += 1
            continue
        }
        guard index + 1 < words.count else { break }
        let value = words[index + 1]
        if word == "--config-env", hidesConfig(value, fromEnvironment: true) { return nil }
        if word == "-c", hidesConfig(value, fromEnvironment: false) { return nil }
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

/// A `KEY=VALUE` config entry whose effect rv cannot judge: a dynamic
/// key, an include, a program-running key, or an alias whose body comes
/// from the environment.
private func hidesConfig(_ entry: String, fromEnvironment: Bool) -> Bool {
    let key = String(entry.prefix { $0 != "=" })
    if fromEnvironment, key.lowercased().hasPrefix("alias.") { return true }
    if isDynamicWord(key) { return true }
    guard isProgramOrIncludeConfigKey(key) else { return false }
    // `--config-env` takes the value from a variable rv cannot see.
    guard fromEnvironment == false, let eq = entry.firstIndex(of: "=") else { return true }
    return isInertProgramSetting(key, value: String(entry[entry.index(after: eq)...])) == false
}

private enum GitConfigAliasDefinition {
    case notADefinition
    case dynamic
    /// An editor or pager set to a named program (`core.editor vim`).
    case namedProgram
    case body(String)
}

/// Interpreters and fetchers: as an editor or pager they run arbitrary
/// code, never just edit or page.
private let hostileProgramHeads: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "env", "eval", "exec", "command", "xargs",
    "python", "python2", "python3", "perl", "ruby", "node", "deno", "bun", "php", "lua", "osascript",
    "curl", "wget", "nc", "ncat", "socat", "ssh", "sudo", "rm", "open",
]

/// An editor or pager key set to a value that names a program by a plain
/// name, with plain arguments (`vim`, `code --wait`, `less -R`): no path,
/// no shell text, no interpreter. Anything else stays unjudgeable.
private func isNamedEditorOrPager(_ key: String, value: String) -> Bool {
    let key = key.lowercased()
    guard ["core.editor", "sequence.editor", "core.pager"].contains(key) || key.hasPrefix("pager.") else {
        return false
    }
    let plain = value.allSatisfy { $0.isLetter || $0.isNumber || " _.+=-".contains($0) }
    let words = value.split(separator: " ").map(String.init)
    guard plain, let head = words.first, head.hasPrefix("-") == false else { return false }
    return hostileProgramHeads.contains(head.lowercased()) == false
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
    if isProgramOrIncludeConfigKey(key), isInertProgramSetting(key, value: positionals[1]) == false {
        return isNamedEditorOrPager(key, value: positionals[1]) ? .namedProgram : .dynamic
    }
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
