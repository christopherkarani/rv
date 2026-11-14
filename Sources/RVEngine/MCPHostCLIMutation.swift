import RVDomain

/// Whether `command` may run a host CLI that adds, removes or installs MCP
/// servers or plugins. The host may sit anywhere in argv, behind a launcher
/// rv does not strip (`npx @anthropic-ai/claude-code mcp add`, `bunx`,
/// `pnpm dlx`, `stdbuf`, `script`, `node …/cli.js`): any word naming a host
/// CLI or its package, followed anywhere by its `mcp`/`plugin` group, counts
/// unless the words after it are exactly a read-only form
/// (`isReadOnlyHostForm`). So does an agent CLI run as the program, or by a
/// runner (`npx`, `node`, `stdbuf`, ...), whose words rv cannot see: one
/// given an expansion that may stand for its subcommand (`claude "$@"` in a
/// function, `claude $SUB add`) or fed more words by `xargs`/`parallel`; and
/// a dynamic program given an agent CLI's group word (`$C mcp add`), and a
/// runner given the whole command line as one word (`watch 'claude mcp add
/// x'`). Editors count with `--add-mcp` anywhere after them. Installers that
/// write host configs themselves count: `fastmcp install`; `mcp install` as
/// the program, under a Python or plain runner (`uv run mcp install`) or
/// given a `.py` server; the `@smithery/cli`, `install-mcp` and `add-mcp`
/// package specs anywhere, and their programs when run.
func isHostMCPMutation(_ command: LaunchedCommand) -> Bool {
    let words = command.guardArgv.map(foldedWord)
    if command.headIsDynamic, words.dropFirst().contains(where: dynamicGroupWords.contains) { return true }
    let head = commandName(command.head)
    let feedsWords = argvFeeders.contains(head)
    let runs = { (index: Int) in index == 0 || hostRunners.contains(head) }
    for (index, word) in words.enumerated() {
        if isConfigInstallerPackage(word) || runs(index) && configInstallerPrograms.contains(commandName(word)) {
            return true
        }
        // A runner given a command line as one word (`watch 'claude mcp
        // add x'`, `su -c '…'`, `parallel '…' ::: x`, Linux `script -c`).
        if index > 0, hostRunners.contains(head), word.contains(where: \.isWhitespace),
           launchedCommandHeads(word).contains(where: isHostMCPMutation)
        {
            return true
        }
        guard let host = hostCLI(word) else { continue }
        let rest = Array(words[(index + 1)...])
        if editorHosts.contains(host) {
            if rest.contains(where: { $0 == "--add-mcp" || $0.hasPrefix("--add-mcp=") }) { return true }
            if host != "cursor" { continue }
        }
        if host == "fastmcp" {
            if rest.first == "install" { return true }
            continue
        }
        if host == "mcp" {
            // `mcp` is a common directory and package name (`make -C mcp
            // install`): the program run, or given a Python server file.
            let run = index == 0 || pythonRunners.contains(head) || rest.contains(where: namesPythonServer)
            if run, rest.first == "install" { return true }
            continue
        }
        guard let groups = hostGroups[host] else { continue }
        if agentHosts.contains(host), runs(index), feedsWords || rest.contains(where: mayStandForWords) {
            return true
        }
        guard rest.contains(where: groups.contains) else { continue }
        if isReadOnlyHostForm(host: host, rest) == false { return true }
    }
    return false
}

/// The host CLI a word runs: its program name, or the npm package that
/// ships it (`@anthropic-ai/claude-code@latest`, `…/claude-code/cli.js`),
/// or Claude Code's native build (`~/.local/share/claude/versions/2.0.14`).
private func hostCLI(_ word: String) -> String? {
    let name = commandName(word)
    if hostGroups[name] != nil || editorHosts.contains(name) || pythonInstallers.contains(name) { return name }
    for (package, host) in hostPackages where word.contains(package) { return host }
    if name == "claude-code" || word.contains("/claude/versions/") { return "claude" }
    return nil
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
    "claude": ["mcp", "plugin", "plugins"],
    "codex": ["mcp", "mcp-server"],
    "gemini": ["mcp", "extensions"],
    "opencode": ["mcp"],
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

/// Packages and programs whose job is writing a server into host configs.
private let configInstallerPackages: [String] = ["@smithery/cli", "install-mcp", "add-mcp"]
private let configInstallerPrograms: Set<String> = ["smithery", "install-mcp", "add-mcp"]

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
    // `<group> help`, `<group> --help`, `<group> <sub> --help` only print.
    // A bare `help` elsewhere is an operand (`claude plugin install help`).
    if (2...3).contains(rest.count), hostGroups[host]?.contains(rest[0]) == true,
       rest[1] == "help" || ["--help", "-h"].contains(rest[rest.count - 1])
    {
        return true
    }
    return forms.contains { form in
        form.count == rest.count
            && zip(form, rest).allSatisfy { expected, word in
                expected == "NAME" ? word.hasPrefix("-") == false : expected == word
            }
    }
}
