import Foundation
import RVDomain

/// Whether `command` may run a host CLI that adds, removes or installs MCP
/// servers or plugins. The host may sit anywhere in argv, behind a launcher
/// rv does not strip (`npx @anthropic-ai/claude-code mcp add`, `bunx`,
/// `pnpm dlx`, `stdbuf`, `script`, `node …/cli.js`): any word naming a host
/// CLI or its package (`packageNames`), followed anywhere by its
/// `mcp`/`plugin`/`config` group, counts unless the words after it are
/// exactly a read-only form (`isReadOnlyHostForm`). So does an agent CLI
/// run as the program, or by a runner (`npx`, `node`, `stdbuf`, ...) that
/// may stand anywhere before it (`volta run npx …`), whose words rv cannot
/// see: one given an expansion that may stand for its subcommand (`claude
/// "$@"` in a function, `claude $SUB add`) or fed more words by
/// `xargs`/`parallel`; and a dynamic program given an agent CLI's group word
/// (`$C mcp add`), and a runner given the whole command line as one word
/// (`watch 'claude mcp add x'`, read through `reads`). Editors count with
/// `--add-mcp` anywhere after them. Installers that write host configs
/// themselves count: `fastmcp install`; `mcp install` as two adjacent
/// words anywhere (`op run -- mcp install s`, `chronic -q mcp install s`),
/// whatever the server, unless `mcp` is the value of a build tool's
/// directory option (`make -C mcp install`) or the command does not run its
/// operands (`isNonExecutor`); `mcp install` under a Python or plain runner
/// (`uv run mcp install`) or given a `.py` server; the `@smithery/cli`,
/// `install-mcp` and `add-mcp` package specs and programs anywhere, and any
/// spec of them a runner runs. Inside text nothing runs (`reads.inert`),
/// `mcp install` needs a Python runner or a `.py` server.
func isHostMCPMutation(_ command: LaunchedCommand, reads: inout HostTextReads) -> Bool {
    let words = command.guardArgv.map(foldedWord)
    if command.headIsDynamic, words.dropFirst().contains(where: dynamicGroupWords.contains) { return true }
    let head = commandName(command.head)
    let feedsWords = argvFeeders.contains(head)
    // A runner anywhere before a word may run it: `corepack pnpm dlx X`,
    // `mise exec -- npx X`, `chronic uvx mcp install s.py`.
    let firstRunner = words.firstIndex { hostRunners.contains(commandName($0)) }
    let firstPythonRunner = words.firstIndex { pythonRunners.contains(commandName($0)) }
    let runs = { (index: Int) in index == 0 || firstRunner.map { $0 < index } == true }
    // A dynamic word rv cannot read, used as the program at the head or after
    // a runner the parser does not strip (`stdbuf -o0 $c mcp add`), with a
    // group word (literal or a brace/glob spelling) after it: treated like a
    // dynamic head, which `headIsDynamic` only catches at index 0.
    for (index, word) in words.enumerated() where runs(index) && wordIsDynamic(word) {
        if words[(index + 1)...].contains(where: namesDynamicGroupWord) { return true }
    }
    // argv holds the head's basename; the head as written is judged too, as
    // a path to a host binary its basename does not name
    // (`~/.local/share/claude/versions/2.0.14`, `…/@openai/codex/bin/codex.js`).
    // zsh runs `=claude` as the `claude` on PATH.
    var judged = Array(words.enumerated())
    let written = foldedWord(command.head)
    if let first = words.first, written != first { judged.append((offset: 0, element: written)) }
    if written.hasPrefix("=") { judged.append((offset: 0, element: String(written.dropFirst()))) }
    let operandsRun = reads.inert == false && isNonExecutor(command) == false
    // A build tool's own directory options, or any of them heading a
    // re-split of operands already judged in their own command (`-C mcp
    // install`, `joinedReadsRun`).
    let options = directoryOptions[head]
        ?? (reads.resplit && command.head.hasPrefix("-") ? anyDirectoryOption : [])
    for (index, word) in judged {
        if isConfigInstallerPackage(word) || configInstallerPrograms.contains(commandName(word)) { return true }
        if runs(index), packageNames(word).contains(where: configInstallerNames.contains) { return true }
        // A runner given a command line as one word (`watch 'claude mcp
        // add x'`, `su -c '…'`, `parallel '…' ::: x`, Linux `script -c`).
        if index > 0, runs(index), carriesHostMCPMutation(word, reads: &reads) { return true }
        let rest = Array(words[(index + 1)...])
        let before = index == 0 ? nil : index == 1 ? command.head : command.guardArgv[index - 1]
        let place = HostWordPlace(
            runs: runs(index), feedsWords: feedsWords,
            pythonRun: (index == 0 && reads.inert == false) || firstPythonRunner.map { $0 < index } == true,
            mayRun: operandsRun && before.map(options.contains) != true)
        if hostCLIs(word).contains(where: { hostWordMutates($0, rest: rest, place: place) }) { return true }
    }
    return false
}

private struct HostWordPlace {
    /// Index 0, or after a runner.
    let runs: Bool
    let feedsWords: Bool
    /// Index 0, or after a Python or plain runner.
    let pythonRun: Bool
    /// The word may be run as a program: its command may run its operands,
    /// the line is not text nothing runs, and it is no directory option's
    /// value.
    let mayRun: Bool
}

/// Per build tool, the options whose next word is a directory, workspace
/// or package filter (`make -C mcp install`, `pnpm --filter mcp install`,
/// `npm --prefix mcp install x`), as written and confirmed in each tool's
/// own help or option table: GNU make `-C`/`--directory` (`-w` is
/// `--print-directory`, a flag); npm `-C` (`--prefix`), `--prefix`, `-w`
/// and `--workspace`; pnpm `-C`/`--dir` and `--filter` (`-w` is
/// `--workspace-root`, a flag); bun `--cwd` and `-F`/`--filter`. Under any
/// other program (`nsenter -w mcp install s`, `yarn --cwd …`) the word
/// after one may run.
private let directoryOptions: [String: Set<String>] = [
    "make": ["-C", "--directory"],
    "gmake": ["-C", "--directory"],
    "npm": ["-C", "--prefix", "-w", "--workspace"],
    "pnpm": ["-C", "--dir", "--filter"],
    "bun": ["--cwd", "-F", "--filter"],
]

private let anyDirectoryOption: Set<String> = directoryOptions.values.reduce(into: []) { $0.formUnion($1) }

/// A command rv knows never runs its operands' text, run by its plain
/// name: `grep`/`egrep`/`fgrep`, `rg` without `--pre`, `echo`/`printf`,
/// `git commit`/`git tag` with no global option, and `gh pr|issue
/// create|comment|edit`. Any other program may be an executor.
func isNonExecutor(_ command: LaunchedCommand) -> Bool {
    let head = foldedWord(command.head)
    guard command.headIsDynamic == false, head.contains("/") == false, commandName(command.head) == head else {
        return false
    }
    let words = command.guardArgv.dropFirst().map(foldedWord)
    switch head {
    case "grep", "egrep", "fgrep", "echo", "printf":
        return true
    case "rg":
        // `--pre` and `--hostname-bin` both name a program rg runs.
        return words.contains(where: { $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") }) == false
    case "git":
        return words.first.map { ["commit", "tag"].contains($0) } == true
    case "gh":
        return words.count >= 2 && ["pr", "issue"].contains(words[0])
            && ["create", "comment", "edit"].contains(words[1])
    default:
        return false
    }
}

private func hostWordMutates(_ host: String, rest: [String], place: HostWordPlace) -> Bool {
    if editorHosts.contains(host) {
        if rest.contains(where: { $0 == "--add-mcp" || $0.hasPrefix("--add-mcp=") }) { return true }
        if host != "cursor" { return false }
    }
    // `--` ends options and leaves the subcommand (`mcp -- install s`). A
    // brace or glob spelling that can produce `install` counts (`mcp
    // {a,install}`, `mcp instal?`).
    let subcommand = rest.first { $0 != "--" }
    let installs = subcommand.map { wordMayBe($0, "install") } == true
    if host == "fastmcp" { return installs }
    if host == "mcp" {
        // `mcp` is a common directory and package name (`make -C mcp
        // install`): a word that may run, the program under a Python
        // runner, or given a Python server file.
        guard installs else { return false }
        return place.mayRun || place.pythonRun || rest.contains(where: namesPythonServer)
    }
    guard let groups = hostGroups[host] else { return false }
    if agentHosts.contains(host), place.runs, place.feedsWords || rest.contains(where: mayStandForWords) {
        return true
    }
    // A later word that is, or that a brace/glob spelling can produce, one of
    // the host's group words (`claude m{c,}p add`, `gemini ext*s install`).
    guard rest.contains(where: { producesGroupWord($0, groups) }) else { return false }
    return isReadOnlyHostForm(host: host, rest) == false
}

/// Every host CLI a word may run: its program name, or a package that
/// ships it in any spec shape (`@anthropic-ai/claude-code@latest`,
/// `…/claude-code/cli.js`, `nixpkgs#claude-code`, `mcp[cli]@1.6`), or
/// Claude Code's native build (`~/.local/share/claude/versions/2.0.14`).
private func hostCLIs(_ word: String) -> [String] {
    var hosts: [String] = []
    let name = commandName(word)
    if hostGroups[name] != nil || editorHosts.contains(name) || pythonInstallers.contains(name) { hosts.append(name) }
    if name == "claude-code" || ("/" + word).contains("/claude/versions/") { hosts.append("claude") }
    for (package, host) in hostPackages where word.contains(package) { hosts.append(host) }
    for package in packageNames(word) {
        if let host = hostPackageNames[package] { hosts.append(host) }
        if pythonInstallers.contains(package) { hosts.append(package) }
    }
    // A brace or glob spelling of a plain host program name (`m{c,}p`,
    // `clau?e`, `cod[e]x`): the filesystem is not consulted, so a wildcard
    // or class is assumed satisfiable.
    if hasExpansionMetacharacters(word) {
        for (spelling, host) in spelledHostNames where wordMayBe(name, spelling) { hosts.append(host) }
    }
    var seen: Set<String> = []
    return hosts.filter { seen.insert($0).inserted }
}

/// A word holding a whole command line that runs a host MCP CLI (`'claude
/// mcp add x'` given to a runner, echoed into a shell, or a here-string).
func carriesHostMCPMutation(_ word: String, reads: inout HostTextReads) -> Bool {
    guard word.contains(where: \.isWhitespace) else { return false }
    return reads.runsHostMCPMutation(word)
}

/// Text no shell parse splits into words, such as inline program code or
/// a quoted string (`os.system("claude mcp add x")`, `X='claude mcp add
/// x'`), cut at every character a program or package name cannot hold: a
/// host CLI or package whose next non-option piece is one of its groups,
/// unless the pieces after it are exactly a read-only form; an installer's
/// package or program; `fastmcp install`; `mcp install` given a `.py`
/// server; an editor given `--add-mcp`. Over-reports on prose that names a
/// host mutation, as a commit message or a grep pattern may. Linear in the
/// pieces, which count against `reads` (past its cap: a mutation) unless
/// no piece holds a stem.
func textNamesHostMCPMutation(_ text: String, reads: inout HostTextReads) -> Bool {
    let pieces = textPieces(text)
    guard pieces.count > 1 else { return false }
    // Sound early exit: every check below that can return true tests a
    // table word (each holds a stem, `hostMCPTableWords`) by equality,
    // prefix or containment against one of: a piece, its `commandName`, a
    // `packageNames` name of it, or a later piece (a group word or
    // `--add-mcp`); `install` and `.py` are only tested once a host
    // matched. A `packageNames` name of a piece with no `%` is a substring
    // of it, or two joined by `/`, which no stem holds; with a `%` the names
    // are tested themselves. Decoding (`$'…'`, backslashes) happens before
    // this text is formed, so the stems are tested on exactly the strings
    // the checks see. So text no piece of which passes cannot match here.
    guard pieces.contains(where: pieceMayNameHostMCP) else { return false }
    guard reads.examine(pieces: pieces.count) else { return true }
    let later = LaterPieces(pieces)
    for (index, piece) in pieces.enumerated() {
        if isConfigInstallerPackage(piece) || configInstallerPrograms.contains(commandName(piece)) { return true }
        if packageNames(piece).contains(where: configInstallerNames.contains) { return true }
        let first = later.subcommand[index].map { pieces[$0] }
        for host in hostCLIs(piece) {
            if editorHosts.contains(host), later.addMCP[index] { return true }
            if host == "fastmcp", first == "install" { return true }
            if host == "mcp", first == "install", later.pythonServer[index] { return true }
            guard let groups = hostGroups[host], let next = later.nextOperand[index], groups.contains(pieces[next])
            else { continue }
            // Every read-only form holds at most three words.
            let restCount = pieces.count - index - 1
            if restCount > 3 || isReadOnlyHostForm(host: host, Array(pieces[(index + 1)...])) == false { return true }
        }
    }
    return false
}

/// For each piece, facts about the pieces after it, built in one pass.
private struct LaterPieces {
    /// Some later piece is `--add-mcp…`.
    var addMCP: [Bool]
    /// Some later piece names a Python server.
    var pythonServer: [Bool]
    /// The index of the first later piece that is not an option.
    var nextOperand: [Int?]
    /// The index of the first later piece that is not `--`.
    var subcommand: [Int?]

    init(_ pieces: [String]) {
        addMCP = Array(repeating: false, count: pieces.count)
        pythonServer = Array(repeating: false, count: pieces.count)
        nextOperand = Array(repeating: nil, count: pieces.count)
        subcommand = Array(repeating: nil, count: pieces.count)
        var seenAddMCP = false
        var seenPythonServer = false
        var operand: Int?
        var word: Int?
        for index in pieces.indices.reversed() {
            addMCP[index] = seenAddMCP
            pythonServer[index] = seenPythonServer
            nextOperand[index] = operand
            subcommand[index] = word
            let piece = pieces[index]
            if piece.hasPrefix("--add-mcp") { seenAddMCP = true }
            if namesPythonServer(piece) { seenPythonServer = true }
            if piece.hasPrefix("-") == false { operand = index }
            if piece != "--" { word = index }
        }
    }
}

/// Case-folded runs of characters a program, package spec or option can
/// hold; a run with no letter or digit (`+`, `.`) is dropped unless it is
/// an option (`--`).
private func textPieces(_ text: String) -> [String] {
    text.folding(options: .caseInsensitive, locale: nil)
        .split(whereSeparator: { ($0.isLetter || $0.isNumber || pieceCharacters.contains($0)) == false })
        .map(String.init)
        .filter { piece in piece.hasPrefix("-") || piece.contains(where: { $0.isLetter || $0.isNumber }) }
}

private let pieceCharacters: Set<Character> = ["_", "@", "/", ".", "-", "%", ":", "#", "~"]

/// Whether a piece, its program name, or (with a `%`) a package name it
/// decodes to holds a `hostMCPStems` stem.
func pieceMayNameHostMCP(_ piece: String) -> Bool {
    let holdsStem = { (word: String) in hostMCPStems.contains { word.contains($0) } }
    if holdsStem(piece) || holdsStem(commandName(piece)) { return true }
    return piece.contains("%") && packageNames(piece).contains(where: holdsStem)
}

/// Every word the tables in this file match on, for the `hostMCPStems` check.
func hostMCPTableWords() -> [String] {
    var words = Array(hostGroups.keys) + hostGroups.values.flatMap { $0 } + Array(dynamicGroupWords)
    words += Array(editorHosts) + Array(pythonInstallers) + hostPackages.map(\.0) + Array(hostPackageNames.keys)
    words += configInstallerPackages + Array(configInstallerPrograms) + Array(configInstallerNames)
    return words + ["claude-code", "/claude/versions/"]
}

/// An expansion rv cannot read that may become the subcommand or several
/// words (`$SUB`, `"$@"`, `$(printf 'mcp add')`, `--$X`). A quoted word
/// with a literal space outside its substitutions (`"fix $FILE"`) stays one
/// word that is no group name, unless it carries `@` (`"x $@"` splits).
private func mayStandForWords(_ word: String) -> Bool {
    guard word.contains("$") || word.contains("`") else { return false }
    let literal = collapsingSubstitutions(word)
    return literal.contains(where: \.isWhitespace) == false || word.contains("@")
}

/// A config installer's package spec anywhere (`@smithery/cli`,
/// `install-mcp@1.2`, `…/node_modules/install-mcp/…`): a word that is the
/// spec itself, not one that contains it (`add-mcp-support`).
private func isConfigInstallerPackage(_ word: String) -> Bool {
    configInstallerPackages.contains { package in
        word == package || word.hasPrefix(package + "@") || word.contains("node_modules/" + package + "/")
    }
}

/// `server.py`, `server.py:app`, `pkg/server.py`.
private func namesPythonServer(_ word: String) -> Bool {
    word.hasPrefix("-") == false && (word.hasSuffix(".py") || word.contains(".py:"))
}

private let editorHosts: Set<String> = ["code", "code-insiders", "cursor", "windsurf"]

/// Programs that append words of their own to the command they run.
private let argvFeeders: Set<String> = ["xargs", "parallel"]

private let agentHosts: Set<String> = ["claude", "codex", "gemini", "opencode", "cursor-agent"]

/// Programs that run a later word of their argv as a program or package.
/// Under any other program a host name is data (`grep claude "$f"`).
private let hostRunners: Set<String> = argvFeeders.union([
    "npx", "bunx", "pnpx", "pnpm", "yarn", "npm", "bun", "node", "deno", "stdbuf", "caffeinate", "arch",
    "script", "unbuffer", "find", "watch", "chrt", "ionice", "taskset", "setsid", "flock", "su", "runuser",
    "tmux", "screen",
])

/// The Python MCP SDK's and FastMCP's CLIs write Claude Desktop and other
/// host configs: `mcp install server.py`, `fastmcp install cursor`.
private let pythonInstallers: Set<String> = ["mcp", "fastmcp"]

/// Runners that start a Python program by name, plus the plain launchers
/// (not the JavaScript package managers: `pnpm --filter mcp install`).
private let pythonRunners: Set<String> = argvFeeders.union([
    "uv", "uvx", "pipx", "poetry", "pdm", "hatch", "rye", "python", "python3", "stdbuf", "caffeinate", "arch",
    "script", "unbuffer", "watch", "chrt", "ionice", "taskset", "setsid", "flock", "su", "runuser",
])

private let hostGroups: [String: Set<String>] = [
    // `config` writes the host's settings (`claude config set|add|remove`):
    // only `config`, `config list` and `config get NAME` stay read-only.
    "claude": ["mcp", "plugin", "plugins", "config"],
    "codex": ["mcp", "mcp-server", "config"],
    "gemini": ["mcp", "extensions", "config"],
    "opencode": ["mcp", "config"],
    "cursor": ["mcp"],
    "cursor-agent": ["mcp"],
]

/// Group words a dynamic program (`$C`) may be given.
private let dynamicGroupWords: Set<String> = hostGroups.values.reduce(into: ["--add-mcp"]) { $0.formUnion($1) }

private let hostPackages: [(String, String)] = [
    ("@anthropic-ai/claude-code", "claude"),
    ("@openai/codex", "codex"),
    ("@google/gemini-cli", "gemini"),
    ("opencode-ai", "opencode"),
]

/// `packageNames` of an agent CLI's package in any spec shape (`github:
/// google-gemini/gemini-cli`, `…/anthropic-ai-claude-code-2.0.14.tgz`).
private let hostPackageNames: [String: String] = [
    "@anthropic-ai/claude-code": "claude", "anthropic-ai-claude-code": "claude", "claude-code": "claude",
    "@openai/codex": "codex", "openai-codex": "codex", "codex": "codex",
    "@google/gemini-cli": "gemini", "google-gemini-cli": "gemini", "gemini-cli": "gemini",
    "opencode-ai": "opencode",
]

/// Packages and programs whose job is writing a server into host configs.
private let configInstallerPackages: [String] = ["@smithery/cli", "install-mcp", "add-mcp"]
private let configInstallerPrograms: Set<String> = ["smithery", "install-mcp", "add-mcp"]
/// `packageNames` of an installer in any spec shape, for a word a runner runs.
private let configInstallerNames: Set<String> = [
    "@smithery/cli", "smithery-cli", "smithery-ai/cli", "install-mcp", "add-mcp",
]

/// The exact argv tails (after the host word) that only print. `NAME`
/// stands for one non-option word. `claude mcp serve` and `codex
/// mcp-server` are not here: they run the host's own tools (shell, file
/// edits) for whatever client writes to their stdin, outside rv's hooks.
private func isReadOnlyHostForm(host: String, _ rest: [String]) -> Bool {
    let forms: [[String]]
    switch host {
    case "claude":
        forms = [
            ["mcp"], ["mcp", "list"], ["mcp", "get", "NAME"],
            ["plugin"], ["plugin", "list"], ["plugin", "validate", "NAME"],
            ["plugins"], ["plugins", "list"],
            ["plugin", "marketplace"], ["plugin", "marketplace", "list"],
        ]
    case "codex":
        forms = [["mcp"], ["mcp", "list"], ["mcp", "get", "NAME"]]
    case "gemini":
        forms = [["mcp"], ["mcp", "list"], ["extensions"], ["extensions", "list"]]
    case "opencode":
        forms = [["mcp"], ["mcp", "list"], ["mcp", "ls"]]
    default:
        forms = [["mcp"], ["mcp", "list"]]
    }
    let configForms: [[String]] = hostGroups[host]?.contains("config") == true
        ? [["config"], ["config", "list"], ["config", "get", "NAME"]]
        : []
    // `<group> help`, `<group> --help`, `<group> <sub> --help` only print.
    // A bare `help` elsewhere is an operand (`claude plugin install help`).
    if (2...3).contains(rest.count), hostGroups[host]?.contains(rest[0]) == true,
       rest[1] == "help" || ["--help", "-h"].contains(rest[rest.count - 1])
    {
        return true
    }
    return (forms + configForms).contains { form in
        form.count == rest.count
            && zip(form, rest).allSatisfy { expected, word in
                expected == "NAME" ? word.hasPrefix("-") == false : expected == word
            }
    }
}

// MARK: - Brace, glob and dynamic spellings

/// Whether `word` holds unquoted brace (`{a,b}`, `{1..3}`) or glob (`*`, `?`,
/// `[…]`) metacharacters the shell may expand to another word. The words
/// judged here are `foldedWord` output, so quoting is already gone (a
/// surviving metacharacter was unquoted in the source).
func hasExpansionMetacharacters(_ word: String) -> Bool {
    if word.contains("*") || word.contains("?") || word.contains("[") { return true }
    return word.contains("{") && (word.contains(",") || word.contains(".."))
}

/// Whether `word`, as the shell expands it, can equal `literal` (both
/// `foldedWord` output). A brace or glob spelling that can produce it counts
/// (`m{c,}p`, `m?p`, `m[c]p` each produce `mcp`); an expansion past the brace
/// bound can produce anything. The filesystem is not consulted: a wildcard or
/// class is assumed satisfiable.
func wordMayBe(_ word: String, _ literal: String) -> Bool {
    if word == literal { return true }
    guard hasExpansionMetacharacters(word) else { return false }
    // A numeric or alpha range (`{a..z}`) is not enumerated by
    // `braceExpanded`; assume it can produce the literal (fail closed).
    if word.contains("{"), word.contains("..") { return true }
    guard let expansions = braceExpanded(word) else { return true }
    return expansions.contains { globCanMatch($0, literal) }
}

/// Whether `word` holds a value rv cannot resolve to a fixed string: a
/// parameter (`$x`, `${x:-y}`), a command substitution (`$(…)`, backticks) or
/// a process substitution. ANSI-C quoting (`$'…'`), which rv decodes, is not
/// dynamic.
func wordIsDynamic(_ word: String) -> Bool {
    collapsingSubstitutions(word.ansiCDecodedIfMarked).contains("$")
}

/// Whether `word` is, or a brace/glob spelling can produce, a group word a
/// dynamic program may be given (`mcp`, `plugin`, `config`, `--add-mcp`).
private func namesDynamicGroupWord(_ word: String) -> Bool {
    if dynamicGroupWords.contains(word) { return true }
    guard hasExpansionMetacharacters(word) else { return false }
    return dynamicGroupWords.contains { wordMayBe(word, $0) }
}

/// Whether `word` is, or a brace/glob spelling can produce, one of `groups`.
private func producesGroupWord(_ word: String, _ groups: Set<String>) -> Bool {
    if groups.contains(word) { return true }
    guard hasExpansionMetacharacters(word) else { return false }
    return groups.contains { wordMayBe(word, $0) }
}

/// Plain host program names (not package specs) a brace or glob spelling may
/// stand for, each mapped to the host it runs.
private let spelledHostNames: [(String, String)] = {
    var pairs: [(String, String)] = []
    for name in hostGroups.keys { pairs.append((name, name)) }
    for name in editorHosts { pairs.append((name, name)) }
    for name in pythonInstallers { pairs.append((name, name)) }
    pairs.append(("claude-code", "claude"))
    return pairs
}()

/// Whether the shell glob `pattern` can match `text` (only `*`, `?` and `[…]`
/// are special; both are `foldedWord` output). No filesystem: a wildcard or
/// class is assumed satisfiable. Memoised, so bounded by `pattern.count *
/// text.count`.
func globCanMatch(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern)
    let t = Array(text)
    let width = t.count + 1
    var failed: Set<Int> = []
    func classEnd(_ open: Int) -> Int? {
        var k = open + 1
        if k < p.count, p[k] == "!" || p[k] == "^" { k += 1 }
        if k < p.count, p[k] == "]" { k += 1 }
        while k < p.count, p[k] != "]" { k += 1 }
        return k < p.count ? k : nil
    }
    func classMatches(_ body: ArraySlice<Character>, _ ch: Character) -> Bool {
        var items = Array(body)
        var negate = false
        if let first = items.first, first == "!" || first == "^" {
            negate = true
            items.removeFirst()
        }
        var matched = false
        var i = 0
        while i < items.count {
            if i + 2 < items.count, items[i + 1] == "-" {
                if items[i] <= ch, ch <= items[i + 2] { matched = true }
                i += 3
            } else {
                if items[i] == ch { matched = true }
                i += 1
            }
        }
        return matched != negate
    }
    func match(_ startP: Int, _ startT: Int) -> Bool {
        var pi = startP
        var ti = startT
        while pi < p.count {
            let key = pi * width + ti
            if failed.contains(key) { return false }
            // A closed `[…]` class; an unclosed `[` is a literal (`default`).
            if p[pi] == "[", let close = classEnd(pi) {
                guard ti < t.count, classMatches(p[(pi + 1)..<close], t[ti]) else {
                    failed.insert(key)
                    return false
                }
                pi = close + 1
                ti += 1
                continue
            }
            switch p[pi] {
            case "*":
                var np = pi
                while np < p.count, p[np] == "*" { np += 1 }
                if np == p.count { return true }
                var k = ti
                while k <= t.count {
                    if match(np, k) { return true }
                    k += 1
                }
                failed.insert(key)
                return false
            case "?":
                if ti >= t.count { failed.insert(key); return false }
                pi += 1
                ti += 1
            default:
                if ti >= t.count || p[pi] != t[ti] { failed.insert(key); return false }
                pi += 1
                ti += 1
            }
        }
        return ti == t.count
    }
    return match(0, 0)
}
