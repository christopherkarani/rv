import RVDomain

/// The pre-commit secrets scan (`rv secrets hook install`) is the owner's
/// check on what leaves the machine, so only the owner may switch it off or
/// silence it. The hook skips the scan when `git config rv.secretsScan` is
/// false, and the scanner honours `rv-secrets:allow` comments and
/// `.rv-secrets-ignore` entries; none of that knows who set it. An agent that
/// hits the check is offered the fix (move the key into rv), never the off
/// switch.
///
/// `weakensScan` matches on structure, never on a word anywhere in the text:
/// - git config that sets `rv.secretsScan` to anything but a true spelling,
///   sets `core.hooksPath` or `include.path`/`includeIf.*.path`, renames a
///   section to `rv` or `include`, or opens an editor: `git config`
///   (options parsed the way git does, unique prefixes included; an option
///   rv does not know fails closed when a guarded key is named), `git -c`,
///   `--config-env`, and the `GIT_CONFIG_*` environment;
/// - a shell write, move, delete or chmod (`>`, `tee`, `sed -i`, `cp`,
///   `rm`, `chmod -x`, … with `cd` followed) of `.rv-secrets-ignore`, a
///   repository's `.git/config` or `.git/hooks`, or the user's global git
///   config;
/// - a shell write whose text carries `rv-secrets:allow`, or an inline
///   interpreter program (`python3 -c`, `perl -pi -e`, `awk`) that names a
///   scan control;
/// - with rv's hook installed in the repository (`installedHook`, which the
///   caller answers from the filesystem): `git commit --no-verify`/`-n`,
///   unsetting or moving `core.hooksPath`, and a write, delete or move of
///   that `pre-commit` file or a directory above it.
/// Reads, `git add`, `git commit -m '… rv.secretsScan'`, tests and searches
/// that name the controls stay allowed.
///
/// `protectsFile` is the file door's half: an agent's Write or Edit of
/// `.rv-secrets-ignore`, a repository's git config or hooks, or the user's
/// global git config.
///
/// Like `SecretServiceGuard` it is a `core.secrets` deny, which no allow-once
/// unlocks: the owner runs the command in their own terminal. Not seen: an
/// allow comment written through a file-edit tool's content (the file door
/// carries only the path), and a script file the agent writes and then runs.
public enum SecretsScanGuard {
    static let patternName = "secrets-scan"
    public static let ruleID = RuleID(pack: .coreSecrets, pattern: patternName)
    /// Sentence 1 is the stop; sentence 2 is the human's command, short
    /// enough to survive `hostDenyWhy`.
    public static let reason =
        "Only the owner can switch off or silence the commit check. Ask them to move the key into rv: rv secrets set NAME."

    /// The git config key the hook reads, folded.
    static let switchKey = "rv.secretsscan"
    static let allowMarker = "rv-secrets:allow"

    /// `installedHook` answers the absolute path of the `pre-commit` that
    /// holds rv's block in the repository at `cwd`, or nil; it is asked at
    /// most once, and only for a command that could skip or move hooks or
    /// that writes some path.
    public static func weakensScan(
        _ command: ShellCommand,
        home: HomePath? = nil,
        cwd: WorkingDirectory? = nil,
        installedHook: () -> String? = { nil }
    ) -> Bool {
        let raw = command.rawValue
        let plain = plainText(raw)
        var launchedMemo: [LaunchedCommand]?
        func launched() -> [LaunchedCommand] {
            if let launchedMemo { return launchedMemo }
            let heads = launchedCommandHeads(raw)
            launchedMemo = heads
            return heads
        }
        var hookMemo: String??
        func hook() -> String? {
            if let hookMemo { return hookMemo }
            let found = installedHook()
            hookMemo = .some(found)
            return found
        }
        if gitConfigScreen.contains(where: { plain.contains($0) }),
           launched().contains(where: setsGuardedConfig)
        {
            return true
        }
        if plain.contains("git_config"), launched().contains(where: setsConfigThroughEnvironment) { return true }
        if writesScanControls(raw, plain: plain, launched: launched, home: home, cwd: cwd, hook: hook) { return true }
        if plain.contains("commit") || plain.contains("hookspath") || plain.contains("core") {
            let heads = launched()
            if heads.contains(where: commitSkipsHooks) || heads.contains(where: configMovesHooksPath) {
                return hook() != nil
            }
        }
        return false
    }

    /// Words one of the git config forms needs: the subcommand, a guarded
    /// key, or a dynamic word that may be either.
    private static let gitConfigScreen = ["config", "secretsscan", "hookspath", "include", "$", "`"]

    /// `git commit --no-verify` (`-n`, an abbreviation, or a short cluster
    /// holding `n`) skips every pre-commit hook, rv's scan included. Only a
    /// repository with rv's hook installed makes this a stop
    /// (`weakensScan`'s `installedHook`).
    public static func skipsCommitHook(_ command: ShellCommand) -> Bool {
        guard plainText(command.rawValue).contains("commit") else { return false }
        return launchedCommandHeads(command.rawValue).contains(where: commitSkipsHooks)
    }

    /// git config that moves hooks away from where rv's hook is: unsetting
    /// or setting `core.hooksPath`, or removing or renaming the `[core]`
    /// section. Setting it is a stop in every repository; the rest only
    /// where rv's hook is installed.
    public static func movesHooksPath(_ command: ShellCommand) -> Bool {
        launchedCommandHeads(command.rawValue).contains(where: configMovesHooksPath)
    }

    private static func commitSkipsHooks(_ launched: LaunchedCommand) -> Bool {
        guard let sub = gitSubcommand(launched), foldedWord(launched.guardArgv[sub]) == "commit" else { return false }
        return commitArgsSkipHooks(launched.guardArgv[(sub + 1)...].map(unescapeBackslashPairs))
    }

    private static func configMovesHooksPath(_ launched: LaunchedCommand) -> Bool {
        guard let sub = gitSubcommand(launched), foldedWord(launched.guardArgv[sub]) == "config" else { return false }
        let call = GitConfigCall(Array(launched.guardArgv[(sub + 1)...]).map(unescapeBackslashPairs))
        if call.unknownOption {
            return call.words.contains { foldedWord($0).contains("hookspath") || foldedWord($0) == "core" || isDynamic($0) }
        }
        switch call.mode {
        case .read:
            return false
        case .edit:
            return true
        case .removeSection, .renameSection:
            guard let old = call.operands.first else { return false }
            return foldedWord(old) == "core" || isDynamic(old)
        case .unset:
            guard let key = call.operands.first else { return false }
            return foldedWord(key) == "core.hookspath" || isDynamic(key)
        case .set:
            guard call.operands.count >= 2 else { return false }
            return foldedWord(call.operands[0]) == "core.hookspath" || isDynamic(call.operands[0])
        }
    }

    /// Short options of `git commit` that take a value (attached or next).
    private static let commitValueLetters: Set<Character> = ["m", "F", "c", "C", "t"]

    private static func commitArgsSkipHooks(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return false }
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                // git takes any unambiguous prefix; `--no-v` is the shortest.
                if name.count >= 6, "--no-verify".hasPrefix(name) { return true }
                if ["--message", "--file", "--reuse-message", "--reedit-message", "--template",
                    "--author", "--date", "--fixup", "--squash", "--trailer", "--cleanup", "--pathspec-from-file"]
                    .contains(name), arg.contains("=") == false
                {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                let letters = Array(arg.dropFirst())
                for (position, letter) in letters.enumerated() {
                    if letter == "n" { return true }
                    // `-uno`, `-Skey`: an attached optional value ends the cluster.
                    if letter == "u" || letter == "S" { break }
                    if commitValueLetters.contains(letter) {
                        // The rest of the word is the value, or the next word is.
                        if position == letters.count - 1 { index += 1 }
                        break
                    }
                }
                index += 1
                continue
            }
            // A dynamic word in option position may carry `-n`: fail closed.
            if arg.hasPrefix("$") { return true }
            index += 1
        }
        return false
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
        let folded = path.folding(options: .caseInsensitive, locale: nil)
        // `~/.gitconfig` as typed, with no home to expand it against.
        if ["~/.gitconfig", "~/.config/git/config"].contains(folded) { return true }
        guard let home else { return false }
        let homeFolded = home.folding(options: .caseInsensitive, locale: nil)
        let trimmedHome = homeFolded.hasSuffix("/") ? String(homeFolded.dropLast()) : homeFolded
        return [trimmedHome + "/.gitconfig", trimmedHome + "/.config/git/config"].contains(folded)
    }

    // MARK: git

    /// git global options that take the next word as their value.
    private static let gitValueGlobals: Set<String> = [
        "-c", "-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--exec-path",
    ]

    /// Index of git's subcommand in a launched git (or dynamic-head)
    /// command, past its global options and their values.
    private static func gitSubcommand(_ launched: LaunchedCommand) -> Int? {
        guard let head = launched.guardArgv.first, launched.headIsDynamic || commandName(head) == "git" else {
            return nil
        }
        return gitSubcommandIndex(launched.guardArgv)
    }

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

    /// git, or a head rv cannot name, run with a `-c`/`--config-env` entry or
    /// a `config` subcommand that writes a guarded key.
    private static func setsGuardedConfig(_ launched: LaunchedCommand) -> Bool {
        let argv = launched.guardArgv
        guard let head = argv.first, launched.headIsDynamic || commandName(head) == "git" else { return false }
        var index = 1
        while index < argv.count {
            let word = unescapeBackslashPairs(argv[index])
            if word.hasPrefix("--config-env=") {
                if guardedKey(configEntryKey(String(word.dropFirst("--config-env=".count)))) != nil { return true }
                index += 1
                continue
            }
            if gitValueGlobals.contains(word) {
                guard index + 1 < argv.count else { return false }
                let value = unescapeBackslashPairs(argv[index + 1])
                // `--config-env KEY=ENVVAR`: the value is not on the line.
                if word == "--config-env", guardedKey(configEntryKey(value)) != nil { return true }
                if word == "-c", entryWeakens(value) { return true }
                index += 2
                continue
            }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            guard foldedWord(word) == "config" else { return false }
            return configWeakens(GitConfigCall(Array(argv[(index + 1)...]).map(unescapeBackslashPairs)))
        }
        return false
    }

    /// The keys an agent's config may not write.
    private enum GuardedKey {
        /// `rv.secretsScan`: only a false value weakens.
        case scanSwitch
        /// `core.hooksPath`: moves the hook away.
        case hooksPath
        /// `include.path`, `includeIf.*.path`: a file rv cannot read.
        case include
        /// A key rv cannot read statically.
        case dynamic
    }

    private static func guardedKey(_ key: String) -> GuardedKey? {
        if isDynamic(key) { return .dynamic }
        let folded = foldedWord(key)
        if folded == switchKey { return .scanSwitch }
        if folded == "core.hookspath" { return .hooksPath }
        if folded == "include.path" || (folded.hasPrefix("includeif.") && folded.hasSuffix(".path")) {
            return .include
        }
        return nil
    }

    /// Whether setting `key` to `value` weakens the scan.
    private static func setWeakens(key: String, value: String) -> Bool {
        switch guardedKey(key) {
        case nil: false
        case .scanSwitch: isTrue(value) == false
        case .hooksPath, .include, .dynamic: true
        }
    }

    /// `-c KEY=VALUE`: a bare `-c KEY` means true.
    private static func entryWeakens(_ entry: String) -> Bool {
        let key = configEntryKey(entry)
        guard let eq = entry.firstIndex(of: "=") else {
            return guardedKey(key).map { $0 != .scanSwitch } ?? false
        }
        return setWeakens(key: key, value: String(entry[entry.index(after: eq)...]))
    }

    private static func configEntryKey(_ entry: String) -> String {
        String(entry.prefix { $0 != "=" })
    }

    private static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(foldedWord(value))
    }

    private static func isDynamic(_ word: String) -> Bool {
        word.contains("$") || word.contains("`")
    }

    /// `git config` arguments that write a guarded key, rename a section to
    /// `rv` or `include`, open an editor, or write into a scan control file.
    private static func configWeakens(_ call: GitConfigCall) -> Bool {
        if call.unknownOption {
            // An option rv cannot place may take a value or switch the mode:
            // any guarded key named at all is a stop.
            return call.words.contains { guardedKey(configEntryKey($0)) != nil }
                || call.words.contains { foldedWord($0) == "rv" || foldedWord($0).hasPrefix("include") }
        }
        if call.mode == .edit { return true }
        if call.mode != .read, let file = call.file,
           protectsFile(file, home: nil) || isDynamic(file) || foldedWord(file).hasSuffix("pre-commit")
        {
            return true
        }
        switch call.mode {
        case .read, .unset, .removeSection, .edit:
            return false
        case .renameSection:
            guard call.operands.count >= 2 else { return false }
            let new = call.operands[1]
            return foldedWord(new) == "rv" || foldedWord(new).hasPrefix("include") || isDynamic(new)
        case .set:
            guard call.operands.count >= 2 else { return false }
            return setWeakens(key: call.operands[0], value: call.operands[1])
        }
    }

    /// `GIT_CONFIG_KEY_n=<guarded key>`, `GIT_CONFIG_PARAMETERS` naming
    /// one, or another config file (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`,
    /// `GIT_CONFIG`) for the commands an agent runs.
    private static func setsConfigThroughEnvironment(_ launched: LaunchedCommand) -> Bool {
        var words = launched.assignments
        if let head = launched.guardArgv.first, ["export", "declare", "typeset", "env"].contains(commandName(head)) {
            words += launched.guardArgv.dropFirst()
        }
        return words.contains { word in
            let unquoted = unescapeBackslashPairs(word).filter { $0 != "'" && $0 != "\"" }
            guard let eq = unquoted.firstIndex(of: "=") else { return false }
            let name = String(unquoted[..<eq])
            let value = String(unquoted[unquoted.index(after: eq)...])
            if name.hasPrefix("GIT_CONFIG_KEY_") { return guardedKey(value) != nil }
            if name == "GIT_CONFIG_PARAMETERS" {
                let folded = foldedWord(value)
                return [switchKey, "core.hookspath", "include"].contains { folded.contains($0) } || isDynamic(value)
            }
            if ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG"].contains(name) { return value != "/dev/null" }
            return false
        }
    }

    // MARK: Shell writes

    /// Words a write of a scan control names; with none, only a write onto
    /// rv's hook (a `.husky` dir) can hold, and only a command that may
    /// write anything is parsed for one.
    private static let controlWords = [
        ".git", ".rv-secrets-ignore", "gitconfig", "git/config", allowMarker, "pre-commit",
    ]
    private static let writerWords = [
        ">", "rm", "mv", "cp", "ln", "chmod", "chown", "tee", "truncate", "sed", "install", "rsync", "dd",
        "unlink", "shred", "touch", "tar", "zip", "perl", "ditto", "patch", "rename", "mkdir",
    ]
    /// What an inline program must name to count: the controls themselves.
    private static let inlineMentions = [
        allowMarker, ".rv-secrets-ignore", "secretsscan", "hookspath", ".git/config", ".git/hooks", "gitconfig",
        "git/config",
    ]
    /// Interpreters whose inline program can write any file.
    private static let interpreters: Set<String> = [
        "python", "python2", "python3", "perl", "ruby", "node", "nodejs", "deno", "bun", "php", "lua",
        "awk", "gawk", "mawk", "nawk", "osascript", "pwsh", "powershell",
    ]

    private static func writesScanControls(
        _ raw: String,
        plain: String,
        launched: () -> [LaunchedCommand],
        home: HomePath?,
        cwd: WorkingDirectory?,
        hook: () -> String?
    ) -> Bool {
        let namesControl = controlWords.contains { plain.contains($0) }
        guard namesControl || writerWords.contains(where: { plain.contains($0) }) else { return false }
        let heads = launched()
        if inlineMentions.contains(where: { plain.contains($0) }), heads.contains(where: runsInlineProgram) {
            return true
        }
        // A very long command is not parsed path by path (`rm` with 32k
        // operands): naming a control is enough there.
        guard raw.utf8.count <= maximumParsedBytes else { return namesControl }
        let context = FilesystemAnalysisContext(workingDirectory: cwd, homeDirectory: home)
        // The command with `cd` followed, and each command it launches
        // (`sh -c '…'`, `sudo`, `rv run -- …`) on its own.
        var mutations = mutatedPaths(raw, context: context)
        for command in heads where command.truncated == false && command.headIsDynamic == false {
            mutations += mutatedPaths(rebuilt(command), context: context)
            mutations += chmodTargets(command, context: context)
        }
        mutations.removeAll { $0.path.hasPrefix("/dev/") }
        guard mutations.isEmpty == false else { return false }
        if plain.contains(allowMarker) { return true }
        if mutations.contains(where: { protectsFile($0.path, home: home?.rawValue) }) { return true }
        guard let hook = hook() else { return false }
        return mutations.contains { $0.path == hook || ($0.removesBelow && hook.hasPrefix($0.path + "/")) }
    }

    private static let maximumParsedBytes = 8192

    /// `chmod -x FILE`: the filesystem parser reads `-x` as an unknown
    /// flag, so chmod's operands are taken here; every word after the mode
    /// is a target.
    private static func chmodTargets(_ command: LaunchedCommand, context: FilesystemAnalysisContext) -> [Mutation] {
        guard let head = command.guardArgv.first, commandName(head) == "chmod" else { return [] }
        let operands = command.guardArgv.dropFirst().map(unescapeBackslashPairs)
        guard let mode = operands.firstIndex(where: isChmodModeWord) else { return [] }
        return operands[(mode + 1)...].filter { $0.hasPrefix("-") == false }.map { word in
            let path = lexicalFilesystemPath(
                word, workingDirectory: context.workingDirectory, homeDirectory: context.homeDirectory
            )
            return Mutation(path: path, removesBelow: false)
        }
    }

    /// `755`, `-x`, `a-w`, `u+x,g-w`.
    private static func isChmodModeWord(_ word: String) -> Bool {
        guard word.isEmpty == false else { return false }
        if word.allSatisfy(\.isNumber) { return true }
        return word.allSatisfy { "ugoa+-=rwxXstugo,0123456789".contains($0) }
            && word.contains(where: { "+-=".contains($0) })
    }

    /// `python3 -c`, `perl -pi -e`, `node -e`, `awk '…'`: a program rv
    /// does not read as shell.
    private static func runsInlineProgram(_ launched: LaunchedCommand) -> Bool {
        guard let head = launched.guardArgv.first else { return false }
        let name = commandName(head)
        let program = name.hasPrefix("python") ? "python" : name
        guard interpreters.contains(program) || interpreters.contains(name) else { return false }
        if ["awk", "gawk", "mawk", "nawk"].contains(name) { return true }
        return launched.guardArgv.dropFirst().contains { arg in
            let word = unescapeBackslashPairs(arg)
            guard word.hasPrefix("-"), word.hasPrefix("--") == false else {
                return ["--eval", "--print", "--command"].contains(foldedWord(word))
            }
            return word.contains("c") || word.contains("e") || word.contains("E") || word.contains("i")
                || word.contains("p")
        }
    }

    /// One path a command writes. `removesBelow`: a delete or a move source,
    /// which takes everything under a directory with it.
    private struct Mutation {
        let path: String
        let removesBelow: Bool
    }

    private static func mutatedPaths(_ text: String, context: FilesystemAnalysisContext) -> [Mutation] {
        let command = ShellCommand(rawValue: text)
        let values = ShellPipeline.collectTopLevelAssignmentValues(ShellPipeline.peelStage(text))
        return parseFilesystemSegments(chainSegmentView(of: command), context: context, assignmentValues: values)
            .flatMap { action -> [Mutation] in
                switch action {
                case .read:
                    return []
                case .delete(let targets, _, _):
                    return targets.map { Mutation(path: $0.canonical, removesBelow: true) }
                case .move(let sources, let destination):
                    return sources.map { Mutation(path: $0.canonical, removesBelow: true) }
                        + [Mutation(path: destination.canonical, removesBelow: false)]
                case .overwrite(let targets), .chmod(let targets, _, _), .create(let targets):
                    return targets.map { Mutation(path: $0.canonical, removesBelow: false) }
                }
            }
    }

    /// A launched command as shell text again, each word quoted.
    private static func rebuilt(_ command: LaunchedCommand) -> String {
        let words = command.guardArgv.map(quoted) + command.redirects.map { word in
            word.contains(">") || word.contains("<") ? word : quoted(word)
        }
        return words.joined(separator: " ")
    }

    private static func quoted(_ word: String) -> String {
        let safe = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./~=:,+@%".contains($0) }
        if safe, word.isEmpty == false { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes, `[x]` classes, backslashes and line continuations folded away,
    /// case-folded: `"rv.secrets"'Scan'`, `rv.secrets\Scan` and
    /// `RV.SECRETSSCAN` all name the switch.
    private static func plainText(_ raw: String) -> String {
        foldHiddenMentions(raw)
            .replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "\\", with: "")
    }
}

/// `git config` arguments, options parsed the way git's parse-options does:
/// a long option by its unique prefix, `--opt=value` or `--opt value`, short
/// clusters with an attached or next-word value. An option rv does not know
/// sets `unknownOption`; the caller then fails closed.
struct GitConfigCall {
    enum Mode: Equatable {
        case read, set, unset, removeSection, renameSection, edit
    }

    let words: [String]
    private(set) var mode: Mode = .set
    /// Key, value and other operands, verb removed.
    private(set) var operands: [String] = []
    /// `--file`/`-f`.
    private(set) var file: String?
    private(set) var unknownOption = false

    private static let longFlags: [String] = [
        "--global", "--system", "--local", "--worktree", "--bool", "--int", "--bool-or-int", "--path",
        "--expiry-date", "--no-type", "--null", "--name-only", "--no-name-only", "--show-origin",
        "--no-show-origin", "--show-scope", "--no-show-scope", "--includes", "--no-includes", "--fixed-value",
        "--all", "--regexp", "--replace-all", "--add", "--append", "--no-value", "--get", "--get-all",
        "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--unset", "--unset-all",
        "--rename-section", "--remove-section", "--list", "--edit",
    ]
    private static let longValues: [String] = [
        "--file", "--blob", "--type", "--default", "--comment", "--value", "--url",
    ]
    private static let readFlags: Set<String> = [
        "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list",
    ]
    private static let verbs: [String: Mode] = [
        "get": .read, "list": .read, "set": .set, "unset": .unset, "edit": .edit,
        "rename-section": .renameSection, "remove-section": .removeSection,
    ]

    init(_ args: [String]) {
        words = args
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if optionsEnded || arg == "-" || arg.hasPrefix("-") == false {
                positionals.append(arg)
                continue
            }
            if arg == "--" {
                optionsEnded = true
                continue
            }
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                guard let option = Self.resolve(name) else {
                    unknownOption = true
                    continue
                }
                if Self.longValues.contains(option) {
                    var value: String?
                    if let eq = arg.firstIndex(of: "=") {
                        value = String(arg[arg.index(after: eq)...])
                    } else if index < args.count {
                        value = args[index]
                        index += 1
                    }
                    if option == "--file" { file = value }
                    if option == "--blob" { flags.insert("--blob") }
                } else {
                    flags.insert(option)
                }
                continue
            }
            // A short cluster: `-l`, `-e`, `-z`, `-f FILE`, `-tbool`.
            for (offset, letter) in arg.dropFirst().enumerated() {
                switch letter {
                case "l": flags.insert("--list")
                case "e": flags.insert("--edit")
                case "z": flags.insert("--null")
                case "f", "t":
                    let rest = String(arg.dropFirst(offset + 2))
                    var value: String? = rest.isEmpty ? nil : rest
                    if value == nil, index < args.count {
                        value = args[index]
                        index += 1
                    }
                    if letter == "f" { file = value }
                default:
                    unknownOption = true
                }
                if letter == "f" || letter == "t" { break }
            }
        }
        if let verb = positionals.first.map(foldedWord), let mode = Self.verbs[verb] {
            self.mode = mode
            positionals.removeFirst()
        } else if flags.contains("--edit") {
            mode = .edit
        } else if flags.isDisjoint(with: Self.readFlags) == false || flags.contains("--blob") {
            mode = .read
        } else if flags.contains("--unset") || flags.contains("--unset-all") {
            mode = .unset
        } else if flags.contains("--remove-section") {
            mode = .removeSection
        } else if flags.contains("--rename-section") {
            mode = .renameSection
        } else if positionals.count < 2 {
            // `git config KEY`: a read.
            mode = .read
        }
        operands = positionals
    }

    /// The long option `name` names: exact, or its only prefix match.
    private static func resolve(_ name: String) -> String? {
        let all = longFlags + longValues
        if all.contains(name) { return name }
        let matches = all.filter { $0.hasPrefix(name) }
        return matches.count == 1 ? matches[0] : nil
    }
}
