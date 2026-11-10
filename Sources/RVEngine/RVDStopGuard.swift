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
        return speculativeTails(raw).contains { stops(argv: $0, context) }
    }

    private static let maxDepth = 4

    fileprivate static func nested(_ raw: String, _ context: StopContext) -> Bool {
        stopsRVD(raw, depth: context.depth + 1)
    }
}

/// Facts about the whole command that one launched `kill` cannot see.
private struct StopContext {
    let raw: String
    let launched: [LaunchedCommand]
    let depth: Int

    /// Whether the command looks up rvd's pid: it names rvd, rv's label or
    /// its socket, or runs a `pgrep`/`pidof` that may select rvd.
    var looksUpRVD: Bool {
        let folded = raw.folding(options: .caseInsensitive, locale: nil)
        if rvdMentions.contains(where: { folded.contains($0) }) { return true }
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
    default: return false
    }
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

// MARK: launchd

private let launchctlStopVerbs: Set<String> = ["bootout", "unload", "remove", "kill", "disable", "stop"]
private let launchdDomains: Set<String> = ["gui", "user", "login", "session", "pid"]

private func launchctlStops(_ args: [String], _ context: StopContext) -> Bool {
    let folded = args.map(foldedWord)
    return verbIndexes(folded).contains { index in
        let verb = folded[index]
        if verb == "asuser" || verb == "bsexec" {
            // `launchctl asuser <uid> <command…>` runs a command.
            let rest = args.dropFirst(index + 2)
            return rest.contains(where: isDynamic) || RVDStopGuard.nested(rest.joined(separator: " "), context)
        }
        guard isUnmodelled(verb) || launchctlStopVerbs.contains(verb) else { return false }
        var targets = folded[(index + 1)...].filter { $0.hasPrefix("-") == false }
        // An unmodelled verb may word-split into a verb and its target.
        if targets.isEmpty { return isUnmodelled(verb) }
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
    return verbIndexes(folded).contains { index in
        let verb = folded[index]
        if systemctlManagerVerbs.contains(verb) { return true }
        guard isUnmodelled(verb) || systemctlStopVerbs.contains(verb) else { return false }
        let units = folded[(index + 1)...].filter { $0.hasPrefix("-") == false }
        if units.isEmpty { return isUnmodelled(verb) }
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
    var selectsByOption = false
    var negated = false
    var fullCommandLine = false
    var regex = false
}

private func parseSelection(
    _ args: [String], valued: Set<Character>, selecting: Set<Character>, longValued: Set<String>,
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
            if ["--euid", "--uid", "--group", "--pgroup", "--parent", "--session", "--terminal",
                "--pidfile", "--user", "--cgroup", "--ns"].contains(name) {
                selection.selectsByOption = true
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

private let pkillLongValued: Set<String> = [
    "--signal", "--euid", "--uid", "--group", "--pgroup", "--parent", "--session", "--terminal",
    "--pidfile", "--ns", "--nslist", "--older", "--runstates", "--cgroup", "--env",
]

/// Whether `pkill args` (or `pgrep args`) may select rvd.
private func pkillSelectsRVD(_ args: [String]) -> Bool {
    let selection = parseSelection(
        args, valued: ["F", "G", "g", "J", "M", "N", "P", "s", "t", "U", "u", "d"],
        selecting: ["F", "G", "g", "J", "P", "s", "t", "U", "u"], longValued: pkillLongValued
    ) { letter, selection in
        if letter == "f" { selection.fullCommandLine = true }
        if letter == "v" { selection.negated = true }
    }
    if selection.negated { return true }
    if selection.names.isEmpty { return selection.selectsByOption }
    return selection.words.contains { word in
        isDynamic(word) || patternMatchesRVD(word, fullCommandLine: selection.fullCommandLine)
    }
}

/// Whether `killall args` (or `pidof args`) may select rvd.
private func killallSelectsRVD(_ args: [String]) -> Bool {
    let selection = parseSelection(
        args, valued: ["u", "t", "s", "o", "y", "n", "Z"], selecting: ["u", "t"],
        longValued: ["--signal", "--user", "--older-than", "--younger-than", "--ns", "--context"]
    ) { letter, selection in
        if letter == "m" || letter == "r" { selection.regex = true }
    }
    if selection.names.isEmpty { return selection.selectsByOption }
    return selection.words.contains { word in
        if isUnmodelled(word) && selection.regex == false { return true }
        if isDynamic(word) { return true }
        if selection.regex { return patternMatchesRVD(word, fullCommandLine: false) }
        return commandName(word) == "rvd"
    }
}

/// `pkill`/`pgrep` patterns are extended regexes searched in the process
/// name (or full command line with `-f`). An invalid pattern fails closed.
private func patternMatchesRVD(_ pattern: String, fullCommandLine: Bool) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return true }
    let subjects = ["rvd"] + (fullCommandLine ? rvdCommandLines : [])
    return subjects.contains { subject in
        regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }
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
        guard isDynamic(operand) else { return false }
        if ["$!", "${!}", "$$"].contains(operand) { return false }
        return context.looksUpRVD
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

private func rawSegments(_ raw: String) -> [[String]] {
    var segments: [[String]] = []
    var words: [String] = []
    var current = ""
    func endWord() {
        if current.isEmpty == false { words.append(current) }
        current = ""
    }
    for char in raw {
        if ";|&\n()".contains(char) {
            endWord()
            segments.append(words)
            words = []
        } else if " \t\r'\"<>,`".contains(char) {
            endWord()
        } else {
            current.append(char)
        }
    }
    endWord()
    segments.append(words)
    return segments
}
