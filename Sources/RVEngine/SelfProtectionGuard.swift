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
/// flag-gated write (`draft`/`rollback --save`) and as a dynamic verb. A
/// re-fed command whose head is or contains it runs a program stdin
/// chose (`xargs sudo`, `xargs -I{} sh -c '{}'`): refused.
private let xargsStdinWord = "$xargs-stdin"

private let xargsProgramNames: Set<String> = ["xargs", "gxargs"]

/// xargs feeding xargs feeding…: past this, fail closed.
private let maxXargsDepth = 4

/// `xargs` runs its program with stdin words, and the launcher parser does
/// not follow it. The program is re-fed through the shared launcher
/// resolver (`sudo`/`env`/`nohup`/`timeout` prefixes, shell `-c`, `eval`,
/// dynamic heads, nested xargs), judged as written and with every replace
/// string swapped for the stdin stand-in; the stand-in is appended unless
/// replace mode alone is in effect. A dynamic head may be xargs too.
///
/// Fail closed rather than model xargs precisely: a literal xargs whose
/// options do not parse exactly (`parseXargsOptions` nil) is refused
/// whenever any of its words could reach rv (`uncertainXargsMayReachRV`).
/// A line with no such word is left to the other stages, so the
/// self-protection floor does not mask their deny (`xargs --frobnicate
/// rm -r` stays denied). Relative to main this only adds refusals. A
/// dynamic head is judged as xargs only when its options parse, since
/// `$PYTHON -m x` is far likelier than a variable naming xargs; it is
/// still judged as rv and as a launcher elsewhere.
private func xargsFeedsWeakeningInvocation(_ launched: LaunchedCommand, depth: Int) -> Bool {
    guard let name = launched.guardArgv.first,
          launched.headIsDynamic || xargsProgramNames.contains(name) else { return false }
    guard depth < maxXargsDepth else { return true }
    let words = Array(launched.guardArgv.dropFirst())
    guard let parsed = parseXargsOptions(words) else {
        return launched.headIsDynamic == false && uncertainXargsMayReachRV(words)
    }
    // No program: xargs runs echo.
    guard let start = parsed.programStart else { return false }
    let program = Array(words[start...])
    let stdin = parsed.appendsStdin ? [xargsStdinWord] : []
    var variants = [program + stdin]
    let substituted = substitutingReplaceStrings(parsed.replaceStrings, in: program)
    if substituted != program { variants.append(substituted + stdin) }
    return variants.contains { argv in
        launchedCommandHeads(argv: argv, depth: depth + 1).contains { fed in
            fed.head.contains(xargsStdinWord) || launchWeakens(fed, xargsDepth: depth + 1)
        }
    }
}

/// Programs that may run a command their stdin or operands name.
private let xargsExecNames: Set<String> = plainLaunchers.union(shellNames).union([
    "sudo", "env", "timeout", "busybox", "eval", "stdbuf", "ionice", "xargs", "gxargs",
])

/// With options that do not parse, any word may be the program, a value,
/// or a replace string. A word could reach rv when it names rv (any
/// spelling containing `rv`), is unmodelled, names a program that runs
/// other commands, has no letter or digit (a possible replace string in
/// head position, `-` included), or when a possible option value occurs
/// again in a later word (a possible replace string, `--repl=X X`).
private func uncertainXargsMayReachRV(_ words: [String]) -> Bool {
    let unescaped = words.map(unescapeBackslashPairs)
    for (index, word) in unescaped.enumerated() {
        if word == "--" { continue }
        if word.lowercased().contains("rv") || isUnmodelledWord(word) { return true }
        if xargsExecNames.contains(commandName(word)) { return true }
        if word.contains(where: { $0.isLetter || $0.isNumber }) == false { return true }
        guard word.hasPrefix("-") else { continue }
        // (value, first word after it): attached, then the next word.
        var values: [(String, Int)] = []
        if let equals = word.firstIndex(of: "=") {
            values.append((String(word[word.index(after: equals)...]), index + 1))
        } else if word.hasPrefix("--") == false, word.count > 2 {
            values.append((String(word.dropFirst(2)), index + 1))
        }
        if index + 1 < unescaped.count { values.append((unescaped[index + 1], index + 2)) }
        if values.contains(where: { value, after in
            value.isEmpty == false && unescaped.dropFirst(after).contains { $0.contains(value) }
        }) {
            return true
        }
    }
    return false
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

/// Letters and long names that set a per-command argument count; with a
/// replace string, which one wins is platform-specific, so stdin is
/// assumed appended.
private let xargsCountLetters: Set<Character> = ["n", "L", "l"]
private let xargsCountLongNames: Set<String> = ["max-args", "max-lines"]

/// A short cluster `xargsShortCluster` walks exactly: every letter before
/// the first value-taking one is a known flag.
private func isKnownXargsCluster(_ word: String) -> Bool {
    for letter in word.dropFirst() {
        if xargsFlagLetters.contains(letter) { continue }
        return xargsValueLetters.contains(letter) || xargsOptionalLetters.contains(letter)
            || ["I", "J", "i"].contains(letter)
    }
    return word.count > 1
}

/// Whether the cluster's letters up to its value-taking one set a count.
private func clusterSetsCount(_ word: String) -> Bool {
    for letter in word.dropFirst() {
        if xargsCountLetters.contains(letter) { return true }
        if xargsFlagLetters.contains(letter) == false { return false }
    }
    return false
}

private struct ParsedXargs {
    /// Index of the program word; nil when xargs runs its default (echo).
    var programStart: Int?
    var replaceStrings: Set<String> = []
    /// False only in replace mode with no count option: xargs then
    /// substitutes stdin instead of appending it.
    var appendsStdin = true
}

/// xargs's options, walked with the parsers `peelXargs` uses. Nil when any
/// step is not exact: an unknown or abbreviated option, an unknown cluster
/// letter, a missing value, a value that looks like an option, or `-` in
/// program position. Callers fail closed on nil.
private func parseXargsOptions(_ words: [String]) -> ParsedXargs? {
    var parsed = ParsedXargs()
    var setsCount = false
    var index = 0
    while index < words.count {
        let word = unescapeBackslashPairs(words[index])
        if word == "--" {
            if index + 1 < words.count { parsed.programStart = index + 1 }
            break
        }
        if word == "-" { return nil }
        guard word.hasPrefix("-") else {
            parsed.programStart = index
            break
        }
        let next = index + 1 < words.count ? unescapeBackslashPairs(words[index + 1]) : nil
        let step: XargsOptionStep?
        if word.hasPrefix("--") {
            step = xargsLongOption(word, next: next)
            setsCount = setsCount || xargsCountLongNames.contains(String(word.dropFirst(2).prefix { $0 != "=" }))
        } else {
            step = isKnownXargsCluster(word) ? xargsShortCluster(word, next: next) : nil
            setsCount = setsCount || clusterSetsCount(word)
        }
        guard let step else { return nil }
        if step.width == 2, next?.hasPrefix("-") == true { return nil }
        if let replace = step.replace { parsed.replaceStrings.insert(replace) }
        index += step.width
    }
    parsed.appendsStdin = parsed.replaceStrings.isEmpty || setsCount
    return parsed
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
