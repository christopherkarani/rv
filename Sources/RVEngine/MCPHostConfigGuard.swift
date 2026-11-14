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
/// - Unmodeled commands: a program rv does not model (`python3`, `node`,
///   `perl -i`, `jq … | sponge`, an editor, a script runner) that names a
///   guarded file; any name of one fed to `xargs`, a script run by a shell,
///   or hidden from argv (an assignment, a here-document) beside such a
///   program; a dynamic or truncated command beside any name of one; a
///   copy-style verb naming one; and host CLIs that edit MCP servers
///   (`claude mcp add`, `codex mcp add`, `claude plugin install`, `code
///   --add-mcp`, ...). Known readers (`cat`, `jq`, `grep`, `ls`, ...) and
///   read-only `git` subcommands stay allowed.
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
/// filesystem parser does not model. Fails closed: an unknown program that
/// names a guarded file counts, even when it only reads it. The one copy
/// that does not is a plain `cp` that provably only reads the name
/// (`plainCopyOnlyReads`).
func mcpHostConfigUnmodeledWrite(
    _ raw: String, guard guarded: MCPHostConfigGuard, context: FilesystemAnalysisContext
) -> Bool {
    let launched = launchedCommandHeads(raw)
    if launched.contains(where: isHostMCPMutation) { return true }
    let changesDirectory = launched.contains { ["cd", "pushd", "popd"].contains(commandName($0.head)) }
    let argvMentions = launched.reduce(0) { total, command in
        total + command.argv.dropFirst().reduce(0) { $0 + mentionCount($1) }
    }
    let rawMentions = mentionCount(raw)
    guard rawMentions > 0 || argvMentions > 0 else { return false }
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
            if named, changesDirectory || plainCopyOnlyReads(command, guard: guarded, context: context) == false {
                return true
            }
        case .unknown:
            if named { return true }
            unknown = true
        }
    }
    // A name the launched argv does not carry (an assignment, a
    // here-document) may reach an unknown program.
    return unknown && rawMentions > argvMentions
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

private enum MCPCommandClass {
    case reader
    case modeled
    case copy
    case consumer
    case unknown
}

private func classify(_ command: LaunchedCommand) -> MCPCommandClass {
    let name = commandName(command.head)
    let operands = command.guardArgv.dropFirst().map(foldedWord)
    if name == "git" { return gitClass(operands) }
    if name == "find" {
        let acting = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]
        return operands.contains(where: acting.contains) ? .unknown : .reader
    }
    if name == "rg", operands.contains(where: { $0 == "--pre" || $0.hasPrefix("--pre=") }) { return .unknown }
    if readerPrograms.contains(name) { return .reader }
    if modeledPrograms.contains(name) { return .modeled }
    if copyPrograms.contains(name) { return .copy }
    if consumerPrograms.contains(name) { return .consumer }
    return .unknown
}

private func gitClass(_ operands: [String]) -> MCPCommandClass {
    let readOnly: Set<String> = [
        "status", "diff", "log", "show", "blame", "grep", "ls-files", "rev-parse", "add", "commit",
        "check-ignore", "cat-file", "shortlog",
    ]
    guard let sub = operands.first(where: { $0.hasPrefix("-") == false }) else { return .reader }
    return readOnly.contains(sub) ? .reader : .unknown
}

/// Programs that only read their operands (redirects are layer A's).
private let readerPrograms: Set<String> = [
    "cat", "less", "more", "head", "tail", "bat", "jq", "gojq", "grep", "egrep", "fgrep", "rg", "ag", "ack",
    "wc", "stat", "ls", "file", "diff", "cmp", "sha1sum", "sha256sum", "sha512sum", "shasum", "md5sum", "md5",
    "hexdump", "od", "strings", "test", "[", "realpath", "readlink", "dirname", "basename", "echo", "printf",
    "true", "false", ":", "eval", "rv", "rv-cli",
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

/// `cp SRC DEST` with only `-f -i -n -p -v`, static operands, a working
/// directory and a probed, certain `DEST`: the source is then only read,
/// and the copy lands at `DEST` or, when `DEST` exists (it may be a
/// directory), at `DEST/basename(SRC)`. Neither may be a guarded file and
/// `DEST` may not hold one. Anything else (recursion, `-t`, `--parents`,
/// links, several sources, globs, an unprobed `DEST`) keeps the copy unmodeled.
private func plainCopyOnlyReads(
    _ command: LaunchedCommand, guard guarded: MCPHostConfigGuard, context: FilesystemAnalysisContext
) -> Bool {
    guard commandName(command.head) == "cp", context.workingDirectory != nil else { return false }
    var operands: [String] = []
    for word in command.guardArgv.dropFirst() {
        let plain = unescapeBackslashPairs(word)
        if plain.hasPrefix("-") {
            guard plain.count > 1, plain.hasPrefix("--") == false,
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

/// Host CLIs that add, remove or install MCP servers or plugins.
private func isHostMCPMutation(_ command: LaunchedCommand) -> Bool {
    let name = commandName(command.head)
    let operands = command.guardArgv.dropFirst().map(foldedWord)
    if ["code", "code-insiders", "cursor", "windsurf"].contains(name) {
        return operands.contains { $0 == "--add-mcp" || $0.hasPrefix("--add-mcp=") }
    }
    let readOnly: [String: Set<String>] = [
        "claude": ["list", "get", "serve", "help", "--help", "-h"],
        "codex": ["list", "get", "help", "--help", "-h"],
        "gemini": ["list", "help", "--help", "-h"],
        "opencode": ["list", "ls", "help", "--help", "-h"],
    ]
    guard let allowed = readOnly[name] else { return false }
    let words = operands.filter { $0.hasPrefix("-") == false || $0 == "--help" || $0 == "-h" }
    let groups: Set<String> = name == "claude" ? ["mcp", "plugin", "plugins"] : ["mcp"]
    guard let index = words.firstIndex(where: groups.contains) else { return false }
    let group = words[index]
    guard let sub = words.dropFirst(index + 1).first else { return false }
    if group == "mcp" { return allowed.contains(sub) == false }
    if sub == "marketplace" {
        // `claude plugin marketplace list`; a bare group prints its help.
        guard let action = words.dropFirst(index + 2).first else { return false }
        return claudeReadOnlyPluginWords.subtracting(["validate"]).contains(action) == false
    }
    return claudeReadOnlyPluginWords.contains(sub) == false
}

/// `claude plugin` subcommands that only print.
private let claudeReadOnlyPluginWords: Set<String> = ["list", "help", "validate", "--help", "-h"]
