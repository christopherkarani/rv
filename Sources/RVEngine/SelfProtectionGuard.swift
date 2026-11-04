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
            // Truncated input cannot be followed: unknown, so flagged. A dynamic
            // or glob head may resolve to rv: judged as rv (fail closed).
            launched.truncated || isWeakeningInvocation(launched.argv, headMayBeRV: launched.headIsDynamic)
        }
    }
}

/// `rv` is the C front door; it execs the installed `rv-cli` sibling with the
/// same argv, so invoking `rv-cli` directly is the same Swift CLI.
private let rvProgramNames: Set<String> = ["rv", "rv-cli"]

private let subcommandVerbs: Set<String> = [
    "packs", "safety", "allowlist", "allow-once", "policy", "egress", "mcp", "secrets", "managed",
]

/// A word whose runtime value is not its text (`$X`, `$'..'`, backticks) or
/// that expands to other words (`*`, `?`, `[`, `{`). Where it decides the
/// action it counts as weakening: fail closed.
private func isUnmodelledWord(_ word: String) -> Bool {
    word.contains(where: { "$`*?[{".contains($0) })
}

private func isWeakeningInvocation(_ rawArgv: [String], headMayBeRV: Bool) -> Bool {
    guard let program = rawArgv.first, headMayBeRV || rvProgramNames.contains(program) else { return false }
    let args = rawArgv.dropFirst().map(foldedWord)
    guard let firstWord = args.firstIndex(where: { $0.hasPrefix("-") == false }) else { return false }
    // An option before the verb may take a value (`rv --config x uninstall`),
    // so any later word could be the verb.
    let verbIndexes = firstWord == 0 ? [firstWord] : args.indices.filter { args[$0].hasPrefix("-") == false }
    return verbIndexes.contains { isWeakeningVerb(args, at: $0) }
}

private func isWeakeningVerb(_ args: [String], at verbIndex: Int) -> Bool {
    let verb = args[verbIndex]
    if isUnmodelledWord(verb) || verb == "uninstall" { return true }
    guard subcommandVerbs.contains(verb) else { return false }
    let rest = Array(args[(verbIndex + 1)...])
    let flags = Set(rest.filter { $0.hasPrefix("-") })
    // An option before the sub may take a value: any later word could be the sub.
    let optionBeforeSub = rest.first?.hasPrefix("-") == true
    let subIndexes = optionBeforeSub
        ? rest.indices.filter { rest[$0].hasPrefix("-") == false }
        : (rest.isEmpty ? [] : [0])
    if subIndexes.isEmpty { return verb == "allow-once" }
    return subIndexes.contains { index in
        let sub = rest[index]
        let third = rest[(index + 1)...].first { $0.hasPrefix("-") == false }
        return isWeakeningSub(verb: verb, sub: sub, third: third, flags: flags)
    }
}

private func isWeakeningSub(verb: String, sub: String, third: String?, flags: Set<String>) -> Bool {
    if isUnmodelledWord(sub) { return true }
    switch verb {
    case "packs":
        return sub == "disable"
    case "safety":
        return sub != SafetyLevel.strict.rawValue
    case "allowlist":
        return sub == "add" || sub == "add-command"
    case "allow-once":
        return sub == "redeem" || sub == "mint" || isUnlockCode(sub)
    case "policy":
        return sub == "apply" || (sub == "draft" && flags.contains("--save"))
    case "egress", "mcp":
        return sub == "approve" || (verb == "mcp" && sub == "trust")
    case "secrets":
        return sub == "hook" && third.map { $0 == "uninstall" || isUnmodelledWord($0) } == true
    case "managed":
        return sub == "sign"
    default:
        return false
    }
}

private func isUnlockCode(_ word: String) -> Bool {
    word.isEmpty == false && word.allSatisfy(\.isNumber)
}
