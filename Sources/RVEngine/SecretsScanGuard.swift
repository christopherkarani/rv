import RVDomain

/// The pre-commit secrets scan (`rv secrets hook install`) is the owner's
/// check on what leaves the machine, so only the owner may switch it off or
/// silence it. The hook skips the scan when `git config --local
/// rv.secretsScan` is false, and the scanner honours `rv-secrets:allow`
/// comments and `.rv-secrets-ignore` entries; none of that knows who set it.
/// An agent that hits the check is offered the fix (move the key into rv),
/// never the off switch.
///
/// `weakensScan` matches on structure, never on a word anywhere in the text:
/// - git config that sets `rv.secretsScan` to anything but a true spelling,
///   sets `include.path`/`includeIf.*.path` or a global `core.hooksPath`,
///   renames a section to `rv` or `include`, or opens an editor: `git config`
///   (options parsed the way git does, unique prefixes included; an option
///   rv does not know fails closed when a guarded key is named), `git -c`,
///   `--config-env`, and the `GIT_CONFIG_*` environment;
/// - a shell write, move, delete or chmod (`>`, `tee`, `sed -i`, `cp`,
///   `rm`, `chmod -x`, … with `cd` followed) of `.rv-secrets-ignore`, a
///   repository's `.git/config` or `.git/hooks`, or the user's global git
///   config;
/// - a command that writes `rv-secrets:allow` (`echo`, `sed -i`, a `cat`
///   heredoc into a file), or an inline interpreter program (`python3 -c`,
///   `perl -pi -e`, `awk`) that writes and names a scan control;
/// - where rv's hook is installed in the repository the command acts on
///   (`installedHook`, which the caller answers from the filesystem; `cd`,
///   `-C` and `--git-dir` followed): `git commit --no-verify`/`-n`, `git
///   commit-tree`, a commit run with `HOME`, `PATH` or `XDG_CONFIG_HOME`
///   changed, a git alias that skips hooks or runs a shell (`!`), setting,
///   unsetting or moving a repository's `core.hooksPath`, and a write,
///   delete or move of that `pre-commit` file or a directory above it.
/// Programs `xargs` and `find -exec` run are followed. Reads, `git add`,
/// searches, tests, and a commit message (`-m`, a `cat` heredoc in `$(…)`)
/// that names the controls stay allowed.
///
/// `protectsFile` is the file door's half: an agent's Write or Edit of
/// `.rv-secrets-ignore`, a repository's git config or hooks, or the user's
/// global git config.
///
/// Like `SecretServiceGuard` it is a `core.secrets` deny, which no allow-once
/// unlocks: the owner runs the command in their own terminal. Not seen: an
/// allow comment written through a file-edit tool's content (the file door
/// carries only the path), a patch applied with `git apply`, and a script
/// file the agent writes and then runs.
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

    /// Directories probed for rv's hook in one evaluation, at most.
    static let maximumProbes = 8
    /// What `hook(near:)` answers past `maximumProbes`: a repository rv did
    /// not look at, which may hold rv's hook.
    static let unprobedHook = "\u{0}unprobed"

    /// `installedHook(directory)` answers the absolute path of the
    /// `pre-commit` holding rv's block for the repository at or above
    /// `directory` (which may be a git dir, or not exist yet), or nil. It is
    /// asked only for a command that could skip, move or replace hooks, at
    /// most `maximumProbes` times, and never without a `cwd` to resolve
    /// relative paths against.
    ///
    /// `leavingGitInternals`: writes inside a `.git` directory are left to
    /// the protected-path rule, already pinned, which names them as git
    /// internals (the engine's own fold, before filesystem semantics run).
    ///
    /// `isScratch(path)` answers whether a write target spelled under a
    /// temporary directory really is scratch space: no symlink takes it
    /// elsewhere and no repository holds it. Only then may a search's
    /// report of marker lines go there (`grep -rn rv-secrets:allow . >
    /// /tmp/hits`). The engine alone cannot look, so it trusts the spelling;
    /// the service answers from the filesystem and fails closed.
    public static func weakensScan(
        _ command: ShellCommand,
        home: HomePath? = nil,
        cwd: WorkingDirectory? = nil,
        leavingGitInternals: Bool = false,
        installedHook: (String) -> String? = { _ in nil },
        isScratch: (String) -> Bool = { _ in true }
    ) -> Bool {
        let raw = command.rawValue
        // The engine refuses a longer command before any rule runs.
        guard raw.utf8.count <= commandByteCap else { return false }
        let data = DataHeredocs(raw)
        let text = data.text
        let plain = plainText(text)
        var launchedMemo: [LaunchedCommand]?
        func launched() -> [LaunchedCommand] {
            if let launchedMemo { return launchedMemo }
            let heads = followingXargs(followingFindExec(launchedCommandHeads(text)))
            launchedMemo = heads
            return heads
        }
        var probed: [String: String?] = [:]
        func hook(near directories: [String]) -> String? {
            for directory in directories {
                if directory == unknownDirectory { return unprobedHook }
                if let known = probed[directory] {
                    if let known { return known }
                    continue
                }
                // Past the cap the repository is unknown: fail closed.
                guard probed.count < maximumProbes else { return unprobedHook }
                let found = installedHook(directory)
                probed[directory] = .some(found)
                if let found { return found }
            }
            return nil
        }
        if data.writesMarker { return true }
        if gitScreen.contains(where: { plain.contains($0) }) {
            let chainSetsEnvironment = setsHookEnvironment(plain)
            var gated: [Placed] = []
            for entry in placing(launched(), cwd: cwd, home: home) {
                switch gitReach(entry.command, plain: plain, chainSetsEnvironment: chainSetsEnvironment) {
                case .none: continue
                case .always: return true
                case .whereHookIs: gated.append(entry)
                }
            }
            for entry in gated {
                // A target rv cannot place (`-C {}`, `-C $R`, xargs input) may be any repository.
                guard let directories = gitDirectories(entry.command, from: entry.directories, home: home) else {
                    return true
                }
                if hook(near: directories) != nil { return true }
            }
        }
        if plain.contains("git_config"), launched().contains(where: setsConfigThroughEnvironment) { return true }
        return writesScanControls(
            text, plain: plain, launched: launched, home: home, cwd: cwd,
            leavingGitInternals: leavingGitInternals, isScratch: isScratch, hook: hook
        )
    }

    /// Words a git form this guard judges needs: the program, a guarded
    /// key, or a dynamic word that may be either.
    private static let gitScreen = ["git", "config", "secretsscan", "hookspath", "include", "commit", "$", "`"]

    /// `git commit --no-verify` (`-n`, an abbreviation, or a short cluster
    /// holding `n`) skips every pre-commit hook, rv's scan included. Only a
    /// repository with rv's hook installed makes this a stop
    /// (`weakensScan`'s `installedHook`).
    public static func skipsCommitHook(_ command: ShellCommand) -> Bool {
        guard plainText(command.rawValue).contains("commit") else { return false }
        return launchedCommandHeads(command.rawValue).contains { launched in
            guard let sub = gitSubcommand(launched), foldedWord(launched.guardArgv[sub]) == "commit" else {
                return false
            }
            return commitArgsSkipHooks(launched.guardArgv[(sub + 1)...].map(unescapeBackslashPairs))
        }
    }

    /// git config that moves hooks away from where rv's hook is: unsetting
    /// or setting `core.hooksPath`, or removing or renaming the `[core]`
    /// section. A global one is a stop in every repository; the rest only
    /// where rv's hook is installed.
    public static func movesHooksPath(_ command: ShellCommand) -> Bool {
        launchedCommandHeads(command.rawValue).contains { launched in
            guard let sub = gitSubcommand(launched), foldedWord(launched.guardArgv[sub]) == "config" else {
                return false
            }
            return movesHooks(GitConfigCall(Array(launched.guardArgv[(sub + 1)...]).map(unescapeBackslashPairs)))
        }
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

    /// How far a command weakens the scan.
    enum Reach: Comparable {
        case none
        /// Only where rv's hook is installed in the repository it acts on.
        case whereHookIs
        /// In every repository.
        case always
    }

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
        var index = 1
        while index < launched.guardArgv.count {
            let word = unescapeBackslashPairs(launched.guardArgv[index])
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

    /// git, or a head rv cannot name: its `-c`/`--config-env` entries, its
    /// `config` subcommand, and a commit that skips hooks.
    private static func gitReach(_ launched: LaunchedCommand, plain: String, chainSetsEnvironment: Bool) -> Reach {
        let argv = launched.guardArgv
        guard let head = argv.first, launched.headIsDynamic || commandName(head) == "git" else { return .none }
        var reach = Reach.none
        // `--exec-path=DIR`: git runs its commit programs from DIR.
        var execPath = false
        var index = 1
        while index < argv.count {
            let word = unescapeBackslashPairs(argv[index])
            if word == "--exec-path" || word.hasPrefix("--exec-path=") { execPath = true }
            if word.hasPrefix("--config-env=") {
                reach = max(reach, environmentEntryReach(String(word.dropFirst("--config-env=".count))))
                index += 1
                continue
            }
            if gitValueGlobals.contains(word) {
                guard index + 1 < argv.count else { return reach }
                let value = unescapeBackslashPairs(argv[index + 1])
                // `--config-env KEY=ENVVAR`: the value is not on the line.
                if word == "--config-env" { reach = max(reach, environmentEntryReach(value)) }
                if word == "-c" { reach = max(reach, entryReach(value)) }
                index += 2
                continue
            }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            let args = Array(argv[(index + 1)...]).map(unescapeBackslashPairs)
            let subcommand = foldedWord(word)
            if execPath, commitFamily.contains(subcommand) { reach = max(reach, .whereHookIs) }
            switch subcommand {
            case "config":
                reach = max(reach, configReach(GitConfigCall(args), plain: plain))
            case "commit":
                if commitArgsSkipHooks(args) || chainSetsEnvironment || setsHookEnvironment(launched.assignments) {
                    reach = max(reach, .whereHookIs)
                }
            case "commit-tree", "fast-import":
                // Writes commit objects no hook ever sees.
                reach = max(reach, .whereHookIs)
            case "am":
                // Commits patches without the pre-commit hook.
                if args.contains(where: { ["--abort", "--quit", "--show-current-patch"].contains($0) }) == false {
                    reach = max(reach, .whereHookIs)
                }
            case "hash-object":
                if writesCommitObject(args) { reach = max(reach, .whereHookIs) }
            default:
                // `git $(echo config) …`, `git $SUB`: any subcommand.
                if launched.headIsDynamic == false, isDynamic(word) {
                    let named = ["secretsscan", "hookspath", "include", "alias"].contains { plain.contains($0) }
                    reach = max(reach, named ? .always : .whereHookIs)
                }
            }
            return reach
        }
        return reach
    }

    /// Subcommands that make commits, which `--exec-path` can redirect.
    private static let commitFamily: Set<String> = [
        "commit", "commit-tree", "merge", "am", "cherry-pick", "revert", "rebase", "pull",
    ]

    /// `git hash-object -t commit` (`-tcommit`, `--type=commit`): a commit
    /// object built by hand, then pointed at with `update-ref`.
    private static func writesCommitObject(_ args: [String]) -> Bool {
        zip(args, args.dropFirst()).contains { ($0 == "-t" || $0 == "--type") && foldedWord($1) == "commit" }
            || args.contains { ["-tcommit", "--type=commit"].contains(foldedWord($0)) }
    }

    /// The directories whose repository a git command acts on: each place
    /// it may run from, with `-C` applied in order, or its `--git-dir`
    /// (`GIT_DIR`). Nil when a target is a placeholder or variable rv cannot
    /// place (`find -exec git -C {}`, `xargs -I{} git -C {}`, `-C $R`).
    private static func gitDirectories(_ launched: LaunchedCommand, from directories: [String], home: HomePath?) -> [String]? {
        // With no directory known, an absolute `-C`/`--git-dir` still places it.
        var places: [String?] = directories.isEmpty ? [nil] : directories
        var gitDir = launched.assignments.compactMap { word -> String? in
            let unquoted = unescapeBackslashPairs(word).filter { $0 != "'" && $0 != "\"" }
            return unquoted.hasPrefix("GIT_DIR=") ? String(unquoted.dropFirst("GIT_DIR=".count)) : nil
        }.last
        let argv = launched.guardArgv
        var index = 1
        while index < argv.count {
            let word = unescapeBackslashPairs(argv[index])
            let next = index + 1 < argv.count ? unescapeBackslashPairs(argv[index + 1]) : nil
            if word == "-C", let next {
                guard isPlaceholder(next) == false else { return nil }
                places = places.map { $0 == unknownDirectory ? $0 : resolving(next, in: $0, home: home) }
                index += 2
            } else if word.hasPrefix("--git-dir=") {
                gitDir = String(word.dropFirst("--git-dir=".count))
                index += 1
            } else if word == "--git-dir", let next {
                gitDir = next
                index += 2
            } else if gitValueGlobals.contains(word) {
                index += 2
            } else if word.hasPrefix("-") {
                index += 1
            } else {
                break
            }
        }
        guard let gitDir, gitDir.isEmpty == false else { return places.compactMap { $0 } }
        guard isPlaceholder(gitDir) == false else { return nil }
        return places.compactMap { $0 == unknownDirectory ? $0 : resolving(gitDir, in: $0, home: home) }
    }

    private static func isPlaceholder(_ word: String) -> Bool {
        isDynamic(word) || word.contains("{}")
    }

    /// The keys an agent's config may not write.
    private enum GuardedKey {
        /// `rv.secretsScan`: only a false value weakens.
        case scanSwitch
        /// `core.hooksPath`: moves the hook away.
        case hooksPath
        /// `include.path`, `includeIf.*.path`: a file rv cannot read.
        case include
        /// `alias.*`: an alias can skip hooks or run a shell.
        case alias
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
        if folded.hasPrefix("alias.") { return .alias }
        return nil
    }

    /// Setting `key` to `value` (nil: not on the line) for one command
    /// (`-c`) or in a repository's config; `widensScope`: `--global` or
    /// `--system`, every repository.
    private static func setReach(key: String, value: String?, widensScope: Bool) -> Reach {
        switch guardedKey(key) {
        case nil:
            return .none
        case .scanSwitch:
            return value.map(isTrue) == true ? .none : .always
        case .include, .dynamic:
            return .always
        case .hooksPath:
            return widensScope ? .always : .whereHookIs
        case .alias:
            guard let value else { return widensScope ? .always : .whereHookIs }
            // A user- or machine-wide alias reaches every repository.
            if widensScope, aliasCertainlySkips(value) { return .always }
            // `!git config rv.secretsScan false`: a shell alias is judged by
            // what it names, everywhere.
            if value.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("!"),
               aliasMentions.contains(where: { plainText(value).contains($0) })
            {
                return .always
            }
            return aliasSkipsHooks(value) ? .whereHookIs : .none
        }
    }

    private static let aliasMentions = [
        "secretsscan", "hookspath", "include", allowMarker, ".rv-secrets-ignore", ".git/", "gitconfig", "git/config",
    ]

    /// `-c KEY=VALUE`: a bare `-c KEY` means true.
    private static func entryReach(_ entry: String) -> Reach {
        let key = configEntryKey(entry)
        guard let eq = entry.firstIndex(of: "=") else {
            return guardedKey(key) == .scanSwitch ? .none : setReach(key: key, value: "true", widensScope: false)
        }
        return setReach(key: key, value: String(entry[entry.index(after: eq)...]), widensScope: false)
    }

    /// `--config-env KEY=ENVVAR`: the value is not on the line.
    private static func environmentEntryReach(_ entry: String) -> Reach {
        setReach(key: configEntryKey(entry), value: nil, widensScope: false)
    }

    private static func configEntryKey(_ entry: String) -> String {
        String(entry.prefix { $0 != "=" })
    }

    private static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(foldedWord(value))
    }

    static func isDynamic(_ word: String) -> Bool {
        word.contains("$") || word.contains("`")
    }

    /// An alias body that skips hooks for sure: a commit that skips them,
    /// `commit-tree`, or a shell alias that runs one (or a word rv cannot
    /// read).
    private static func aliasCertainlySkips(_ body: String) -> Bool {
        let trimmed = body.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("!") else { return aliasSkipsHooks(body) }
        let shell = String(trimmed.dropFirst())
        let folded = plainText(shell)
        return isDynamic(shell) || folded.contains("--no-verify") || folded.contains("commit-tree")
            || skipsCommitHook(ShellCommand(rawValue: shell))
    }

    /// An alias body that runs a shell (`!…`) or a commit that skips hooks.
    private static func aliasSkipsHooks(_ body: String) -> Bool {
        if isDynamic(body) { return true }
        let trimmed = body.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("!") { return true }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let sub = words.firstIndex(where: { foldedWord($0) == "commit" || foldedWord($0) == "commit-tree" })
        else { return false }
        return foldedWord(words[sub]) == "commit-tree" || commitArgsSkipHooks(Array(words[(sub + 1)...]))
    }

    /// `git config` arguments.
    private static func configReach(_ call: GitConfigCall, plain: String) -> Reach {
        if call.unknownOption {
            // An option rv cannot place may take a value or switch the mode:
            // any guarded key named at all is a stop.
            let keys = call.words.compactMap { guardedKey(configEntryKey($0)) }
            if keys.contains(where: { $0 == .scanSwitch || $0 == .include || $0 == .dynamic })
                || call.words.contains(where: { foldedWord($0) == "rv" || foldedWord($0).hasPrefix("include") })
            {
                return .always
            }
            return keys.isEmpty && movesHooks(call) == false ? .none : .whereHookIs
        }
        if call.mode == .edit { return .always }
        if call.mode != .read, let file = call.file,
           protectsFile(file, home: nil) || isDynamic(file) || foldedWord(file).hasSuffix("pre-commit")
        {
            return .always
        }
        if movesHooks(call) { return call.widensScope ? .always : .whereHookIs }
        switch call.mode {
        case .read:
            // `git config $ARGS`, `xargs git config`: a dynamic operand may
            // expand to a key and a value.
            guard call.implicitRead, call.operands.contains(where: isDynamic) else { return .none }
            let named = ["secretsscan", "hookspath", "include", "alias"].contains { plain.contains($0) }
            return named || call.operands.contains(where: { $0.contains(xargsStandIn) }) ? .always : .none
        case .unset, .removeSection, .edit:
            return .none
        case .renameSection:
            guard call.operands.count >= 2 else { return .none }
            let new = foldedWord(call.operands[1])
            if new == "rv" || new.hasPrefix("include") || isDynamic(new) { return .always }
            return new == "alias" ? .whereHookIs : .none
        case .set:
            guard call.operands.count >= 2 else { return .none }
            return setReach(key: call.operands[0], value: call.operands[1], widensScope: call.widensScope)
        }
    }

    /// Unsetting or setting `core.hooksPath`, or removing or renaming the
    /// `[core]` section.
    private static func movesHooks(_ call: GitConfigCall) -> Bool {
        if call.unknownOption {
            return call.words.contains { foldedWord($0).contains("hookspath") || foldedWord($0) == "core" || isDynamic($0) }
        }
        switch call.mode {
        case .read, .edit:
            return false
        case .removeSection, .renameSection:
            guard let old = call.operands.first else { return false }
            return foldedWord(old) == "core" || isDynamic(old)
        case .unset:
            guard let key = call.operands.first else { return false }
            return foldedWord(key) == "core.hookspath" || isDynamic(key)
        case .set:
            guard call.operands.count >= 2 else { return false }
            return foldedWord(call.operands[0]) == "core.hookspath"
        }
    }

    /// Short options of `git commit` that take a value (attached or next).
    private static let commitValueLetters: Set<Character> = ["m", "F", "c", "C", "t"]

    static func commitArgsSkipHooks(_ args: [String]) -> Bool {
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
            if arg.hasPrefix("$") || arg.contains(xargsStandIn) { return true }
            index += 1
        }
        return false
    }

    /// Variables the hook's environment takes from the commit: `HOME` and
    /// `XDG_CONFIG_HOME` pick the config and the store an older hook reads,
    /// `PATH` and `GIT_EXEC_PATH` the programs it runs. `words` are
    /// assignment words, or the whole folded line (a statement such as
    /// `export HOME=/tmp` before the commit).
    private static let hookEnvironment = ["home=", "path=", "xdg_config_home=", "git_exec_path="]

    private static func setsHookEnvironment(_ assignments: [String]) -> Bool {
        assignments.contains { word in
            let folded = foldedWord(unescapeBackslashPairs(word))
            return hookEnvironment.contains { folded.hasPrefix($0) }
        }
    }

    private static func setsHookEnvironment(_ plain: String) -> Bool {
        guard hookEnvironment.contains(where: { plain.contains($0) }) else { return false }
        let words = plain.split(whereSeparator: { " \t\n;&|(){}`".contains($0) }).map(String.init)
        return setsHookEnvironment(words)
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
                return [switchKey, "core.hookspath", "include", "alias."].contains { folded.contains($0) }
                    || isDynamic(value)
            }
            if ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG"].contains(name) { return value != "/dev/null" }
            return false
        }
    }

    /// Quotes, `[x]` classes, backslashes and line continuations folded away,
    /// case-folded: `"rv.secrets"'Scan'`, `rv.secrets\Scan` and
    /// `RV.SECRETSSCAN` all name the switch.
    static func plainText(_ raw: String) -> String {
        foldHiddenMentions(raw)
            .replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "\\", with: "")
    }
}
