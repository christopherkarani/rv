import RVDomain

/// Whether `command` may run a host CLI that adds, removes or installs MCP
/// servers or plugins. The host may sit anywhere in argv, behind a launcher
/// rv does not strip (`npx @anthropic-ai/claude-code mcp add`, `bunx`,
/// `pnpm dlx`, `stdbuf`, `script`, `node …/cli.js`): any word naming a host
/// CLI or its package, followed anywhere by its `mcp`/`plugin` group, counts
/// unless the words after it are exactly a read-only form
/// (`readOnlyHostForms`). Editors count with `--add-mcp` anywhere after them.
func isHostMCPMutation(_ command: LaunchedCommand) -> Bool {
    let words = command.guardArgv.map(foldedWord)
    for (index, word) in words.enumerated() {
        guard let host = hostCLI(word) else { continue }
        let rest = Array(words[(index + 1)...])
        if editorHosts.contains(host) {
            if rest.contains(where: { $0 == "--add-mcp" || $0.hasPrefix("--add-mcp=") }) { return true }
            if host != "cursor" { continue }
        }
        guard let groups = hostGroups[host], rest.contains(where: groups.contains) else { continue }
        if isReadOnlyHostForm(host: host, rest) == false { return true }
    }
    return false
}

/// The host CLI a word runs: its program name, or the npm package that
/// ships it (`@anthropic-ai/claude-code@latest`, `…/claude-code/cli.js`).
private func hostCLI(_ word: String) -> String? {
    let name = commandName(word)
    if hostGroups[name] != nil || editorHosts.contains(name) { return name }
    for (package, host) in hostPackages where word.contains(package) { return host }
    if name == "claude-code" { return "claude" }
    return nil
}

private let editorHosts: Set<String> = ["code", "code-insiders", "cursor", "windsurf"]

private let hostGroups: [String: Set<String>] = [
    "claude": ["mcp", "plugin", "plugins"],
    "codex": ["mcp"],
    "gemini": ["mcp"],
    "opencode": ["mcp"],
    "cursor": ["mcp"],
    "cursor-agent": ["mcp"],
]

private let hostPackages: [(String, String)] = [
    ("@anthropic-ai/claude-code", "claude"),
    ("@openai/codex", "codex"),
    ("@google/gemini-cli", "gemini"),
    ("opencode-ai", "opencode"),
]

/// The exact argv tails (after the host word) that only print. `NAME`
/// stands for one non-option word. `claude mcp serve` is not here: it runs
/// Claude Code's own tools for another client, which rv cannot show is
/// harmless.
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
    case "opencode":
        forms = [["mcp"], ["mcp", "list"], ["mcp", "ls"]]
    default:
        forms = [["mcp"], ["mcp", "list"]]
    }
    // `<group> --help`, `<group> <sub> --help` only print.
    if let last = rest.last, helpWords.contains(last), (2...3).contains(rest.count),
       hostGroups[host]?.contains(rest[0]) == true
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

private let helpWords: Set<String> = ["help", "--help", "-h"]
