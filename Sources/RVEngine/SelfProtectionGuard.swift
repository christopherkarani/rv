import RVDomain

/// rv must not let the agent it guards weaken it.
///
/// `weakensPolicy` is true when any launched command is an `rv` invocation
/// that lowers protection: uninstalling, disabling packs, lowering safety,
/// adding allowlist entries, redeeming or minting allow-once permits,
/// applying, saving, or rolling back policy, approving egress/MCP calls, trusting an
/// edited mcp.json, writing secrets (`rv secrets set|remove|import|oauth-reset`),
/// removing the secrets pre-commit hook, signing
/// managed policy, setting a host to anything but `block`
/// (`rv host mode <host> observe|off`), or switching rv to observe
/// (`rv setup --observe`). `evaluate` floors such a command at indeterminate
/// ("run it in Terminal"): the owner runs rv administration, never the
/// agent. Reads of rv's config dir are a separate secret-path rule.
public enum SelfProtectionGuard {
    public static func weakensPolicy(_ command: ShellCommand) -> Bool {
        launchedCommandHeads(command.rawValue).contains { launched in
            // Truncated input cannot be followed: unknown, so flagged. A dynamic
            // or glob head may resolve to rv: judged as rv (fail closed).
            launched.truncated || isWeakeningInvocation(launched.guardArgv, headMayBeRV: launched.headIsDynamic)
                || xargsFeedsWeakeningInvocation(launched)
        }
    }
}

/// Stands in for the words `xargs` appends from stdin: unmodelled, so a
/// flag-gated write (`draft`/`rollback --save`) counts as one and an
/// operand-less `xargs rv` fails closed.
private let xargsStdinWord = "$xargs-stdin"

/// `xargs` runs its program with stdin words appended, and the launcher
/// parser does not follow it. Each word that may be xargs's program
/// (`xargsProgramCandidates`) and is `rv`/`rv-cli`, or dynamic (it may
/// resolve to rv), starts a candidate command judged with the stdin
/// stand-in appended. Only adds refusals.
private func xargsFeedsWeakeningInvocation(_ launched: LaunchedCommand) -> Bool {
    guard launched.headIsDynamic == false, launched.guardArgv.first == "xargs" else { return false }
    let words = Array(launched.guardArgv.dropFirst())
    let starts = xargsProgramCandidates(words)
    if starts.count > maxVerbCandidates { return true }
    return starts.contains { start in
        let program = words[start]
        let dynamic = isUnmodelledWord(program)
        guard dynamic || rvProgramNames.contains(commandName(program)) else { return false }
        let argv = [dynamic ? program : "rv"] + words[(start + 1)...] + [xargsStdinWord]
        return isWeakeningInvocation(argv, headMayBeRV: dynamic)
    }
}

/// xargs options (BSD and GNU) whose value is the next word.
private let xargsValuedOptions: Set<String> = [
    "-E", "-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s", "-a", "-d",
    "--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars", "--process-slot-var",
]

/// xargs options that take no separate value (GNU `-e`/`-i`/`-l` and
/// `--eof`/`--replace`/`--max-lines` take theirs attached only).
private let xargsFlagOptions: Set<String> = [
    "-0", "-o", "-p", "-r", "-t", "-x", "-e", "-i", "-l",
    "--null", "--open-tty", "--interactive", "--no-run-if-empty", "--verbose", "--exit",
    "--show-limits", "--eof", "--replace", "--max-lines",
]

/// Indexes into xargs's operands that may be its program. Known options
/// are skipped with their values; an unknown option may or may not take
/// the next word, so both that word and the one after stay candidates.
/// The first word that can only be the program ends the scan.
private func xargsProgramCandidates(_ words: [String]) -> [Int] {
    var candidates: [Int] = []
    var index = 0
    while index < words.count {
        let word = unescapeBackslashPairs(words[index])
        if word == "--" {
            if index + 1 < words.count { candidates.append(index + 1) }
            break
        }
        guard word.hasPrefix("-"), word != "-" else {
            candidates.append(index)
            break
        }
        if xargsFlagOptions.contains(word) || isAttachedXargsValue(word) {
            index += 1
        } else if xargsValuedOptions.contains(word) {
            index += 2
        } else {
            if index + 1 < words.count, words[index + 1].hasPrefix("-") == false {
                candidates.append(index + 1)
                index += 2
            } else {
                index += 1
            }
        }
    }
    return candidates
}

/// `-n1`, `-I{}`, `--max-args=1`, `-eEOF`: the value is part of the word.
private func isAttachedXargsValue(_ word: String) -> Bool {
    if word.hasPrefix("--") { return word.contains("=") }
    guard word.count > 2 else { return false }
    let option = String(word.prefix(2))
    return xargsValuedOptions.contains(option) || ["-e", "-i", "-l"].contains(option)
}

/// `rv` is the C front door; it execs the installed `rv-cli` sibling with the
/// same argv, so invoking `rv-cli` directly is the same Swift CLI.
private let rvProgramNames: Set<String> = ["rv", "rv-cli"]

private let subcommandVerbs: Set<String> = [
    "packs", "safety", "allowlist", "allow-once", "policy", "egress", "mcp", "secrets", "managed", "host",
]

/// A word whose runtime value is not its text (`$X`, `$'..'`, backticks) or
/// that expands to other words (`*`, `?`, `[`, `{`). Where it decides the
/// action it counts as weakening: fail closed.
private func isUnmodelledWord(_ word: String) -> Bool {
    word.contains(where: { "$`*?[{".contains($0) })
}

private let maxVerbCandidates = 256

private func isWeakeningInvocation(_ rawArgv: [String], headMayBeRV: Bool) -> Bool {
    guard let program = rawArgv.first, headMayBeRV || rvProgramNames.contains(program) else { return false }
    let args = rawArgv.dropFirst().map(foldedWord)
    guard let firstWord = args.firstIndex(where: { $0.hasPrefix("-") == false }) else { return false }
    // An option before the verb may take a value (`rv --config x uninstall`),
    // so any later word could be the verb.
    let verbIndexes = firstWord == 0 ? [firstWord] : args.indices.filter { args[$0].hasPrefix("-") == false }
    // Each candidate scans the tail: past a bound, fail closed instead of going quadratic.
    if verbIndexes.count > maxVerbCandidates { return true }
    return verbIndexes.contains { isWeakeningVerb(args, at: $0) }
}

private func isWeakeningVerb(_ args: [String], at verbIndex: Int) -> Bool {
    let verb = args[verbIndex]
    if isUnmodelledWord(verb) || verb == "uninstall" { return true }
    // `setup --observe` sheds oversight; a variable or glob may carry the flag.
    if verb == "setup" {
        return args[(verbIndex + 1)...].contains { $0 == "--observe" || isUnmodelledWord($0) }
    }
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
        return isWeakeningSub(verb: verb, sub: sub, third: third, flags: flags, tail: rest[(index + 1)...])
    }
}

private func isWeakeningSub(
    verb: String, sub: String, third: String?, flags: Set<String>, tail: ArraySlice<String>
) -> Bool {
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
        // `draft --save` and `rollback --save` write the layer; a variable
        // or glob may carry the flag. Without it both are read-only previews.
        let writesLayer = flags.contains("--save") || tail.contains(where: isUnmodelledWord)
        return sub == "apply" || ((sub == "draft" || sub == "rollback") && writesLayer)
    case "egress", "mcp":
        return sub == "approve" || (verb == "mcp" && sub == "trust")
    case "secrets":
        // Every secrets.json or Keychain write: an agent that defines or
        // imports a secret chooses which real value reaches a cage, or which
        // host the gateway sends it to (a Varlock `@proxy(domain=...)`).
        switch sub {
        case "set", "remove", "oauth-reset": return true
        case "import": return flags.contains("--dry-run") == false
        case "hook": return third.map { $0 == "uninstall" || isUnmodelledWord($0) } == true
        default: return false
        }
    case "managed":
        return sub == "sign"
    case "host":
        // `mode <host> block` is the one tightening form; a missing, extra,
        // unknown or unmodelled word fails closed. `--json`/`--robot` take
        // no value, so flags are skipped.
        guard sub == "mode" else { return false }
        let positionals = tail.filter { $0.hasPrefix("-") == false }
        return positionals.count != 2 || positionals.last != HostModeWord.block
    default:
        return false
    }
}

/// `HostMode.block` lives in RVPolicy, which RVEngine does not import.
private enum HostModeWord {
    static let block = "block"
}

private func isUnlockCode(_ word: String) -> Bool {
    word.isEmpty == false && word.allSatisfy(\.isNumber)
}
