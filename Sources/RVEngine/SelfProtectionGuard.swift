import RVDomain

/// rv must not let the agent it guards weaken it.
///
/// `weakensPolicy` is true when any launched command is an `rv` invocation
/// that lowers protection: uninstalling, disabling packs, lowering safety,
/// adding allowlist entries, redeeming or minting allow-once permits,
/// applying or saving policy, approving egress/MCP calls, trusting an
/// edited mcp.json, removing the secrets pre-commit hook, or signing
/// managed policy. `evaluate` floors such a command at indeterminate
/// ("run it in Terminal"): the owner runs rv administration, never the
/// agent. Reads of rv's config dir are a separate secret-path rule.
public enum SelfProtectionGuard {
    public static func weakensPolicy(_ command: ShellCommand) -> Bool {
        launchedCommandHeads(command.rawValue).contains { launched in
            // A dynamic or glob head may resolve to rv: judge it as rv (fail closed).
            isWeakeningInvocation(launched.argv, headMayBeRV: isDynamicOrGlobWord(launched.head))
        }
    }
}

/// `rv` is the C front door; it execs the installed `rv-cli` sibling with the
/// same argv, so invoking `rv-cli` directly is the same Swift CLI.
private let rvProgramNames: Set<String> = ["rv", "rv-cli"]

private func isDynamicOrGlobWord(_ word: String) -> Bool {
    word.contains("$") || word.contains("`") || isGlobBraceHead(word)
}

/// A word as the filesystem/shell resolves it for matching: unescaped and
/// case-folded. Words that cannot be modelled exactly (`$'...'`, `$X`) are
/// handled by callers as possibly-anything.
private func foldedWord(_ word: String) -> String {
    unescapeBackslashPairs(word).folding(options: .caseInsensitive, locale: nil)
}

private let subcommandVerbs: Set<String> = [
    "packs", "safety", "allowlist", "allow-once", "policy", "egress", "mcp", "secrets", "managed",
]

private func isWeakeningInvocation(_ rawArgv: [String], headMayBeRV: Bool) -> Bool {
    guard let program = rawArgv.first, headMayBeRV || rvProgramNames.contains(program) else { return false }
    let args = rawArgv.dropFirst().map(foldedWord)
    let words = args.filter { $0.hasPrefix("-") == false }
    let flags = Set(args.filter { $0.hasPrefix("-") })
    guard let verb = words.first else { return false }
    let sub = words.dropFirst().first
    if isDynamicWord(verb) { return true }
    if subcommandVerbs.contains(verb), words.dropFirst().contains(where: isDynamicWord) { return true }
    switch verb {
    case "uninstall":
        return true
    case "packs":
        return sub == "disable"
    case "safety":
        return sub.map { $0 != SafetyLevel.strict.rawValue } ?? false
    case "allowlist":
        return sub == "add" || sub == "add-command"
    case "allow-once":
        // Bare `rv allow-once` redeems.
        return sub == nil || sub == "redeem" || sub == "mint" || sub.map(isUnlockCode) == true
    case "policy":
        return sub == "apply" || (sub == "draft" && flags.contains("--save"))
    case "egress", "mcp":
        return sub == "approve" || (verb == "mcp" && sub == "trust")
    case "secrets":
        return sub == "hook" && words.dropFirst(2).first == "uninstall"
    case "managed":
        return sub == "sign"
    default:
        return false
    }
}

private func isUnlockCode(_ word: String) -> Bool {
    word.isEmpty == false && word.allSatisfy(\.isNumber)
}

private func isDynamicWord(_ word: String) -> Bool {
    word.contains("$") || word.contains("`")
}
