import RVDomain

/// `SecretsScanGuard`'s shell half: where each command runs, and the writes,
/// deletes and inline programs that reach a scan control.
extension SecretsScanGuard {
    // MARK: Where a command runs

    /// A launched command and the directories it may run in.
    struct Placed {
        let command: LaunchedCommand
        /// The directory the `cd`s before it leave, first, then every other
        /// directory the line ran in: a `cd` in a subshell or a pipeline
        /// does not carry, and rv does not model which ones do.
        let directories: [String]
    }

    /// `cd`, `pushd` and `popd` followed in order (`-`, `popd` and a dynamic
    /// operand leave the directory unknown). Only the first
    /// `maximumProbes` other directories are kept, since no more are ever
    /// probed; past them, and past a path longer than `maximumPathBytes`,
    /// `unknownDirectory` stands in (probing it fails closed). Linear in the
    /// number of commands.
    static func placing(_ commands: [LaunchedCommand], cwd: WorkingDirectory?, home: HomePath?) -> [Placed] {
        var current = cwd?.rawValue
        var seen = cwd.map { [$0.rawValue] } ?? []
        var overflowed = false
        var out: [Placed] = []
        out.reserveCapacity(commands.count)
        for command in commands {
            var directories = current.map { [$0] } ?? []
            directories += seen.filter { $0 != current }
            if overflowed { directories.append(unknownDirectory) }
            out.append(Placed(command: command, directories: directories))
            guard let head = command.guardArgv.first,
                  ["cd", "pushd", "popd", "chdir"].contains(commandName(head)) else { continue }
            let operand = command.guardArgv.dropFirst().map(unescapeBackslashPairs)
                .first { $0 == "-" || $0.hasPrefix("-") == false }
            if commandName(head) == "popd" || operand == "-" {
                current = nil
            } else if let operand {
                current = isDynamic(operand) ? nil : resolving(operand, in: current, home: home)
            } else {
                current = home?.rawValue
            }
            if let path = current, path.utf8.count > maximumPathBytes {
                current = nil
                overflowed = true
            }
            guard let current, seen.contains(current) == false else { continue }
            if seen.count < maximumProbes { seen.append(current) } else { overflowed = true }
        }
        return out
    }

    /// Stands in for directories `placing` did not keep.
    static let unknownDirectory = "\u{0}unknown"
    static let maximumPathBytes = 4096

    /// `word` as an absolute path from `base`, or nil when it stays relative.
    static func resolving(_ word: String, in base: String?, home: HomePath?) -> String? {
        let path = lexicalFilesystemPath(
            word, workingDirectory: base.flatMap(WorkingDirectory.init(validating:)), homeDirectory: home
        )
        return path.hasPrefix("/") ? path : nil
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
        "git/config", "pre-commit",
    ]
    /// Interpreters whose inline program can write any file.
    private static let interpreters: Set<String> = [
        "python", "python2", "python3", "perl", "ruby", "node", "nodejs", "deno", "bun", "php", "lua",
        "awk", "gawk", "mawk", "nawk", "osascript", "pwsh", "powershell",
    ]
    private static let awks: Set<String> = ["awk", "gawk", "mawk", "nawk"]
    /// Searches and readers: an `rv-secrets:allow` in their arguments is a
    /// pattern, and their output a report (`grep -rn rv-secrets:allow . >
    /// /tmp/hits`).
    private static let readers: Set<String> = [
        "grep", "egrep", "fgrep", "rg", "ag", "ack", "git", "find", "fd", "less", "more", "head", "tail", "wc",
        "cat", "bat", "ls", "sort", "uniq", "test", "[", "jq", "yq", "diff", "cmp", "file", "stat",
    ]

    static func writesScanControls(
        _ text: String,
        plain: String,
        launched: () -> [LaunchedCommand],
        home: HomePath?,
        cwd: WorkingDirectory?,
        leavingGitInternals: Bool,
        isScratch: (String) -> Bool,
        hook: ([String]) -> String?
    ) -> Bool {
        let namesControl = controlWords.contains { plain.contains($0) }
        guard namesControl || writerWords.contains(where: { plain.contains($0) }) else { return false }
        let heads = launched()
        if inlineMentions.contains(where: { plain.contains($0) }), heads.contains(where: inlineProgramWritesControl) {
            return true
        }
        // A very long command is not parsed path by path (`rm` with 32k
        // operands): a writer that names a control is enough there.
        guard text.utf8.count <= maximumParsedBytes else {
            let controls = [".rv-secrets-ignore", "/.gitconfig", ".config/git/config", allowMarker]
                + (leavingGitInternals ? [] : [".git/"])
            return controls.contains { plain.contains($0) }
        }
        let context = FilesystemAnalysisContext(workingDirectory: cwd, homeDirectory: home)
        // The command with `cd` followed, and each command it launches
        // (`sh -c '…'`, `sudo`, `rv run -- …`, xargs) on its own.
        var mutations = mutatedPaths(text, context: context)
        for command in heads where command.truncated == false && command.headIsDynamic == false {
            mutations += mutatedPaths(rebuilt(command), context: context) + chmodTargets(command, context: context)
        }
        mutations.removeAll { discardingSinks.contains($0.path) || (leavingGitInternals && isGitInternalPath($0.path)) }
        // A search's report of marker lines may go to scratch space
        // (`grep -rn rv-secrets:allow . > /tmp/hits`); anywhere else,
        // `/dev/fd/3` included, its output is marker lines written into a
        // file.
        if plain.contains(allowMarker), mutations.isEmpty == false,
           markerIsOnlySearched(plain, heads) == false
            || mutations.contains(where: { isScratchTarget($0, isScratch: isScratch) == false })
        {
            return true
        }
        mutations.removeAll { $0.path.hasPrefix("/dev/") }
        guard mutations.isEmpty == false else { return false }
        if mutations.contains(where: { protectsFile($0.path, home: home?.rawValue) }) { return true }
        // rv's hook where `core.hooksPath` puts it (`.husky/pre-commit`): a
        // write of a `pre-commit` file, or a delete or move above one.
        let reaching = mutations.filter { $0.removesBelow || lastComponent($0.path) == "pre-commit" }
        var directories: [String] = []
        for mutation in reaching where mutation.path.hasPrefix("/") {
            let parent = parentPath(mutation.path)
            if directories.contains(parent) == false { directories.append(parent) }
        }
        for directory in directories {
            guard let hook = hook([directory]) else { continue }
            if hook == unprobedHook || reaching.contains(where: { $0.reaches(hook) }) { return true }
        }
        return false
    }

    static let maximumParsedBytes = 8192

    /// Whether every `rv-secrets:allow` on the line is an argument of a
    /// search or reader (`grep -rn rv-secrets:allow . > /tmp/hits`). Any
    /// other place it appears (an `echo` or `printf` feeding a pipe or a
    /// group, a heredoc body, a comment) may reach the file the line
    /// writes, so the marker plus any write is the stop.
    private static func markerIsOnlySearched(_ plain: String, _ heads: [LaunchedCommand]) -> Bool {
        var seen: Set<[String]> = []
        var searched = 0
        for command in heads where seen.insert(command.guardArgv).inserted {
            let carrying = command.guardArgv.filter { plainText($0).contains(allowMarker) }.count
            guard carrying > 0 else { continue }
            guard let head = command.guardArgv.first, readers.contains(commandName(head)),
                  command.truncated == false, command.headIsDynamic == false
            else { return false }
            searched += carrying
        }
        return searched > 0 && plain.components(separatedBy: allowMarker).count - 1 <= searched
    }

    /// Writes that land nowhere a file can hold them.
    private static let discardingSinks: Set<String> = ["/dev/null", "/dev/stdout", "/dev/stderr"]
    public static let temporaryRoots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]

    /// Spelled under a temporary directory with no `..` (`/tmp/../repo`,
    /// `/tmp/link/../a.ts` may land anywhere), and scratch by `isScratch`.
    private static func isScratchTarget(_ mutation: Mutation, isScratch: (String) -> Bool) -> Bool {
        mutation.traversesParent == false
            && temporaryRoots.contains(where: { mutation.path.hasPrefix($0) })
            && isScratch(mutation.path)
    }

    private static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "").folding(options: .caseInsensitive, locale: nil)
    }

    private static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

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

    // MARK: Inline programs

    /// What a program's code must hold to count as a write: a redirect, a
    /// file API, a write mode, or a way to run a shell.
    private static let writeHints = [
        ">", "system", "write", "append", "unlink", "remove", "delete", "rename", "rmtree", "rmdir", "rmsync",
        "rm(", "chmod", "truncate", "spawn", "exec", "eval", "popen", "subprocess", "shutil", "copy", "move",
        "symlink", "link(", "| \"", "|\"", "|&", "`", "'w'", "\"w\"", "'wb'", "\"wb\"", "'a'", "\"a\"", "'ab'",
        "\"ab\"", "'x'", "\"x\"", "'w+'", "'r+'", "\"r+\"", "'a+'", "\"a+\"", "\"w+\"", "'at'", "\"at\"", "'wt'",
        "\"wt\"", "'xt'", "\"xt\"", "mode=", "$^i", "+<", "+>", "inplace", "sysopen", "seek", "fopen", "file.new",
        "file_put_contents", "io.open", "os.open",
    ]

    /// Controls whose name in a program's own code makes it a write: rv
    /// cannot tell a read from a write in another language (`open(…,
    /// "at")`, perl `+<`, ruby `File.new(…, "a+")`), so it fails closed.
    private static let codeMentions = [
        allowMarker, ".rv-secrets-ignore", "secretsscan", "hookspath", ".git/config", ".git/hooks", "gitconfig",
        "git/config", "pre-commit",
    ]

    /// `python3 -c`, `perl -pi -e`, `node -e`, `awk '…'`: a program rv does
    /// not read as shell. It counts when its code names a scan control, or
    /// an operand does and the program edits in place or its code writes;
    /// `awk '/url/' .git/config` and `perl -ne 'print if /x/' .git/config`
    /// only read.
    private static func inlineProgramWritesControl(_ launched: LaunchedCommand) -> Bool {
        guard let head = launched.guardArgv.first else { return false }
        let name = commandName(head)
        let family = name.hasPrefix("python") ? "python" : name
        guard interpreters.contains(family) || interpreters.contains(name) else { return false }
        let words = launched.guardArgv.dropFirst().map(unescapeBackslashPairs)
        guard words.contains(where: { word in inlineMentions.contains { plainText(word).contains($0) } }) else {
            return false
        }
        if editsInPlace(name, words) { return true }
        return programCode(name, words).contains { code in
            let folded = plainText(code)
            if codeMentions.contains(where: { folded.contains($0) }) { return true }
            // Quotes carry the file modes (`'at'`), so read the code as typed too.
            let typed = code.lowercased()
            return writeHints.contains { folded.contains($0) || typed.contains($0) }
        }
    }

    /// `perl -i`/`-pi.bak`, `ruby -i`, `gawk -i inplace`.
    private static func editsInPlace(_ name: String, _ words: [String]) -> Bool {
        if awks.contains(name) {
            return zip(words, words.dropFirst()).contains { $0 == "-i" && $1 == "inplace" }
                || words.contains { $0 == "-iinplace" || $0 == "--include=inplace" }
        }
        guard name == "perl" || name == "ruby" else { return false }
        return words.contains { word in
            guard word.hasPrefix("-"), word.hasPrefix("--") == false else { return false }
            // Letters before an `e` (whose value may follow attached).
            return word.dropFirst().prefix { $0 != "e" }.contains("i")
        }
    }

    /// The words that are program text: the value of `-c`/`-e`/`--eval`
    /// (alone or ending a cluster), awk's first operand, and any word that
    /// reads as code (spaces, `;`, parentheses).
    private static func programCode(_ name: String, _ words: [String]) -> [String] {
        var code: [String] = []
        var index = 0
        var awkProgramSeen = false
        while index < words.count {
            let word = words[index]
            index += 1
            if word.contains(where: { " ;(){}\n".contains($0) }) {
                code.append(word)
                if word.hasPrefix("-") == false { awkProgramSeen = true }
                continue
            }
            if word.hasPrefix("-") {
                let folded = word.lowercased()
                let takesCode = ["--eval", "--print", "--command", "-command", "--source"].contains(folded)
                    || (word.hasPrefix("--") == false && ["c", "e", "E", "r"].contains(word.last.map(String.init) ?? ""))
                if takesCode, index < words.count {
                    code.append(words[index])
                    index += 1
                } else if awks.contains(name), ["-F", "-v", "-f", "-i"].contains(word), index < words.count {
                    // awk's valued options: `-f FILE` is a script rv cannot read.
                    index += 1
                }
                continue
            }
            if awks.contains(name), awkProgramSeen == false {
                code.append(word)
                awkProgramSeen = true
            }
        }
        return code
    }

    // MARK: Paths

    /// One path a command writes. `removesBelow`: a delete or a move source,
    /// which takes everything under a directory with it.
    struct Mutation {
        let path: String
        let removesBelow: Bool
        /// The word as typed has a `..` component.
        var traversesParent = false

        func reaches(_ hook: String) -> Bool {
            path == hook || (removesBelow && (path == "/" || hook.hasPrefix(path + "/")))
        }
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
                    return targets.map { mutation($0, removesBelow: true) }
                case .move(let sources, let destination):
                    return sources.map { mutation($0, removesBelow: true) }
                        + [mutation(destination, removesBelow: false)]
                case .overwrite(let targets), .chmod(let targets, _, _), .create(let targets):
                    return targets.map { mutation($0, removesBelow: false) }
                }
            }
    }

    private static func mutation(_ target: FilesystemTarget, removesBelow: Bool) -> Mutation {
        Mutation(
            path: target.canonical, removesBelow: removesBelow,
            traversesParent: target.apparent.split(separator: "/").contains("..")
        )
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
}
