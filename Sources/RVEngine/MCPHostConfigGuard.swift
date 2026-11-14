import RVDomain

/// Keeps an agent from adding ungoverned MCP servers by rewriting a host's
/// MCP config (`MCPHostConfigPaths`) while rv's MCP gateway is in use. The
/// service turns it on by attaching `MCPHostConfigGuard` to the probed
/// filesystem context; without it (or unprobed) nothing here runs.
///
/// Two layers, both only tightening an allow:
/// - Modeled writes: a parsed filesystem mutation (redirect, `tee`, `sed -i`,
///   `cp`, `mv`, `ln`, `install`, `dd`, `curl -o`, ...) whose target, as
///   written or resolved, is a guarded file, a resolved alias of one, or —
///   for a move or overwrite — a directory that holds one.
/// - Unmodeled commands (`mcpHostConfigUnmodeledWrite`): host CLIs that edit
///   MCP servers, behind any launcher; copy verbs with an option word after
///   an operand (BSD `cp` writes to the last word); and, once any guarded
///   name appears, any program rv does not model, any consumer (`xargs`, a
///   shell), any command run with an environment assignment, git with a
///   config override, and any copy verb naming one. Known readers (`cat`,
///   `jq`, `grep`, `ls`, ...) and read-only `git` subcommands stay allowed.
///
/// The deny is `core.mcp`, not pinned: the owner may approve one through
/// allow-once.
func mcpHostConfigDeny(pack: EvaluationResult, analysis: SemanticAnalysis) -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(Deny(ruleID: MCPHostConfigPaths.ruleID, reason: MCPHostConfigPaths.reason), matched: nil),
        matchingView: pack.matchingView,
        analysis: analysis
    )
}

/// `world` with the guard attached while rv's MCP gateway is in use (`nil`:
/// not in use, `world` unchanged). The guard never drops with the probe: a
/// world that was not probed becomes a probed one with no working directory
/// and no path facts, where every modeled write still counts and any
/// guarded name asks (`mcpHostConfigUnmodeledWrite`). The live probe always
/// answers `.probed`, so that branch only fails closed should it change.
public func attachingMCPHostConfigGuard(
    _ guarded: MCPHostConfigGuard?, to world: FilesystemAnalysisWorld, homeDirectory: HomePath?
) -> FilesystemAnalysisWorld {
    guard let guarded else { return world }
    switch world {
    case .probed(var context):
        context.mcpHostConfigGuard = guarded
        return .probed(context)
    case .unprobed:
        return .probed(FilesystemAnalysisContext(homeDirectory: homeDirectory, mcpHostConfigGuard: guarded))
    }
}

/// The guard when the world carries one.
func mcpHostConfigGuard(_ world: FilesystemAnalysisWorld) -> (MCPHostConfigGuard, home: String)? {
    guard case .probed(let context) = world, let guarded = context.mcpHostConfigGuard else { return nil }
    return (guarded, context.homeDirectory?.rawValue ?? "")
}

// MARK: - Modeled writes

/// Whether a parsed mutation lands on a host MCP config.
func landsOnMCPHostConfig(_ action: FilesystemAction, guard guarded: MCPHostConfigGuard, home: String) -> Bool {
    if case .read = action { return false }
    func hits(_ target: FilesystemTarget) -> Bool {
        MCPHostConfigPaths.isGuarded(target.apparent, home: home)
            || isGuardedOrAlias(target.canonical, guard: guarded, home: home)
    }
    func lands(in target: FilesystemTarget) -> Bool {
        [target.apparent, target.canonical].contains { MCPHostConfigPaths.isGuardedContainer($0, home: home) }
    }
    if action.targets.contains(where: hits) { return true }
    switch action {
    case .move(_, let destination):
        return lands(in: destination)
    case .overwrite(let targets):
        return targets.contains(where: lands(in:))
    case .delete, .chmod, .create, .read:
        return false
    }
}

/// A guarded file, or at or under a resolved alias of one.
private func isGuardedOrAlias(_ path: String, guard guarded: MCPHostConfigGuard, home: String) -> Bool {
    if MCPHostConfigPaths.isGuarded(path, home: home) { return true }
    let folded = foldedPath(path)
    return guarded.resolvedAliases.map(foldedPath).contains { folded == $0 || folded.hasPrefix($0 + "/") }
}

private func foldedPath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).map { foldedPathComponent(String($0)) }
        .joined(separator: "/")
}

// MARK: - Unmodeled commands

/// Whether `raw` may write a host MCP config through something the
/// filesystem parser does not model. Fails closed: an unknown program
/// anywhere in a command that names a guarded file counts, even when it
/// only reads it or the name reaches it on stdin (`echo .mcp.json |
/// python3 x.py`). The one copy that does not is a plain `cp` that provably
/// only reads the name (`plainCopyOnlyReads`).
func mcpHostConfigUnmodeledWrite(
    _ raw: String, guard guarded: MCPHostConfigGuard, context: FilesystemAnalysisContext
) -> Bool {
    let launched = launchedCommandHeads(raw)
    if launched.contains(where: isHostMCPMutation) { return true }
    if launched.contains(where: hasOptionAfterOperand) { return true }
    let argvMentions = launched.reduce(0) { total, command in
        total + (command.argv.dropFirst() + command.assignments).reduce(0) { $0 + mentionCount($1) }
    }
    guard mentionCount(raw) > 0 || argvMentions > 0 else { return false }
    // No working directory (or no probe, `attachingMCPHostConfigGuard`):
    // a relative name cannot be placed, so no name is known to be read only.
    guard context.workingDirectory != nil else { return true }
    let copyIsPlain = launched.contains(where: mayShadowOrMoveCopy) == false && mayDefineCommands(raw) == false
    var unknown = false
    for command in launched {
        if command.truncated || command.headIsDynamic { return true }
        let named = command.argv.dropFirst().contains(where: MCPHostConfigPaths.mentions)
        switch classify(command) {
        case .reader, .modeled:
            continue
        case .consumer:
            return true
        case .copy:
            if named, copyIsPlain == false || plainCopyOnlyReads(command, guard: guarded, context: context) == false {
                return true
            }
        case .unknown:
            unknown = true
        }
    }
    return unknown
}

private func mentionCount(_ text: String) -> Int {
    let folded = foldedPathComponent(text)
    // Longest tokens first, each hit consumed, so `.mcp.json` counts once.
    var remaining = folded
    var count = 0
    for token in MCPHostConfigPaths.mentionTokens.sorted(by: { $0.count > $1.count }) {
        let parts = remaining.components(separatedBy: token)
        count += parts.count - 1
        remaining = parts.joined(separator: "\u{0}")
    }
    return count
}

/// BSD getopt (macOS `cp`, `mv`, `ln`, `install`) stops at the first
/// operand: a later `-x` word is an operand, and the last word the real
/// destination, which the GNU-style writer parse does not see. A `--`
/// after an operand is itself an operand there (`cp a -- b` also copies a
/// file named `--`), and any `-x` word after a `--` is one in both
/// grammars: neither is modelled here, so both count.
private func hasOptionAfterOperand(_ command: LaunchedCommand) -> Bool {
    let name = commandName(command.head)
    guard ["cp", "mv", "ln", "install"].contains(name) else { return false }
    var sawOperand = false
    var optionsEnded = false
    var skipValue = false
    for word in command.guardArgv.dropFirst().map(unescapeBackslashPairs) {
        if skipValue {
            skipValue = false
            continue
        }
        let dashWord = word.hasPrefix("-") && word != "-"
        if optionsEnded {
            if dashWord { return true }
            continue
        }
        if word == "--" {
            if sawOperand { return true }
            optionsEnded = true
            continue
        }
        if dashWord {
            if sawOperand { return true }
            skipValue = name == "install" && ["-m", "-o", "-g"].contains(word)
            continue
        }
        sawOperand = true
    }
    return false
}

/// A directory change, or a definition that may stand in for `cp`.
private func mayShadowOrMoveCopy(_ command: LaunchedCommand) -> Bool {
    ["cd", "pushd", "popd", "alias", "function", "hash", "enable"].contains(commandName(command.head))
}

/// A shell function definition or a `PATH` change anywhere in `raw`.
private func mayDefineCommands(_ raw: String) -> Bool {
    raw.contains("()") || raw.contains("PATH=") || raw.contains("PATH+=")
}

private enum MCPCommandClass {
    case reader
    case modeled
    case copy
    case consumer
    case unknown
}

private func classify(_ command: LaunchedCommand) -> MCPCommandClass {
    // `LESSOPEN=… less`, `GIT_PAGER=… git log`, `PATH=… cp`: the
    // environment may make any program run code.
    if command.assignments.isEmpty == false { return .unknown }
    let name = commandName(command.head)
    let operands = command.guardArgv.dropFirst().map(foldedWord)
    if name == "git" { return gitClass(command) }
    if name == "find" {
        let acting = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]
        return operands.contains(where: acting.contains) ? .unknown : .reader
    }
    if name == "rg", operands.contains(where: { $0 == "--pre" || $0.hasPrefix("--pre=") }) { return .unknown }
    if name == "less" || name == "more", operands.contains(where: lessRunsCode) { return .unknown }
    if ["bat", "ack", "ag"].contains(name),
       operands.contains(where: { abbreviatesLong($0, of: ["--pager", "--ackrc"]) })
    {
        return .unknown
    }
    if readerPrograms.contains(name) { return .reader }
    if modeledPrograms.contains(name) { return .modeled }
    if copyPrograms.contains(name) { return .copy }
    if consumerPrograms.contains(name) { return .consumer }
    return .unknown
}

/// Read-only subcommands, with no global option that can run a program
/// (`-c core.pager=…`, `--config-env=…`, `--exec-path`). `commit` runs
/// an editor and hooks: read-only only with a message given on the command
/// line, no `--edit`, and no guarded name of its own.
private func gitClass(_ command: LaunchedCommand) -> MCPCommandClass {
    let words = command.guardArgv.dropFirst().map(unescapeBackslashPairs)
    guard let index = words.firstIndex(where: { $0.hasPrefix("-") == false }) else { return .reader }
    let overrides = words[..<index].contains {
        $0.hasPrefix("-c") || $0.hasPrefix("--config-env") || $0.hasPrefix("--exec-path")
    }
    if overrides { return .unknown }
    let sub = foldedWord(words[index])
    let rest = words[(index + 1)...]
    // `git grep -O<cmd>` runs a program on the matches; `--output=<file>`
    // (diff, log, show) writes one.
    let runsOrWrites = rest.contains { word in
        (word.hasPrefix("-") && word.hasPrefix("--") == false && word.contains("O"))
            || abbreviatesLong(word, of: ["--open-files-in-pager", "--output"])
    }
    if runsOrWrites { return .unknown }
    if sub == "commit" {
        let message = rest.contains {
            ["-m", "-am", "-F", "--message", "--file"].contains($0)
                || $0.hasPrefix("--message=") || $0.hasPrefix("--file=")
        }
        let edits = rest.contains { $0 == "-e" || $0 == "--edit" }
        let named = rest.contains(where: MCPHostConfigPaths.mentions)
        return message && edits == false && named == false ? .reader : .unknown
    }
    return gitReadOnly.contains(sub) ? .reader : .unknown
}

/// `less`/`more` (macOS `more` is `less`) words that run a program or
/// write a file: `+cmd` (`+!cmd` runs a shell command at start), a lesskey
/// file (`-k`, `--lesskey-*`; its `#env` section can set `LESSOPEN`), and a
/// log file (`-o`, `-O`, `--log-file`). Words come case-folded; only the
/// motions `+G` and `+F` are known not to.
private func lessRunsCode(_ word: String) -> Bool {
    if word.hasPrefix("+") { return word != "+g" && word != "+f" }
    if word.hasPrefix("--") {
        return abbreviatesLong(word, of: ["--lesskey-file", "--lesskey-src", "--lesskey-content", "--log-file"])
    }
    return word.hasPrefix("-") && word.dropFirst().contains { $0 == "k" || $0 == "o" }
}

/// Whether `word` (`--name` or `--name=value`) may name one of `longs`:
/// getopt_long, git and Getopt::Long take any unambiguous prefix.
private func abbreviatesLong(_ word: String, of longs: [String]) -> Bool {
    guard word.hasPrefix("--") else { return false }
    let name = String(word.prefix { $0 != "=" })
    guard name.count > 2 else { return false }
    return longs.contains { $0.hasPrefix(name) }
}

private let gitReadOnly: Set<String> = [
    "status", "diff", "log", "show", "blame", "grep", "ls-files", "rev-parse", "add", "check-ignore", "cat-file",
    "shortlog",
]

/// Programs that only read their operands (redirects are layer A's).
private let readerPrograms: Set<String> = [
    "cat", "less", "more", "head", "tail", "bat", "jq", "gojq", "grep", "egrep", "fgrep", "rg", "ag", "ack",
    "wc", "stat", "ls", "file", "diff", "cmp", "sha1sum", "sha256sum", "sha512sum", "shasum", "md5sum", "md5",
    "hexdump", "od", "strings", "test", "[", "realpath", "readlink", "dirname", "basename", "echo", "printf",
    "true", "false", ":", "eval", "rv", "rv-cli", "cd", "pushd", "popd",
]

/// Writers the filesystem parser models, so layer A sees their targets.
private let modeledPrograms: Set<String> = [
    "rm", "unlink", "rmdir", "tee", "curl", "wget", "dd", "iconv", "split", "sed", "gsed", "sqlite3",
    "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz", "zip", "chmod", "truncate", "shred", "touch", "mkdir",
]

/// Verbs that carry a source's content to a destination the parser may
/// only see as a directory (`cp x/.mcp.json ./`): any name of a guarded
/// file in their operands counts.
private let copyPrograms: Set<String> = [
    "cp", "mv", "install", "ln", "link", "rsync", "tar", "bsdtar", "unzip", "ditto", "rename", "cpio", "scp",
    "patch",
]

/// `cp SRC DEST` with only `-f -i -n -p -v` before the operands, static
/// operands, a working directory and a probed, certain `DEST`: the source
/// is then only read, and the copy lands at `DEST` or, when `DEST` exists
/// (it may be a directory), at `DEST/basename(SRC)`. Neither may be a
/// guarded file and `DEST` may not hold one. Anything else (recursion,
/// `-t`, `--parents`, `--`, links, several sources, globs, an option after
/// an operand, an unprobed `DEST`) keeps the copy unmodeled.
private func plainCopyOnlyReads(
    _ command: LaunchedCommand, guard guarded: MCPHostConfigGuard, context: FilesystemAnalysisContext
) -> Bool {
    guard commandName(command.head) == "cp", context.workingDirectory != nil else { return false }
    var operands: [String] = []
    for word in command.guardArgv.dropFirst() {
        let plain = unescapeBackslashPairs(word)
        if plain.hasPrefix("-") {
            guard operands.isEmpty, plain.count > 1, plain.hasPrefix("--") == false,
                  plain.dropFirst().allSatisfy(plainCopyFlags.contains)
            else { return false }
            continue
        }
        guard plain.isEmpty == false, plain.contains(where: opaqueOperandCharacters.contains) == false
        else { return false }
        operands.append(plain)
    }
    guard operands.count == 2, let source = operands.first, let destination = operands.last,
          let fact = context.fact(for: destination), fact.resolution != .uncertain
    else { return false }
    let home = context.homeDirectory?.rawValue ?? ""
    if MCPHostConfigPaths.isGuarded(destination, home: home)
        || isGuardedOrAlias(fact.canonical, guard: guarded, home: home)
        || [destination, fact.canonical].contains(where: { MCPHostConfigPaths.isGuardedContainer($0, home: home) })
    {
        return false
    }
    // `.lexical` from the probe: a component is missing, so `cp` creates
    // `DEST` itself. `.resolved`: `DEST` exists and may be a directory.
    guard fact.resolution == .resolved else { return true }
    guard let name = source.split(separator: "/").last else { return false }
    return isGuardedOrAlias(fact.canonical + "/" + name, guard: guarded, home: home) == false
}

private let plainCopyFlags: Set<Character> = ["f", "i", "n", "p", "v"]

/// Expansions and globs whose operands rv cannot name.
private let opaqueOperandCharacters: Set<Character> = ["$", "`", "*", "?", "[", "{", "\\"]

/// Programs that run commands or scripts rv cannot see.
private let consumerPrograms: Set<String> = [
    "xargs", "parallel", "sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh", "source", ".",
]
