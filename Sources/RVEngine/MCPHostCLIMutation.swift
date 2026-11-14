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
/// themselves count: `fastmcp install`; `mcp install` as the program, under
/// a Python or plain runner (`uv run mcp install`) or given a `.py` server;
/// the `@smithery/cli`, `install-mcp` and `add-mcp` package specs and
/// programs anywhere, and any spec of them a runner runs.
func isHostMCPMutation(_ command: LaunchedCommand, reads: HostTextReads) -> Bool {
    let words = command.guardArgv.map(foldedWord)
    if command.headIsDynamic, words.dropFirst().contains(where: dynamicGroupWords.contains) { return true }
    let head = commandName(command.head)
    let feedsWords = argvFeeders.contains(head)
    // A runner anywhere before a word may run it: `corepack pnpm dlx X`,
    // `mise exec -- npx X`, `chronic uvx mcp install s.py`.
    let firstRunner = words.firstIndex { hostRunners.contains(commandName($0)) }
    let firstPythonRunner = words.firstIndex { pythonRunners.contains(commandName($0)) }
    let runs = { (index: Int) in index == 0 || firstRunner.map { $0 < index } == true }
    for (index, word) in words.enumerated() {
        if isConfigInstallerPackage(word) || configInstallerPrograms.contains(commandName(word)) { return true }
        if runs(index), packageNames(word).contains(where: configInstallerNames.contains) { return true }
        // A runner given a command line as one word (`watch 'claude mcp
        // add x'`, `su -c '…'`, `parallel '…' ::: x`, Linux `script -c`).
        if index > 0, runs(index), carriesHostMCPMutation(word, reads: reads) { return true }
        let rest = Array(words[(index + 1)...])
        let place = HostWordPlace(
            runs: runs(index), feedsWords: feedsWords,
            pythonRun: index == 0 || firstPythonRunner.map { $0 < index } == true)
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
}

private func hostWordMutates(_ host: String, rest: [String], place: HostWordPlace) -> Bool {
    if editorHosts.contains(host) {
        if rest.contains(where: { $0 == "--add-mcp" || $0.hasPrefix("--add-mcp=") }) { return true }
        if host != "cursor" { return false }
    }
    if host == "fastmcp" { return rest.first == "install" }
    if host == "mcp" {
        // `mcp` is a common directory and package name (`make -C mcp
        // install`): the program run, or given a Python server file.
        return (place.pythonRun || rest.contains(where: namesPythonServer)) && rest.first == "install"
    }
    guard let groups = hostGroups[host] else { return false }
    if agentHosts.contains(host), place.runs, place.feedsWords || rest.contains(where: mayStandForWords) {
        return true
    }
    guard rest.contains(where: groups.contains) else { return false }
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
    if name == "claude-code" || word.contains("/claude/versions/") { hosts.append("claude") }
    for (package, host) in hostPackages where word.contains(package) { hosts.append(host) }
    for package in packageNames(word) {
        if let host = hostPackageNames[package] { hosts.append(host) }
        if pythonInstallers.contains(package) { hosts.append(package) }
    }
    var seen: Set<String> = []
    return hosts.filter { seen.insert($0).inserted }
}

/// A word holding a whole command line that runs a host MCP CLI (`'claude
/// mcp add x'` given to a runner, echoed into a shell, or a here-string).
func carriesHostMCPMutation(_ word: String, reads: HostTextReads) -> Bool {
    word.contains(where: \.isWhitespace) && reads.runsHostMCPMutation(word)
}

/// Text no shell parse splits into words, such as inline program code or
/// a quoted string (`os.system("claude mcp add x")`, `X='claude mcp add
/// x'`), cut at every character a program or package name cannot hold: a
/// host CLI or package whose next non-option piece is one of its groups,
/// unless the pieces after it are exactly a read-only form; an installer's
/// package or program; `fastmcp install`; `mcp install` given a `.py`
/// server; an editor given `--add-mcp`. Over-reports on prose that names a
/// host mutation, as a commit message or a grep pattern may.
func textNamesHostMCPMutation(_ text: String) -> Bool {
    let pieces = textPieces(text)
    guard pieces.count > 1 else { return false }
    for (index, piece) in pieces.enumerated() {
        if isConfigInstallerPackage(piece) || configInstallerPrograms.contains(commandName(piece)) { return true }
        if packageNames(piece).contains(where: configInstallerNames.contains) { return true }
        let rest = Array(pieces[(index + 1)...])
        for host in hostCLIs(piece) {
            if editorHosts.contains(host), rest.contains(where: { $0.hasPrefix("--add-mcp") }) { return true }
            if host == "fastmcp", rest.first == "install" { return true }
            if host == "mcp", rest.first == "install", rest.contains(where: namesPythonServer) { return true }
            guard let groups = hostGroups[host], let next = rest.first(where: { $0.hasPrefix("-") == false }),
                  groups.contains(next)
            else { continue }
            if isReadOnlyHostForm(host: host, rest) == false { return true }
        }
    }
    return false
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
