import RVDomain

/// The pre-commit secrets scan (`rv secrets hook install`) is the owner's
/// check on what leaves the machine, so only the owner may switch it off or
/// silence it. The hook skips the scan when `git config rv.secretsScan` is
/// false, and the scanner honours `rv-secrets:allow` comments and
/// `.rv-secrets-ignore` entries; none of that knows who set it. An agent that
/// hits the check is offered the fix (move the key into rv), never the off
/// switch.
///
/// `weakensScan` is true when an agent's command:
/// - sets `rv.secretsScan` to anything but a true spelling through git
///   (`git config [scope] [set] rv.secretsScan false`, `git -c
///   rv.secretsScan=false commit`, `--config-env`), or renames a section to
///   `rv` or edits config in an editor;
/// - or names the switch, the allow comment or the ignore file anywhere in
///   its text (a redirect into `.git/config`, `sed -i`, `tee`, a script) and
///   does more than read: every launched command must be a plain reader with
///   no output redirect. `grep -rn rv-secrets:allow .` and `git config --get
///   rv.secretsScan` stay allowed.
///
/// `protectsFile` is the file door's half: an agent's Write or Edit of
/// `.rv-secrets-ignore`, a repository's git config or hooks, or the user's
/// global git config.
///
/// Like `SecretServiceGuard` it is a `core.secrets` deny, which no allow-once
/// unlocks: the owner runs the command in their own terminal. Text only: it
/// cannot see a marker an agent writes through a file-edit tool's content, or
/// a script file the agent wrote first and then runs.
public enum SecretsScanGuard {
    static let patternName = "secrets-scan"
    public static let ruleID = RuleID(pack: .coreSecrets, pattern: patternName)
    /// Sentence 1 is the stop; sentence 2 is the human's command, short
    /// enough to survive `hostDenyWhy`.
    public static let reason =
        "Only the owner can switch off or silence the commit check. Ask them to move the key into rv: rv secrets set NAME."

    /// The git config key the hook reads, folded.
    static let switchKey = "rv.secretsscan"

    /// Folded mentions that name the switch or the scanner's allow paths.
    private static let mentions = ["secretsscan", "rv-secrets:allow", ".rv-secrets-ignore"]

    public static func weakensScan(_ command: ShellCommand) -> Bool {
        let plain = plainText(command.rawValue)
        let mentioned = mentions.contains { plain.contains($0) }
        // Cheap screen before a full parse: a git config write of the switch
        // needs `config` (or `--config-env`), the key, or a dynamic word.
        guard mentioned || plain.contains("config") || plain.contains("$") || plain.contains("`") else { return false }
        let launched = launchedCommandHeads(command.rawValue)
        if launched.contains(where: { setsSwitchThroughGit($0) }) { return true }
        guard mentioned else { return false }
        // A bare redirect (`> .rv-secrets-ignore`) launches nothing and writes.
        return launched.isEmpty || launched.contains { onlyReads($0) == false }
    }

    static func match(searchText: String) -> RuleMatch {
        RuleMatch(ruleID: ruleID, severity: .high, reason: reason, regex: nil, matchedText: nil, searchText: searchText)
    }

    public static func deny(searchText: String) -> EvaluationResult {
        EvaluationResult(
            outcome: .deny(Deny(ruleID: ruleID, reason: reason), matched: match(searchText: searchText)),
            matchingView: MatchingView(searchText)
        )
    }

    // MARK: File door

    /// `path` is the absolute (or, without a cwd, as-typed) path a Write or
    /// Edit targets, and `home` the user's home.
    public static func protectsFile(_ path: String, home: String?) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).folding(options: .caseInsensitive, locale: nil) }
        guard let last = parts.last else { return false }
        if last == ".rv-secrets-ignore" { return true }
        if let git = parts.lastIndex(of: ".git") {
            let inside = parts[(git + 1)...]
            if inside.first == "hooks" { return true }
            if last == "config" || last == "config.worktree" { return true }
        }
        guard let home else { return false }
        let folded = path.folding(options: .caseInsensitive, locale: nil)
        let homeFolded = home.folding(options: .caseInsensitive, locale: nil)
        let trimmedHome = homeFolded.hasSuffix("/") ? String(homeFolded.dropLast()) : homeFolded
        return [trimmedHome + "/.gitconfig", trimmedHome + "/.config/git/config"].contains(folded)
    }

    // MARK: git

    /// git global options that take the next word as their value.
    private static let gitValueGlobals: Set<String> = [
        "-c", "-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--exec-path",
    ]

    private static func setsSwitchThroughGit(_ launched: LaunchedCommand) -> Bool {
        let argv = launched.guardArgv
        guard let head = argv.first, launched.headIsDynamic || commandName(head) == "git" else { return false }
        var index = 1
        while index < argv.count {
            let word = unescapeBackslashPairs(argv[index])
            if word.hasPrefix("--config-env=") {
                if namesSwitch(configEntryKey(String(word.dropFirst("--config-env=".count)))) { return true }
                index += 1
                continue
            }
            if gitValueGlobals.contains(word) {
                guard index + 1 < argv.count else { return false }
                let value = unescapeBackslashPairs(argv[index + 1])
                if word == "--config-env", namesSwitch(configEntryKey(value)) { return true }
                if word == "-c", setsSwitch(entry: value) { return true }
                index += 2
                continue
            }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            guard foldedWord(word) == "config" else { return false }
            return configWritesSwitch(Array(argv[(index + 1)...]).map(unescapeBackslashPairs))
        }
        return false
    }

    /// Index of git's subcommand in `argv` (git first), past its global
    /// options and their values.
    private static func gitSubcommandIndex(_ argv: [String]) -> Int? {
        var index = 1
        while index < argv.count {
            let word = unescapeBackslashPairs(argv[index])
            if gitValueGlobals.contains(word) {
                index += 2
            } else if word.hasPrefix("-") {
                index += 1
            } else {
                return index
            }
        }
        return nil
    }

    /// `-c KEY=VALUE`: a bare `-c KEY` means true.
    private static func setsSwitch(entry: String) -> Bool {
        let key = configEntryKey(entry)
        guard namesSwitch(key) else { return false }
        guard let eq = entry.firstIndex(of: "=") else { return false }
        return isTrue(String(entry[entry.index(after: eq)...])) == false
    }

    private static func configEntryKey(_ entry: String) -> String {
        String(entry.prefix { $0 != "=" })
    }

    /// The switch, or a key rv cannot read statically.
    private static func namesSwitch(_ key: String) -> Bool {
        let folded = foldedWord(key)
        return folded == switchKey || key.contains("$") || key.contains("`")
    }

    private static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(foldedWord(value))
    }

    private static let configValueFlags: Set<String> = [
        "-f", "--file", "--blob", "--type", "--default", "--comment", "--value",
    ]
    /// Flags whose positionals are not a key and value to set.
    private static let configNonWriteFlags: Set<String> = [
        "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool",
        "-l", "--list", "--unset", "--unset-all", "--remove-section",
    ]

    /// `git config` arguments: true when they set the switch to a false
    /// value, rename a section to `rv`, or open an editor.
    private static func configWritesSwitch(_ args: [String]) -> Bool {
        var positionals: [String] = []
        var flags: Set<String> = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if configValueFlags.contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-"), arg != "-" {
                flags.insert(arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg)
            } else {
                positionals.append(arg)
            }
            index += 1
        }
        if flags.contains("-e") || flags.contains("--edit") { return true }
        if flags.contains("--rename-section") { return positionals.contains(where: renamesToRV) }
        if flags.isDisjoint(with: configNonWriteFlags) == false { return false }
        if let verb = positionals.first.map(foldedWord) {
            switch verb {
            case "edit": return true
            case "rename-section": return positionals.dropFirst().contains(where: renamesToRV)
            case "get", "list", "unset", "remove-section", "get-color", "get-colorbool": return false
            case "set": positionals.removeFirst()
            default: break
            }
        }
        guard positionals.count >= 2 else { return false }
        return namesSwitch(positionals[0]) && isTrue(positionals[1]) == false
    }

    private static func renamesToRV(_ word: String) -> Bool {
        foldedWord(word) == "rv" || word.contains("$") || word.contains("`")
    }

    // MARK: Mentions

    /// Quotes, `[x]` classes, backslashes and line continuations folded away,
    /// case-folded: `"rv.secrets"'Scan'`, `rv.secrets\Scan` and
    /// `RV.SECRETSSCAN` all name the switch.
    static func mentionsScanControls(_ raw: String) -> Bool {
        let plain = plainText(raw)
        return mentions.contains { plain.contains($0) }
    }

    private static func plainText(_ raw: String) -> String {
        foldHiddenMentions(raw)
            .replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "\\", with: "")
    }

    /// Programs that only read their operands or print.
    private static let readers: Set<String> = [
        "cat", "bat", "less", "more", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "ack",
        "wc", "ls", "stat", "file", "diff", "echo", "printf",
    ]
    /// rv verbs that only explain (`rv explain 'git config rv.secretsScan
    /// false'`); `rv run -- …` runs a command rv cannot see here.
    private static let rvReadVerbs: Set<String> = ["explain", "why", "help", "blocks", "test"]
    private static let gitReadSubcommands: Set<String> = [
        "grep", "log", "show", "diff", "blame", "status", "ls-files",
    ]

    private static func onlyReads(_ launched: LaunchedCommand) -> Bool {
        guard launched.truncated == false, launched.headIsDynamic == false else { return false }
        guard redirectsOutput(launched) == false else { return false }
        guard let head = launched.guardArgv.first.map(commandName) else { return true }
        if readers.contains(head) { return true }
        if rvProgramNames.contains(head) {
            let verb = launched.guardArgv.dropFirst().first { $0.hasPrefix("-") == false }.map(foldedWord)
            return verb.map(rvReadVerbs.contains) ?? true
        }
        guard head == "git" else { return false }
        let argv = launched.guardArgv
        guard let subIndex = gitSubcommandIndex(argv) else { return true }
        let verb = foldedWord(argv[subIndex])
        if gitReadSubcommands.contains(verb) { return true }
        guard verb == "config" else { return false }
        // git itself writes only the key the parse above judged; `--file`
        // may point it at the ignore file.
        if setsSwitchThroughGit(launched) { return false }
        if configOnlyReads(launched.guardArgv) { return true }
        return launched.guardArgv.contains { ["-f", "--file", "--blob"].contains($0) || $0.hasPrefix("--file=") } == false
    }

    /// `git config` that reads: a read flag, a `get`/`list` verb, or one key.
    private static func configOnlyReads(_ argv: [String]) -> Bool {
        guard let config = gitSubcommandIndex(argv) else { return false }
        let args = argv[(config + 1)...].map(unescapeBackslashPairs)
        let readFlags: Set<String> = [
            "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "-l", "--list",
        ]
        if args.contains(where: { readFlags.contains($0) }) { return true }
        let positionals = args.filter { $0.hasPrefix("-") == false }
        if let verb = positionals.first.map(foldedWord), ["get", "list"].contains(verb) { return true }
        return positionals.count == 1 && args.allSatisfy { $0.hasPrefix("-") == false || $0 == "--bool" || $0 == "--type=bool" }
    }

    /// An output redirect to anything but `/dev/null` or another descriptor.
    private static func redirectsOutput(_ launched: LaunchedCommand) -> Bool {
        let words = launched.redirects.map(unmarkedWord)
        var index = 0
        while index < words.count {
            let word = words[index]
            defer { index += 1 }
            guard word.contains(">") else { continue }
            if word.hasSuffix("&1") || word.hasSuffix("&2") || word.hasSuffix("&-") { continue }
            // The target is attached (`>f`) or the next word.
            let attached = word.drop { "0123456789&>|".contains($0) }
            let target = attached.isEmpty ? (index + 1 < words.count ? words[index + 1] : "") : String(attached)
            if attached.isEmpty { index += 1 }
            if target != "/dev/null" { return true }
        }
        return false
    }
}
