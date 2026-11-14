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
        launchedCommandHeads(command.rawValue).contains { launchWeakens($0, xargsDepth: 0) }
    }
}

private func launchWeakens(_ launched: LaunchedCommand, xargsDepth: Int) -> Bool {
    // Truncated input cannot be followed: unknown, so flagged. A dynamic
    // or glob head may resolve to rv: judged as rv (fail closed).
    launched.truncated || isWeakeningInvocation(launched.guardArgv, headMayBeRV: launched.headIsDynamic)
        || xargsFeedsWeakeningInvocation(launched, depth: xargsDepth)
}

/// Stands in for the words `xargs` appends from stdin, and for each
/// replace-string occurrence (`-I %`): unmodelled, so it counts as a
/// flag-gated write (`draft`/`rollback --save`), as a dynamic verb, and as
/// a dynamic head, and an operand-less `xargs rv` fails closed.
private let xargsStdinWord = "$xargs-stdin"

private let xargsProgramNames: Set<String> = ["xargs", "gxargs"]

/// xargs feeding xargs feeding…: past this, fail closed.
private let maxXargsDepth = 4

/// Real xargs lines have one program candidate; more come only from
/// unknown options. Past this bound, fail closed instead of re-resolving.
private let maxXargsCandidates = 32

/// `xargs` runs its program with stdin words appended, and the launcher
/// parser does not follow it. Each word that may be xargs's program
/// (`scanXargsOptions`) starts a command that is re-fed through the shared
/// launcher resolver, so `sudo`/`env`/`nohup`/`timeout` prefixes, shell
/// `-c` payloads and dynamic heads resolve as they do at top level. It is
/// judged as written and with every replace-string occurrence swapped for
/// the stdin stand-in, the stand-in appended to both. Only adds refusals.
private func xargsFeedsWeakeningInvocation(_ launched: LaunchedCommand, depth: Int) -> Bool {
    guard launched.headIsDynamic == false, let name = launched.guardArgv.first,
          xargsProgramNames.contains(name) else { return false }
    guard depth < maxXargsDepth else { return true }
    let words = Array(launched.guardArgv.dropFirst())
    let scan = scanXargsOptions(words)
    if scan.starts.count > maxXargsCandidates { return true }
    return scan.starts.contains { start in
        let program = Array(words[start...])
        var variants = [program]
        let substituted = substitutingReplaceStrings(scan.replaceStrings, in: program)
        if substituted != program { variants.append(substituted) }
        return variants.contains { argv in
            launchedCommandHeads(argv: argv + [xargsStdinWord], depth: depth + 1)
                .contains { launchWeakens($0, xargsDepth: depth + 1) }
        }
    }
}

/// xargs replaces each occurrence of its replace string (`-I`/`-J`/`-i`/
/// `--replace`) with an input line, inside a word as well as whole.
private func substitutingReplaceStrings(_ replaceStrings: Set<String>, in words: [String]) -> [String] {
    let strings = replaceStrings.filter { $0.isEmpty == false }
    guard strings.isEmpty == false else { return words }
    return words.map { word in
        var out = word
        for string in strings {
            let unescaped = unescapeBackslashPairs(out)
            if out.contains(string) {
                out = out.replacing(string, with: xargsStdinWord)
            } else if unescaped.contains(string) {
                out = unescaped.replacing(string, with: xargsStdinWord)
            }
        }
        return out
    }
}

/// Short option letters that take no value (BSD and GNU).
private let xargsFlagLetters: Set<Character> = ["0", "o", "p", "r", "t", "x"]

/// A short cluster `xargsShortCluster` can walk exactly: every letter
/// before the first value-taking one is a known flag. An unknown letter
/// may take the next word on some platform, so it stays ambiguous.
private func isKnownXargsCluster(_ word: String) -> Bool {
    for letter in word.dropFirst() {
        if xargsFlagLetters.contains(letter) { continue }
        return xargsValueLetters.contains(letter) || xargsOptionalLetters.contains(letter)
            || ["I", "J", "i"].contains(letter)
    }
    return word.count > 1
}

/// Indexes into xargs's operands that may be its program, plus every
/// replace string its options name. Known options (clusters included) are
/// walked with the same parsers as `peelXargs`. An unknown option may or
/// may not take the next word, so that word stays a candidate and the
/// scan continues after it. The first word that can only be the program
/// ends the scan.
private func scanXargsOptions(_ words: [String]) -> (starts: [Int], replaceStrings: Set<String>) {
    var starts: [Int] = []
    var replaceStrings: Set<String> = []
    var index = 0
    while index < words.count {
        let word = unescapeBackslashPairs(words[index])
        if word == "--" {
            if index + 1 < words.count { starts.append(index + 1) }
            break
        }
        guard word.hasPrefix("-"), word != "-" else {
            starts.append(index)
            break
        }
        let next = index + 1 < words.count ? unescapeBackslashPairs(words[index + 1]) : nil
        let step: XargsOptionStep? = word.hasPrefix("--")
            ? xargsLongOption(word, next: next)
            : (isKnownXargsCluster(word) ? xargsShortCluster(word, next: next) : nil)
        if let step {
            if let replace = step.replace { replaceStrings.insert(replace) }
            index += step.width
        } else if let next, next.hasPrefix("-") == false {
            starts.append(index + 1)
            index += 2
        } else {
            index += 1
        }
    }
    return (starts, replaceStrings)
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
