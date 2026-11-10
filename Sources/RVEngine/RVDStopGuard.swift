import Foundation
import RVDomain

/// The agent rv guards must not stop rvd.
///
/// With rvd unreachable, a host in observe mode allows every later call
/// unchecked, so an agent that stops rvd sheds all oversight. `stopsRVD` is
/// true when any launched command:
/// - runs `launchctl bootout|unload|remove|kill|disable|stop` on a target
///   that may be rv's (`dev.rv.*`, a whole domain, a plist path or
///   directory, an unmodelled word), or `launchctl asuser|bsexec` such a
///   command;
/// - runs `systemctl stop|disable|mask|kill|restart|…` on a unit that may be
///   rv's, or a verb that stops every unit (`isolate`, `exit`, …);
/// - runs `pkill`/`killall` with a pattern or name that may match rvd, or a
///   selection (`-u`, `-v`) with no name;
/// - runs `kill` on pid `-1`, or with pids read from a lookup that names
///   rvd (`kill $(pgrep rvd)`, `pgrep rvd | xargs kill`);
/// - launches `rvd` (a second rvd unlinks the live socket).
///
/// A dynamic head is judged as each of these programs, and the words after
/// any of their names in the raw text are judged too, so a launcher the
/// parser does not model (`find -exec`, `xargs`, an inline program) still
/// counts. Unmodelled words (`$`, backticks, globs) fail closed. `kill`
/// with a numeric pid, or a pid in a variable or file, cannot be resolved
/// and is not flagged.
public enum RVDStopGuard {
    public static func stopsRVD(_ raw: String) -> Bool {
        stopsRVD(raw, depth: 0)
    }

    private static func stopsRVD(_ raw: String, depth: Int) -> Bool {
        guard depth < maxDepth else { return true }
        let launched = launchedCommandHeads(raw)
        let context = StopContext(raw: raw, launched: launched, depth: depth)
        if launched.contains(where: { stops($0, context) }) { return true }
        if speculativeTails(raw).contains(where: { stops(argv: $0, context) }) { return true }
        return echoFedShellStops(raw, depth: depth)
    }

    private static let maxDepth = 4

    fileprivate static func nested(_ raw: String, _ context: StopContext) -> Bool {
        stopsRVD(raw, depth: context.depth + 1)
    }

    fileprivate static func nestedText(_ raw: String, depth: Int) -> Bool {
        stopsRVD(raw, depth: depth + 1)
    }
}

/// `echo`/`printf` text is inert, unless its pipe consumer is a shell or a
/// scheduler that runs it (`sh`, `bash`, `zsh`, `dash`, `at`, `batch`,
/// `crontab`). Then the echoed string is a command: evaluate it.
/// `echo "pkill rvd" | sh`, `… echo '* * * * * pkill rvd' … | crontab -`.
private let shellConsumers: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "at", "batch", "crontab"]

private func echoFedShellStops(_ raw: String, depth: Int) -> Bool {
    let segments = rawSegments(raw).filter { $0.isEmpty == false }
    guard segments.contains(where: { shellConsumers.contains(commandName($0[0])) }) else { return false }
    for segment in segments where ["echo", "printf"].contains(commandName(segment[0])) {
        let text = segment.dropFirst().filter { $0.hasPrefix("-") == false }.joined(separator: " ")
        if text.isEmpty == false, RVDStopGuard.nestedText(text, depth: depth) { return true }
    }
    return false
}

/// Facts about the whole command that one launched `kill` cannot see.
private struct StopContext {
    let raw: String
    let launched: [LaunchedCommand]
    let depth: Int

    /// Whether the command looks up rvd's pid: it names rvd, rv's label or
    /// its socket, or runs a `pgrep`/`pidof` that may select rvd. The text
    /// is folded (`[r]vd` → `rvd`, quotes stripped so `'r''vd'` → `rvd`)
    /// before the mention check, and grep/awk regexes are tested against
    /// rvd's names, so a pipeline that hides the name still counts.
    var looksUpRVD: Bool {
        let folded = foldHiddenMentions(raw)
        if rvdMentions.contains(where: { folded.contains($0) }) { return true }
        if pipelinePatterns(raw).contains(where: patternMatchesRVDName) { return true }
        return launched.contains { command in
            guard command.truncated == false, let program = command.guardArgv.first else { return false }
            let args = Array(command.guardArgv.dropFirst())
            switch program {
            case "pgrep": return pkillSelectsRVD(args)
            case "pidof": return killallSelectsRVD(args)
            default: return false
            }
        }
    }
}

/// `[r]vd` → `rvd`, quote marks dropped, case-folded: a `grep '[r]vd'` or
/// `'r''vd'` no longer hides the name from a substring check.
func foldHiddenMentions(_ raw: String) -> String {
    var out = ""
    let chars = Array(raw)
    var index = 0
    while index < chars.count {
        // A single-character class `[x]` matches the literal `x`.
        if chars[index] == "[", index + 2 < chars.count, chars[index + 2] == "]" {
            out.append(chars[index + 1])
            index += 3
            continue
        }
        if chars[index] != "'", chars[index] != "\"" { out.append(chars[index]) }
        index += 1
    }
    return out.folding(options: .caseInsensitive, locale: nil)
}

/// The search regexes of grep/awk stages, to test against rvd's names. For
/// `grep` the first non-option operand is the pattern; for `awk`/`sed` only
/// `/…/`-delimited spans are patterns (an action body like `{print $2}` is
/// not a regex, so it is never compiled and cannot fail closed).
private func pipelinePatterns(_ raw: String) -> [String] {
    var patterns: [String] = []
    for segment in rawSegments(raw) where segment.isEmpty == false {
        let program = commandName(segment[0])
        if ["grep", "egrep", "fgrep", "rg"].contains(program) {
            // The first bare operand is the pattern; the rest are filenames.
            if let pattern = segment.dropFirst().first(where: { $0.hasPrefix("-") == false }) {
                patterns.append(pattern)
            }
        } else if program == "awk" || program == "sed" {
            for word in segment.dropFirst() {
                var rest = Substring(word)
                while let open = rest.firstIndex(of: "/"),
                      let close = rest[rest.index(after: open)...].firstIndex(of: "/") {
                    patterns.append(String(rest[rest.index(after: open)..<close]))
                    rest = rest[rest.index(after: close)...]
                }
            }
        }
    }
    return patterns
}

/// rvd's process name and launchd/systemd labels, for regex tests.
private let rvdNameSubjects = ["rvd", "dev.rv.evaluate", "dev.rv.mcp-custodian", "dev.rv.audit-forward"]

private func patternMatchesRVDName(_ pattern: String) -> Bool {
    guard pattern.isEmpty == false else { return false }
    return boundedRegexMatches(pattern, subjects: rvdNameSubjects)
}

private let rvdMentions = ["rvd", "dev.rv", "evaluate.sock"]

private let lifecyclePrograms = ["launchctl", "systemctl", "pkill", "killall", "kill"]

private func stops(_ command: LaunchedCommand, _ context: StopContext) -> Bool {
    // Truncated input is already flagged by `SelfProtectionGuard`.
    guard command.truncated == false else { return false }
    let argv = command.guardArgv
    guard command.headIsDynamic else { return stops(argv: argv, context) }
    // A bare dynamic head is a residual shared with the rv admin floor.
    guard argv.count > 1 else { return false }
    let args = Array(argv.dropFirst())
    return lifecyclePrograms.contains { stops(argv: [$0] + args, context) }
}

private func stops(argv: [String], _ context: StopContext) -> Bool {
    guard let head = argv.first else { return false }
    let args = argv.dropFirst().map(unescapeBackslashPairs)
    switch commandName(head) {
    case "rvd": return true
    case "launchctl": return launchctlStops(args, context)
    case "systemctl": return systemctlStops(args, context)
    case "pkill": return pkillSelectsRVD(args)
    case "killall": return killallSelectsRVD(args)
    case "kill": return killStops(args, context)
    case "xargs": return xargsStops(args, context)
    case "busctl", "gdbus", "dbus-send", "systemd-run", "loginctl":
        // Linux D-Bus / systemd manager calls that name rv's bus or unit.
        let folded = context.raw.folding(options: .caseInsensitive, locale: nil)
        return folded.contains("systemd1") || folded.contains("dev.rv")
    default: return false
    }
}

/// `xargs <program> [args]` runs `program` with the words from stdin
/// appended. The program is judged with the inline args it carries (the
/// stdin words make an operand-less stop still stop). `xargs` options and
/// their values are skipped first.
private func xargsStops(_ args: [String], _ context: StopContext) -> Bool {
    var index = 0
    let valued: Set<String> = ["-I", "-i", "-n", "-L", "-P", "-s", "-E", "-e", "-d", "-a", "--max-args",
                               "--max-procs", "--max-lines", "--replace", "--delimiter", "--arg-file"]
    while index < args.count {
        let word = args[index]
        guard word.hasPrefix("-") else { break }
        // `-I {}` / `-n 1` take the next word; `-I{}` / `-n1` carry it attached.
        index += valued.contains(word) ? 2 : 1
    }
    let rest = Array(args[index...])
    guard rest.isEmpty == false else { return false }
    return stops(argv: rest, context)
}

/// `$X`, backticks, globs and braces: the word's runtime value is unknown.
private func isUnmodelled(_ word: String) -> Bool {
    word.contains(where: { "$`*?[{".contains($0) })
}

private func isDynamic(_ word: String) -> Bool {
    word.contains(where: { $0 == "$" || $0 == "`" })
}

/// Option words before the verb may take values, so then every later
/// non-option word may be the verb (the rv admin floor does the same).
private func verbIndexes(_ folded: [String]) -> [Int] {
    guard let first = folded.firstIndex(where: { $0.hasPrefix("-") == false }) else { return [] }
    if first == 0 { return [0] }
    return folded.indices.filter { folded[$0].hasPrefix("-") == false }
}

/// A verb-candidate × target scan is quadratic; past this bound fail closed
/// instead, matching `SelfProtectionGuard`'s `maxVerbCandidates`. A 16 KB
/// `launchctl` word list no longer runs for seconds.
private let maxVerbCandidates = 256

/// Whether a huge word list should fail closed before the quadratic scan.
private func verbScanOverflows(_ folded: [String]) -> Bool {
    verbIndexes(folded).count > maxVerbCandidates
}

// MARK: launchd

private let launchctlStopVerbs: Set<String> = ["bootout", "unload", "remove", "kill", "disable", "stop"]
private let launchdDomains: Set<String> = ["gui", "user", "login", "session", "pid"]

private func launchctlStops(_ args: [String], _ context: StopContext) -> Bool {
    let folded = args.map(foldedWord)
    if verbScanOverflows(folded) { return true }
    return verbIndexes(folded).contains { index in
        let verb = folded[index]
        if verb == "asuser" || verb == "bsexec" {
            // `launchctl asuser <uid> <command…>` runs a command.
            let rest = args.dropFirst(index + 2)
            return rest.contains(where: isDynamic) || RVDStopGuard.nested(rest.joined(separator: " "), context)
        }
        // `kickstart -k` restarts the job, killing the running instance.
        if verb == "kickstart", args.contains(where: { foldedWord($0) == "-k" }) {
            let targets = folded[(index + 1)...].filter { $0.hasPrefix("-") == false }
            return targets.contains(where: launchdTargetMayBeRV)
        }
        guard isUnmodelled(verb) || launchctlStopVerbs.contains(verb) else { return false }
        var targets = folded[(index + 1)...].filter { $0.hasPrefix("-") == false }
        // No inline target: a stop verb is fed one from stdin (`xargs launchctl
        // bootout`), so it holds; an unmodelled verb may be a split word.
        if targets.isEmpty { return true }
        // `bootout <domain> <path…>` stops the listed jobs, not the domain.
        if targets.count > 1, isDomainOnly(targets[0]) { targets.removeFirst() }
        return targets.contains(where: launchdTargetMayBeRV)
    }
}

/// A target names another job only as a `<domain>/<label>` service target
/// or a bare label. A plist is opaque (launchd stops its `Label`, wherever
/// the file lives), and a directory or whole domain holds rv's job.
private func launchdTargetMayBeRV(_ target: String) -> Bool {
    if isUnmodelled(target) || target.contains("dev.rv") { return true }
    if target == "system" || isDomainOnly(target) { return true }
    let parts = target.split(separator: "/", omittingEmptySubsequences: false)
    if let domain = parts.first, launchdDomains.contains(String(domain)) || domain == "system" {
        return parts.count > 3 || parts.last?.isEmpty == true
    }
    return target.contains("/") || target.hasSuffix(".plist")
}

private func isDomainOnly(_ target: String) -> Bool {
    let parts = target.split(separator: "/", omittingEmptySubsequences: false)
    guard let domain = parts.first, launchdDomains.contains(String(domain)) else { return false }
    return parts.count == 2 || (parts.count == 3 && parts[2].isEmpty)
}

// MARK: systemd

private let systemctlStopVerbs: Set<String> = [
    "stop", "disable", "mask", "kill", "restart", "try-restart", "reload-or-restart",
    "try-reload-or-restart", "condrestart", "force-reload", "reenable", "link", "revert",
    "edit", "set-property", "preset", "freeze", "clean",
]

/// Verbs that stop or reconfigure every unit, rv's included.
private let systemctlManagerVerbs: Set<String> = [
    "isolate", "exit", "set-environment", "unset-environment", "import-environment",
    "halt", "poweroff", "reboot", "kexec", "soft-reboot", "default", "rescue", "emergency",
    "switch-root", "preset-all",
]

private func systemctlStops(_ args: [String], _ context: StopContext) -> Bool {
    let folded = args.map(foldedWord)
    if verbScanOverflows(folded) { return true }
    return verbIndexes(folded).contains { index in
        let verb = folded[index]
        if systemctlManagerVerbs.contains(verb) { return true }
        guard isUnmodelled(verb) || systemctlStopVerbs.contains(verb) else { return false }
        let units = folded[(index + 1)...].filter { $0.hasPrefix("-") == false }
        // No inline unit: fed from stdin under `xargs`, so a stop verb holds.
        if units.isEmpty { return true }
        return units.contains { isUnmodelled($0) || $0.contains("dev.rv") }
    }
}

// MARK: signals

/// What a `pkill -f` pattern is matched against: rvd's full command line.
private let rvdCommandLines = ["/Users/u/.local/bin/rvd --socket", "/home/u/.local/bin/rvd --socket"]

private let signalNames: Set<String> = [
    "hup", "int", "quit", "ill", "trap", "abrt", "iot", "emt", "fpe", "kill", "bus", "segv", "sys",
    "pipe", "alrm", "term", "urg", "stop", "tstp", "cont", "chld", "ttin", "ttou", "io", "xcpu",
    "xfsz", "vtalrm", "prof", "winch", "info", "usr1", "usr2", "pwr", "stkflt", "poll",
]

/// `-9`, `-KILL`, `-SIGKILL`: a signal, not an option cluster.
private func isSignalOption(_ word: String) -> Bool {
    guard word.hasPrefix("-"), word.hasPrefix("--") == false, word.count > 1 else { return false }
    let body = word.dropFirst().lowercased()
    if body.allSatisfy(\.isNumber) { return true }
    let name = body.hasPrefix("sig") ? String(body.dropFirst(3)) : body
    return signalNames.contains(name) || (name.hasPrefix("rtm") && body.count > 3)
}

/// Selection words of one `pkill`/`killall`/`pgrep`/`pidof` invocation.
private struct SignalSelection {
    /// Every non-option word, option values included (fail closed).
    var words: [String] = []
    /// Non-option words that are not values of a valued option.
    var names: [String] = []
    /// A user/negation option (`-u`, `-U`, `-v`) that alone selects rvd.
    var selectsByOption = false
    /// Any narrowing option at all (`-P`, `-g`, `-t`, `-F`, …): a deliberate
    /// selection, not an operand-less invocation fed from stdin.
    var sawSelectionOption = false
    /// An informational flag (`-l`, `-V`, `--help`): never kills.
    var informational = false
    var negated = false
    var fullCommandLine = false
    var regex = false
}

private let selectionLongOptions: Set<String> = [
    "--euid", "--uid", "--group", "--pgroup", "--parent", "--session", "--terminal",
    "--pidfile", "--user", "--cgroup", "--ns", "--runstates",
]

private func parseSelection(
    _ args: [String], valued: Set<Character>, selecting: Set<Character>,
    narrowing: Set<Character>, longValued: Set<String>,
    flags: (Character, inout SignalSelection) -> Void
) -> SignalSelection {
    var selection = SignalSelection()
    var index = 0
    var optionsEnded = false
    func takeValue(at next: Int) {
        guard next < args.count else { return }
        selection.words.append(args[next])
    }
    while index < args.count {
        let word = args[index]
        index += 1
        if optionsEnded || word.hasPrefix("-") == false || word == "-" {
            selection.words.append(word)
            selection.names.append(word)
            continue
        }
        if word == "--" { optionsEnded = true; continue }
        if isSignalOption(word) { continue }
        if word.hasPrefix("--") {
            let name = String(word.prefix { $0 != "=" }).lowercased()
            if name == "--full" { selection.fullCommandLine = true }
            if name == "--inverse" { selection.negated = true }
            if name == "--regexp" { selection.regex = true }
            if ["--help", "--version", "--list-name", "--list-full"].contains(name) { selection.informational = true }
            if selectionLongOptions.contains(name) {
                selection.sawSelectionOption = true
                if ["--uid", "--euid", "--user"].contains(name) { selection.selectsByOption = true }
            }
            if word.contains("=") == false, longValued.contains(name) {
                takeValue(at: index)
                index += 1
            }
            continue
        }
        let letters = Array(word.dropFirst())
        for (offset, letter) in letters.enumerated() {
            flags(letter, &selection)
            if letter == "l" || letter == "V" || letter == "h" { selection.informational = true }
            if narrowing.contains(letter) { selection.sawSelectionOption = true }
            if selecting.contains(letter) { selection.selectsByOption = true }
            guard valued.contains(letter) else { continue }
            if offset == letters.count - 1 {
                takeValue(at: index)
                index += 1
            }
            break
        }
    }
    return selection
}

/// A `pkill`/`killall` with no name pattern: holds when it is fed from
/// stdin (operand-less, as under `xargs`) or selects by user/negation;
/// a deliberate narrowing (`-P $$`) or an informational flag does not.
private func operandLessSelectsRVD(_ selection: SignalSelection) -> Bool {
    if selection.negated || selection.selectsByOption { return true }
    if selection.sawSelectionOption || selection.informational { return false }
    return true
}

private let pkillLongValued: Set<String> = [
    "--signal", "--euid", "--uid", "--group", "--pgroup", "--parent", "--session", "--terminal",
    "--pidfile", "--ns", "--nslist", "--older", "--runstates", "--cgroup", "--env",
]

/// Whether `pkill args` (or `pgrep args`) may select rvd. When a name
/// pattern is present it decides (a `-u`/`-P` only narrows it); with no
/// name, a user/negation selection or an operand-less stdin feed holds.
private func pkillSelectsRVD(_ args: [String]) -> Bool {
    let selection = parseSelection(
        args, valued: ["F", "G", "g", "J", "M", "N", "P", "s", "t", "U", "u", "d"],
        selecting: ["U", "u"], narrowing: ["F", "G", "g", "J", "M", "N", "P", "s", "t", "U", "u"],
        longValued: pkillLongValued
    ) { letter, selection in
        if letter == "f" { selection.fullCommandLine = true }
        if letter == "v" { selection.negated = true }
    }
    if selection.negated { return true }
    if selection.names.isEmpty { return operandLessSelectsRVD(selection) }
    return selection.names.contains { name in
        isDynamic(name) || patternMatchesRVD(name, fullCommandLine: selection.fullCommandLine)
    }
}

/// Whether `killall args` (or `pidof args`) may select rvd.
private func killallSelectsRVD(_ args: [String]) -> Bool {
    let selection = parseSelection(
        args, valued: ["u", "t", "s", "o", "y", "n", "Z"], selecting: ["u"], narrowing: ["u", "t"],
        longValued: ["--signal", "--user", "--older-than", "--younger-than", "--ns", "--context"]
    ) { letter, selection in
        if letter == "m" || letter == "r" { selection.regex = true }
    }
    if selection.names.isEmpty { return operandLessSelectsRVD(selection) }
    return selection.names.contains { name in
        if isUnmodelled(name) && selection.regex == false { return true }
        if isDynamic(name) { return true }
        if selection.regex { return patternMatchesRVD(name, fullCommandLine: false) }
        return commandName(name) == "rvd"
    }
}

/// `pkill`/`pgrep` patterns are extended regexes searched in the process
/// name (or full command line with `-f`). With `-f`, a pattern whose text
/// just mentions rvd counts even if the regex would not match the sample
/// command lines (`pkill -f 'bob.*rvd'`). An invalid pattern fails closed.
private func patternMatchesRVD(_ pattern: String, fullCommandLine: Bool) -> Bool {
    if fullCommandLine {
        let folded = pattern.folding(options: .caseInsensitive, locale: nil)
        if folded.contains("rvd") || folded.contains("dev.rv") { return true }
    }
    let subjects = ["rvd"] + (fullCommandLine ? rvdCommandLines : [])
    return boundedRegexMatches(pattern, subjects: subjects)
}

/// A regex match with a hard bound on agent-supplied patterns.
///
/// `NSRegularExpression` has no evaluation time limit, and a pattern with a
/// quantified group, alternation inside a quantifier, or a backreference
/// can backtrack for seconds on a short subject (`(.|.)+X` with `-f`). Such
/// a pattern — or any over `maxPatternLength` — fails closed (treated as a
/// match) without ever being run. Otherwise the bounded pattern runs on the
/// short, fixed subjects.
func boundedRegexMatches(_ pattern: String, subjects: [String]) -> Bool {
    if pattern.count > maxPatternLength || isCatastrophicPattern(pattern) { return true }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return true }
    return subjects.contains { subject in
        regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }
}

private let maxPatternLength = 128

/// A pattern whose backtracking could blow up: a quantifier on a group, an
/// alternation inside a group, or a backreference. Conservative: any of
/// these makes the pattern fail closed rather than run.
func isCatastrophicPattern(_ pattern: String) -> Bool {
    let chars = Array(pattern)
    var escaped = false
    var groupDepth = 0
    var alternationDepth = Set<Int>()
    for index in chars.indices {
        let char = chars[index]
        if escaped {
            // A backreference (`\1`…`\9`) can force exponential rematching.
            if char.isNumber { return true }
            escaped = false
            continue
        }
        switch char {
        case "\\":
            escaped = true
        case "(":
            groupDepth += 1
        case ")":
            if alternationDepth.contains(groupDepth) {
                // An alternation inside this group; if quantified, blow up.
                let next = index + 1
                if next < chars.count, "*+?{".contains(chars[next]) { return true }
            }
            alternationDepth.remove(groupDepth)
            groupDepth -= 1
        case "|":
            if groupDepth > 0 { alternationDepth.insert(groupDepth) }
        case "*", "+", "{":
            // A quantifier applied to a group close is handled above; a
            // nested-quantifier group like `(a+)+` is caught here.
            if index > 0, chars[index - 1] == ")" { return true }
        default:
            break
        }
    }
    return false
}

/// `kill -1` signals every process the user owns; pids from a lookup that
/// may select rvd (`$(pgrep rvd)`, `pgrep rvd | xargs kill`) are rvd's.
private func killStops(_ args: [String], _ context: StopContext) -> Bool {
    if args.contains(where: { $0 == "-l" || $0 == "-L" }) { return false }
    var index = 0
    if let first = args.first, first.hasPrefix("-"), first != "--", first != "-1" || args.count > 1 {
        index = first == "-s" || first == "-n" ? 2 : 1
    }
    var operands = Array(args.dropFirst(index))
    if operands.first == "--" { operands.removeFirst() }
    // No pids: they come from stdin (`… | xargs kill`).
    if operands.isEmpty { return context.looksUpRVD }
    return operands.contains { operand in
        if operand == "-1" || commandName(operand) == "rvd" { return true }
        if isDynamic(operand) {
            if ["$!", "${!}", "$$"].contains(operand) { return false }
            return context.looksUpRVD
        }
        // A non-numeric operand is an `xargs -I` placeholder (`{}`, `%`)
        // filled from stdin, not a literal pid.
        if operand.allSatisfy(\.isNumber) == false { return context.looksUpRVD }
        return false
    }
}

// MARK: unmodelled launchers

/// Words after any lifecycle program name in the raw text, segment by
/// segment, so `find -exec`, `xargs`, `asuser` or an inline program that
/// runs one is still judged. Quotes split words; shell punctuation splits
/// segments. A segment led by a program that only prints or searches
/// (`echo`, `grep`) is text, not a command.
private func speculativeTails(_ raw: String) -> [[String]] {
    var tails: [[String]] = []
    for segment in rawSegments(raw) where segment.isEmpty == false {
        let inert = textHeads.contains(commandName(segment[0]))
        for (index, word) in segment.enumerated() where lifecyclePrograms.contains(commandName(word)) {
            if inert && index > 0 { continue }
            tails.append(Array(segment[index...]))
        }
    }
    return tails
}

private let textHeads: Set<String> = [
    "echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "ack", "cat", "ls", "head", "tail",
    "wc", "less", "more", "man", "which", "type", "file", "stat", "jq", "diff", "test", "[",
]

/// Quote-aware so a quoted argument stays one word: a `pkill -f 'rails s'`
/// pattern or a `git commit -m '… pkill rvd …'` message is not re-split into
/// a `pkill` command. Adjacent quotes (`'r''vd'`) still concatenate, since
/// the quote mark itself is not a separator.
private func rawSegments(_ raw: String) -> [[String]] {
    var segments: [[String]] = []
    var words: [String] = []
    var current = ""
    var quote: Character?
    func endWord() {
        if current.isEmpty == false { words.append(current) }
        current = ""
    }
    for char in raw {
        if let active = quote {
            if char == active { quote = nil } else { current.append(char) }
        } else if char == "'" || char == "\"" {
            quote = char
        } else if ";|&\n()".contains(char) {
            endWord()
            segments.append(words)
            words = []
        } else if " \t\r<>,`".contains(char) {
            endWord()
        } else {
            current.append(char)
        }
    }
    endWord()
    segments.append(words)
    return segments
}
