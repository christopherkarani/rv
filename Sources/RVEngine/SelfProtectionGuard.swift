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
        launchedCommands(command.rawValue).contains(where: isWeakeningInvocation)
    }
}

/// `rv` is the C front door; it execs the installed `rv-cli` sibling with the
/// same argv, so invoking `rv-cli` directly is the same Swift CLI.
private let rvProgramNames: Set<String> = ["rv", "rv-cli"]

private func isWeakeningInvocation(_ argv: [String]) -> Bool {
    guard let program = argv.first, rvProgramNames.contains(program) else { return false }
    let words = argv.dropFirst().filter { $0.hasPrefix("-") == false }
    let flags = Set(argv.dropFirst().filter { $0.hasPrefix("-") })
    guard let verb = words.first else { return false }
    let sub = words.dropFirst().first
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
