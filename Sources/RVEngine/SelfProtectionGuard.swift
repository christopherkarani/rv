import Foundation
import RVDomain

/// rv must not let the agent it guards weaken it.
///
/// `weakensPolicy` is true when any launched command is an `rv` invocation
/// that lowers protection: uninstalling, disabling packs, lowering safety,
/// adding allowlist entries, redeeming or minting allow-once permits,
/// applying, saving, or rolling back policy, saving its ceiling, approving egress/MCP calls, trusting an
/// edited mcp.json, writing secrets (`rv secrets set|remove|import|oauth-reset`),
/// removing the secrets pre-commit hook, signing
/// managed policy, setting a host to anything but `block`
/// (`rv host mode <host> observe|off`), moving files across a workspace's
/// wall (`rv workspace upload|download`), or switching rv to observe
/// (`rv setup --observe`). `evaluate` floors such a command at indeterminate
/// ("run it in Terminal"): the owner runs rv administration, never the
/// agent. Reads of rv's config dir are a separate secret-path rule. A bare
/// help request (`rv uninstall --help`, `isHelpPageRequest`) runs nothing
/// and is not weakening.
///
/// rv may also run where the launcher parser cannot follow
/// (`SelfProtectionScripts`): an interpreter or shell runner's script
/// (`perl -e`, `su -c`, `ssh host cmd`), `find -exec`, and a program a
/// shell or interpreter reads from stdin (`echo … | sh`, `sh <<< …`).
public enum SelfProtectionGuard {
    public static func weakensPolicy(_ command: ShellCommand) -> Bool {
        let launched = followingFindExec(launchedCommandHeads(command.rawValue))
        if launched.contains(where: { launchWeakens($0, xargsDepth: 0) }) { return true }
        // A program read from stdin, or a script that runs its input or
        // names rv, takes words from elsewhere on the line (a producer,
        // here-string, heredoc, assignment): the whole line is scanned.
        let readsElsewhere = startsShellOnStdin(command.rawValue)
            || launched.contains(where: { readsProgramFromStdin($0) || scriptReachesPastItself($0) })
        return readsElsewhere && carriesWeakeningRV(command.rawValue)
    }
}

private func launchWeakens(_ launched: LaunchedCommand, xargsDepth: Int) -> Bool {
    // Truncated input cannot be followed: unknown, so flagged. A dynamic
    // or glob head may resolve to rv: judged as rv (fail closed). A script
    // is judged as opaque text (`SelfProtectionScripts`). At the top level
    // `followingFindExec` has re-fed every `find -exec` command; one an
    // xargs runs is checked here (`findUnderXargsWeakens`).
    launched.truncated || isWeakeningInvocation(launched.guardArgv, headMayBeRV: launched.headIsDynamic)
        || xargsFeedsWeakeningInvocation(launched, depth: xargsDepth)
        || opaqueScriptText(launched).map(carriesWeakeningRV) == true
        || (xargsDepth > 0 && findUnderXargsWeakens(launched, depth: xargsDepth))
}

/// A `find -exec` command an xargs runs (`xargs find . -exec rv`, with
/// `uninstall ;` on stdin): each clause is re-fed through the resolver and
/// judged like a launched command, a dynamic head and an unmodelled verb
/// included, and like an xargs program (stdin pasted into a script, a head
/// stdin chose, a dynamic head that may be xargs). A clause that runs
/// another find is not followed further: it is refused (fail closed, and
/// bounded); another xargs is followed up to `maxXargsDepth`.
private func findUnderXargsWeakens(_ launched: LaunchedCommand, depth: Int) -> Bool {
    findExecCommands(launched.guardArgv).contains { clause in
        scriptTakesStdin(clause) || launchedCommandHeads(argv: clause, depth: depth + 1).contains { fed in
            fed.truncated || fed.head.contains(xargsStdinWord)
                || isWeakeningInvocation(fed.guardArgv, headMayBeRV: fed.headIsDynamic)
                || opaqueScriptText(fed).map(carriesWeakeningRV) == true
                || findExecCommands(fed.guardArgv).isEmpty == false
                || xargsFeedsWeakeningInvocation(fed, depth: depth + 1)
        }
    }
}

/// Stands in for the words `xargs` appends from stdin, and for each
/// replace-string occurrence (`-I %`): unmodelled, so it counts as a
/// flag-gated write (`draft`/`rollback --save`) and as a dynamic verb. A
/// re-fed command whose head is or contains it runs a program stdin
/// chose (`xargs sudo`, `xargs -I{} sh -c '{}'`): refused, as is a shell or
/// `eval` script that holds it (`scriptTakesStdin`).
private let xargsStdinWord = "$xargs-stdin"

private let xargsProgramNames: Set<String> = ["xargs", "gxargs"]

/// The stdin stand-in, for other guards that follow xargs.
let xargsStandIn = xargsStdinWord

/// `launched` plus the commands each `xargs` among them runs (nested
/// xargs too, up to `maxXargsDepth`): its program as written and with
/// every replace string swapped for the stdin stand-in, the stand-in
/// appended unless replace mode alone is in effect, re-fed through the
/// shared launcher resolver. When xargs's options do not parse exactly,
/// every word from one that names git (or is dynamic) on is taken as the
/// program (fail closed).
func followingXargs(_ launched: [LaunchedCommand]) -> [LaunchedCommand] {
    var out = launched
    var depths = Array(repeating: 0, count: launched.count)
    var index = 0
    while index < out.count {
        let (command, depth) = (out[index], depths[index])
        index += 1
        guard depth < maxXargsDepth, let head = command.guardArgv.first,
              xargsProgramNames.contains(commandName(head)) else { continue }
        for argv in xargsPrograms(Array(command.guardArgv.dropFirst())) {
            let fed = launchedCommandHeads(argv: argv, depth: depth + 1)
            out += fed
            depths += Array(repeating: depth + 1, count: fed.count)
        }
    }
    return out
}

private func xargsPrograms(_ words: [String]) -> [[String]] {
    guard let parsed = parseXargsOptions(words) else {
        return words.indices.filter { index in
            let word = unescapeBackslashPairs(words[index])
            return commandName(word) == "git" || word.hasPrefix("$")
        }.map { Array(words[$0...]) + [xargsStdinWord] }
    }
    guard let start = parsed.programStart else { return [] }
    let program = Array(words[start...])
    let stdin = parsed.appendsStdin ? [xargsStdinWord] : []
    var variants = [program + stdin]
    let substituted = substitutingReplaceStrings(parsed.replaceStrings, in: program)
    if substituted != program { variants.append(substituted + stdin) }
    return variants
}

/// xargs feeding xargs feeding…: past this, fail closed.
private let maxXargsDepth = 4

/// `xargs` runs its program with stdin words, and the launcher parser does
/// not follow it. The program is re-fed through the shared launcher
/// resolver (`sudo`/`env`/`nohup`/`timeout` prefixes, shell `-c`, `eval`,
/// dynamic heads, nested xargs), judged as written and with every replace
/// string swapped for the stdin stand-in; the stand-in is appended unless
/// replace mode alone is in effect. A dynamic head may be xargs too.
///
/// Fail closed rather than model xargs precisely: when the options do not
/// parse exactly (`parseXargsOptions` nil), for a literal, dynamic, or
/// glob head alike, the line is refused whenever any word could reach a
/// weakening rv invocation (`uncertainXargsMayReachRV`). A line with no
/// such word is left to the other stages, so the self-protection floor
/// does not mask their deny (`xargs --frobnicate rm -r` stays denied).
/// Relative to main this only adds refusals.
private func xargsFeedsWeakeningInvocation(_ launched: LaunchedCommand, depth: Int) -> Bool {
    guard let name = launched.guardArgv.first,
          launched.headIsDynamic || xargsProgramNames.contains(name) else { return false }
    guard depth < maxXargsDepth else { return true }
    let words = Array(launched.guardArgv.dropFirst())
    guard let parsed = parseXargsOptions(words) else {
        return uncertainXargsMayReachRV(words)
    }
    // No program: xargs runs echo.
    guard let start = parsed.programStart else { return false }
    let program = Array(words[start...])
    let stdin = parsed.appendsStdin ? [xargsStdinWord] : []
    var variants = [program + stdin]
    let substituted = substitutingReplaceStrings(parsed.replaceStrings, in: program)
    if substituted != program { variants.append(substituted + stdin) }
    return variants.contains { argv in
        scriptTakesStdin(argv) || splitStringTakesStdin(argv)
            || launchedCommandHeads(argv: argv, depth: depth + 1).contains { fed in
                fed.head.contains(xargsStdinWord) || launchWeakens(fed, xargsDepth: depth + 1)
            }
    }
}

/// A shell or `eval` with the stdin stand-in after it: xargs pastes stdin
/// into the script text (`xargs -I% sh -c 'echo %'` with stdin
/// `x; rv uninstall`), so stdin may run any command. Words are split at
/// whitespace and shell operators, once with quotes as separators and once
/// with quotes and backslashes removed, since one word may carry a command
/// line. Any later token counts, not only a `-c` payload, and the shell may
/// follow a wrapper: fail closed.
private func scriptTakesStdin(_ argv: [String]) -> Bool {
    let split = argv.flatMap { scriptTokens($0, separators: "'\";&|()<>`") }
    let joined = argv.flatMap { scriptTokens($0.filter { "'\"\\".contains($0) == false }, separators: ";&|()<>`") }
    return shellBeforeStdin(split) || shellBeforeStdin(joined)
}

private func scriptTokens(_ word: String, separators: String) -> [String] {
    word.split(whereSeparator: { $0.isWhitespace || separators.contains($0) }).map(String.init)
}

private let scriptRunnerNames: Set<String> = shellNames.union(["eval"])

private func shellBeforeStdin(_ tokens: [String]) -> Bool {
    guard let lastStdin = tokens.lastIndex(where: { $0.contains(xargsStdinWord) }) else { return false }
    return tokens[..<lastStdin].contains { scriptRunnerNames.contains(commandName($0)) }
}

/// `env -S` splits a string into a command line with its own quoting and
/// escapes (`s""h -c`, `sh\_-c`, `FOO=%`), which is not modelled. A
/// split-shaped option at or before the stdin stand-in is refused, whatever
/// program it follows (a copied or renamed `env` has another name): fail
/// closed.
private func splitStringTakesStdin(_ argv: [String]) -> Bool {
    guard let lastStdin = argv.lastIndex(where: { $0.contains(xargsStdinWord) }) else { return false }
    return argv[...lastStdin].contains(where: isSplitStringOption)
}

/// `-S`, a single-dash cluster holding `S` (`-vS`, `-Ssh`, `-iS`), or
/// `--split-string` and any abbreviation of it, with or without `=value`.
private func isSplitStringOption(_ word: String) -> Bool {
    let word = unescapeBackslashPairs(word)
    guard word.hasPrefix("-") else { return false }
    let name = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
    // A variable, substitution, glob, or the stand-in may spell `-S`
    // (`-$'\x53'`, `-?`, `--s*`, `-%` fed from stdin): fail closed.
    if isUnmodelledWord(String(name)) { return true }
    guard word.hasPrefix("--") else { return word.dropFirst().contains("S") }
    return name.count > 2 && "--split-string".hasPrefix(name)
}

/// Programs that may run a command their stdin or operands name.
private let xargsExecNames: Set<String> = plainLaunchers.union(shellNames).union([
    "sudo", "env", "timeout", "busybox", "eval", "stdbuf", "ionice", "xargs", "gxargs",
])

/// Words a weakening rv invocation needs literally (`isWeakeningVerb` /
/// `isWeakeningSub`): verbs, subcommands, and flags.
private let weakeningWords: Set<String> = subcommandVerbs.union([
    "uninstall", "setup", "--observe", "--save", "apply", "draft", "rollback", "disable", "add",
    "add-command", "redeem", "mint", "approve", "trust", "set", "remove", "import", "oauth-reset",
    "hook", "sign", "mode", "ceiling", "upload", "download",
])

/// Past this many words or characters, the uncertain scan (quadratic in
/// the worst case) is not attempted: fail closed.
private let maxUncertainXargsWords = 256
private let maxUncertainXargsCharacters = 4096

/// With options that do not parse, any word may be the program, a value,
/// or a replace string. rv is reached only through a literal rv program,
/// a program that runs other commands, or a replace string, so the line
/// is refused when any word is a weakening verb or flag, contains `rv`,
/// names such a program, is unmodelled, has no letter or digit (a
/// possible replace string in head position, `-` included), or when a
/// possible option value occurs again in a later word (`possibleOptionValues`).
private func uncertainXargsMayReachRV(_ words: [String]) -> Bool {
    if words.count > maxUncertainXargsWords
        || words.reduce(0, { $0 + $1.count }) > maxUncertainXargsCharacters {
        return true
    }
    let unescaped = words.map(unescapeBackslashPairs)
    for (index, word) in unescaped.enumerated() {
        if word == "--" { continue }
        let folded = foldedWord(word)
        if weakeningWords.contains(folded) || folded.contains("rv") { return true }
        if xargsExecNames.contains(commandName(word)) { return true }
        if isUnmodelledWord(word) || word.contains(where: { $0.isLetter || $0.isNumber }) == false { return true }
        guard word.hasPrefix("-") else { continue }
        if possibleOptionValues(word, at: index, in: unescaped).contains(where: { value, after in
            value.isEmpty == false && unescaped.dropFirst(after).contains { $0.contains(value) }
        }) {
            return true
        }
    }
    return false
}

/// (value, index of the first word after it) for each value an option word
/// may carry: an attached `=value`, every suffix of a short cluster after
/// its first letter (`-rIX` may name `IX` or `X`), and the next word. Each
/// such suffix ends in the cluster's last character, and a later word
/// holding a suffix holds that character, so the last character alone
/// stands for them all.
private func possibleOptionValues(_ word: String, at index: Int, in words: [String]) -> [(String, Int)] {
    var values: [(String, Int)] = []
    if let equals = word.firstIndex(of: "=") {
        values.append((String(word[word.index(after: equals)...]), index + 1))
    }
    if word.hasPrefix("--") == false, word.count > 2, let last = word.last {
        values.append((String(last), index + 1))
    }
    if index + 1 < words.count { values.append((words[index + 1], index + 2)) }
    return values
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
let rvProgramNames: Set<String> = ["rv", "rv-cli"]

let subcommandVerbs: Set<String> = [
    "packs", "safety", "allowlist", "allow-once", "policy", "egress", "mcp", "secrets", "managed", "host",
    "workspace", "protect", "pause",
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
    if headMayBeRV == false, isHelpPageRequest(rawArgv.dropFirst()) { return false }
    let args = rawArgv.dropFirst().map(foldedWord)
    guard let firstWord = args.firstIndex(where: { $0.hasPrefix("-") == false }) else { return false }
    // An option before the verb may take a value (`rv --config x uninstall`),
    // so any later word could be the verb.
    let verbIndexes = firstWord == 0 ? [firstWord] : args.indices.filter { args[$0].hasPrefix("-") == false }
    // Each candidate scans the tail: past a bound, fail closed instead of going quadratic.
    if verbIndexes.count > maxVerbCandidates { return true }
    return verbIndexes.contains { isWeakeningVerb(args, at: $0) }
}

/// `rv <verb> --help` or `rv <verb> <sub> --help`: rv prints the help page
/// and runs nothing, so an agent may read how a guarded command works. Only
/// one or two plain lowercase command words come before the help flag: no
/// option (whose value the flag could be), no `--`, no positional a
/// passthrough command could capture (`rv allow-once mint rm x --help`
/// mints), and nothing a shell expands. Anything else stays judged.
private func isHelpPageRequest(_ args: ArraySlice<String>) -> Bool {
    guard let last = args.last, last == "--help" || last == "-h" else { return false }
    let words = args.dropLast()
    guard (1...2).contains(words.count) else { return false }
    return words.allSatisfy { word in
        word.utf8.first.map { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) } == true
            && word.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || $0 == UInt8(ascii: "-") }
    }
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
        return sub == "disable" || sub == "off"
    case "protect":
        // `rv protect <tool> off` loosens; `off` may sit anywhere, and a
        // variable or glob may carry it. Adding protection only tightens.
        return sub == "off" || tail.contains { $0 == "off" || isUnmodelledWord($0) }
    case "safety":
        return sub != SafetyLevel.strict.rawValue
    case "allowlist":
        return sub == "add" || sub == "add-command"
    case "allow-once":
        return sub == "redeem" || sub == "mint" || isUnlockCode(sub)
    case "policy":
        // `draft --save` and `rollback --save` write the layer; a variable
        // or glob may carry the flag. Without it both are read-only previews.
        // `ceiling` replaces the owner's bound; only `show` (the default) reads.
        if sub == "ceiling" { return third.map { $0 != "show" } ?? false }
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
    case "workspace":
        // File transfer crosses the cage wall: `upload` reads host paths
        // into the workspace, `download` writes workspace files to the host.
        return sub == "upload" || sub == "download"
    case "pause":
        // `rv pause <duration>` watches every host; bare `rv pause` (the
        // countdown) and `rv pause --end` (back now) carry no positional.
        return true
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

/// Bare `rv allow-once <code>` redeems through the default subcommand. The
/// CLI trims and lowercases before `AllowOnceUnlockCode.isValid`, so the
/// guard does the same. Digit-only words of any length stay flagged as
/// before: loosening them buys nothing.
private func isUnlockCode(_ word: String) -> Bool {
    let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if AllowOnceUnlockCode.isValid(normalized) { return true }
    return word.isEmpty == false && word.allSatisfy(\.isNumber)
}
