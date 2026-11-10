import Foundation

/// rvd ignores its launch environment for every posture knob except a
/// tighten-only `RV_GUARD_MODE=enforce`, and must stay running to guard
/// anything. An agent command that edits the
/// launchd/systemd user environment for `RV_*`, or that stops, unloads,
/// restarts or kills rv's own service (labels and units named `dev.rv.*`,
/// the `rvd` process), weakens rv exactly like `rv uninstall`.
///
/// A dynamic head (`$L setenv ...`) may be any of these programs, and an
/// unmodelled operand (`$X`, glob) where the target is decided fails
/// closed. Once an rv label or `RV_*` name appears, every launchctl verb
/// outside a read-only allowlist is flagged (`asuser`/`bsexec` run their
/// inner command as judged here). An unmodelled launcher before a kill or
/// service tool (`xargs kill`, `caffeinate pkill`, `find -exec kill`) is
/// flagged, and so is a literal `kill` of rvd's pid at evaluation time or
/// of every process (`kill -9 -1`). Read-only forms (`launchctl
/// list|print|getenv`, `systemctl status`, `pgrep rvd`) and other services
/// pass.
func retunesOrStopsRVService(_ launched: [LaunchedCommand], rvdPIDs: () -> Set<Int32>?) -> Bool {
    let argvs = launched.map { (words: $0.guardArgv.map(foldedWord), dynamic: $0.headIsDynamic) }
    for (words, dynamic) in argvs {
        guard let program = words.first.map(programName) else { continue }
        let args = Array(words.dropFirst())
        if dynamic {
            // A dynamic head may be any of these. Verb-keyed launchctl and
            // systemctl forms are judged in full; a pattern kill only when an
            // operand names rvd outright (`$GO build ./...` is not a pkill).
            if launchctlWeakens(args) || systemctlWeakens(args) { return true }
            if args.contains(where: { $0 == "rv" || $0.contains("rvd") }) { return true }
            continue
        }
        if isServiceWeakening(program, args) { return true }
        if launchesServiceTool(program, args) { return true }
        if program == "kill", killsRVDByPid(args, rvdPIDs: rvdPIDs) { return true }
    }
    // `kill $(pgrep rvd)`, `pgrep rvd | xargs kill`: a pid lookup of rvd
    // feeding a kill in the same command line.
    let kills = argvs.contains { $0.words.first == "kill" || ($0.words.first == "xargs" && $0.words.contains("kill")) }
    let looksUpRVD = argvs.contains { entry in
        guard let program = entry.words.first, program == "pgrep" || program == "pidof" else { return false }
        return patternOperandsMayMatchRV(Array(entry.words.dropFirst()))
    }
    return kills && looksUpRVD
}

private func programName(_ word: String) -> String {
    word.split(separator: "/").last.map(String.init) ?? word
}

/// Kill and service tools a launcher may run.
private let serviceTools: Set<String> = ["kill", "pkill", "killall", "launchctl", "systemctl"]

/// Launchers the launcher parser does not unwrap: their operands may be a
/// command line run as given.
private let unmodelledLaunchers: Set<String> = [
    "xargs", "find", "script", "caffeinate", "arch", "watch", "parallel", "flock", "setsid", "stdbuf",
    "unbuffer", "chronic", "ionice", "taskpolicy", "su", "runuser", "sg", "chroot", "entr", "expect",
    "osascript", "tmux", "screen", "ssh-agent", "dbus-run-session", "systemd-run",
]

/// Heads whose operands are text, never a command line.
private let textOnlyHeads: Set<String> = [
    "echo", "printf", "git", "gh", "grep", "egrep", "fgrep", "rg", "ag", "man", "which", "type", "whereis",
    "whatis", "apropos", "cat", "less", "more", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "jq",
]

/// An unmodelled launcher with a kill/service tool among its operands
/// (`xargs kill`, `caffeinate -i pkill node`), or any command whose
/// operands carry a kill tool aimed at an rv process (`unbuffer pkill
/// rvd`). Operands are also split at whitespace and quotes, so a command
/// string (`osascript -e 'do shell script "pkill rvd"'`) counts.
private func launchesServiceTool(_ program: String, _ args: [String]) -> Bool {
    guard textOnlyHeads.contains(program) == false, serviceTools.contains(program) == false else { return false }
    let words = args.flatMap { $0.split(whereSeparator: { " \t\n'\";".contains($0) }).map(String.init) }
        .map(programName)
    guard let toolIndex = words.firstIndex(where: serviceTools.contains) else { return false }
    if unmodelledLaunchers.contains(program) { return true }
    return isServiceWeakening(words[toolIndex], Array(words[(toolIndex + 1)...]))
}

/// `kill` operands after the signal: a literal pid that is rvd's now, or
/// `-1` (every process this user may signal, rvd included). An unknown
/// rvd pid set fails closed on any literal pid.
private func killsRVDByPid(_ args: [String], rvdPIDs: () -> Set<Int32>?) -> Bool {
    var operands = args
    if let first = operands.first, first.hasPrefix("-"), first != "--" {
        operands.removeFirst()
        if first == "-s" || first == "-n" { operands = Array(operands.dropFirst()) }
    }
    let pids = operands.filter { $0 != "--" }.compactMap { Int32($0) }
    if pids.contains(-1) { return true }
    let positive = pids.filter { $0 > 0 }
    guard positive.isEmpty == false else { return false }
    guard let running = rvdPIDs() else { return true }
    return positive.contains(where: running.contains)
}

private func isServiceWeakening(_ program: String, _ args: [String]) -> Bool {
    switch program {
    case "launchctl": return launchctlWeakens(args)
    case "systemctl": return systemctlWeakens(args)
    case "pkill": return patternOperandsMayMatchRV(args)
    case "killall": return patternOperandsMayMatchRV(args)
    default: return false
    }
}

private let rvLabelMarker = "dev.rv."

private func namesRVService(_ word: String) -> Bool {
    word.contains(rvLabelMarker) || isUnmodelledServiceWord(word)
}

private func isUnmodelledServiceWord(_ word: String) -> Bool {
    word.contains(where: { "$`*?[{".contains($0) })
}

private func namesRVVariable(_ word: String) -> Bool {
    word.hasPrefix("rv_") || isUnmodelledServiceWord(word)
}

private let launchctlStopVerbs: Set<String> = ["bootout", "kill", "disable", "remove", "unload", "stop"]

/// launchctl verbs that only read state.
private let launchctlReadOnlyVerbs: Set<String> = [
    "list", "print", "print-cache", "print-disabled", "getenv", "blame", "dumpstate", "dumpjpcategory",
    "procinfo", "hostinfo", "resolveport", "version", "help", "managerpid", "manageruid", "managername",
    "error",
]

/// An rv label, an `RV_*` name (alone or in `NAME=value`), or an
/// unmodelled word anywhere in the operands.
private func mentionsRV(_ word: String) -> Bool {
    namesRVService(word) || word.split(whereSeparator: { "=,: ".contains($0) }).contains { $0.hasPrefix("rv_") }
}

private func launchctlWeakens(_ args: [String]) -> Bool {
    guard let verbIndex = args.firstIndex(where: { $0.hasPrefix("-") == false }) else { return false }
    let verb = args[verbIndex]
    let rest = Array(args[(verbIndex + 1)...])
    let operands = rest.filter { $0.hasPrefix("-") == false }
    if isUnmodelledServiceWord(verb) { return true }
    if verb == "asuser" || verb == "bsexec" {
        // `launchctl asuser UID command ...`: the inner command runs as given.
        let inner = Array(operands.dropFirst())
        guard let program = inner.first.map(programName) else { return false }
        let innerArgs = Array(inner.dropFirst())
        return isServiceWeakening(program, innerArgs) || launchesServiceTool(program, innerArgs)
            || innerArgs.contains(where: mentionsRV)
    }
    if launchctlReadOnlyVerbs.contains(verb) { return false }
    switch verb {
    case "setenv", "unsetenv":
        return operands.contains(where: namesRVVariable)
    case "kickstart":
        // Only `-k` kills the running instance (to restart it).
        let kills = rest.contains { $0.hasPrefix("-") && $0.hasPrefix("--") == false && $0.contains("k") }
        return kills && operands.contains(where: namesRVService)
    case _ where rest.contains(where: mentionsRV):
        // Any other verb once an rv label or RV_* name appears (`debug
        // --environment RV_X=1`, `bootstrap`, `submit -l dev.rv.x`).
        return true
    case _ where launchctlStopVerbs.contains(verb):
        if operands.contains(where: namesRVService) { return true }
        // `bootout gui/501` tears down the whole domain, rvd included;
        // `unload ~/Library/LaunchAgents` unloads every plist in it.
        if verb == "bootout", operands.isEmpty == false, operands.allSatisfy(isLaunchdDomain) { return true }
        return operands.contains { $0.hasSuffix("launchagents") || $0.hasSuffix("launchagents/") }
    default:
        return false
    }
}

private func isLaunchdDomain(_ word: String) -> Bool {
    if word == "system" { return true }
    let parts = word.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let kind = parts.first else { return false }
    return ["gui", "user", "login", "session", "pid"].contains(String(kind))
}

private let systemctlEnvVerbs: Set<String> = ["set-environment", "unset-environment", "import-environment"]
private let systemctlStopVerbs: Set<String> = [
    "stop", "disable", "mask", "kill", "edit", "revert", "restart", "try-restart",
    "reload-or-restart", "try-reload-or-restart", "freeze", "clean", "link", "preset",
]

private func systemctlWeakens(_ args: [String]) -> Bool {
    let words = args.filter { $0.hasPrefix("-") == false }
    guard let verbIndex = words.firstIndex(where: { systemctlEnvVerbs.contains($0) || systemctlStopVerbs.contains($0) })
    else {
        // An unmodelled word may be the verb.
        return words.first.map(isUnmodelledServiceWord) ?? false
    }
    let verb = words[verbIndex]
    let operands = Array(words[(verbIndex + 1)...])
    if systemctlEnvVerbs.contains(verb) {
        // A bare `import-environment` imports the caller's whole environment.
        if verb == "import-environment", operands.isEmpty { return true }
        return operands.contains(where: namesRVVariable)
    }
    return operands.contains(where: namesRVService)
}

/// Process names and command lines rv runs under.
private let rvProcessSubjects = [
    "rvd", "rv", "rv-cli", "rv-workspace-host", "rv-mcp-custodian",
    "/users/someone/.local/bin/rvd", "/home/someone/.local/bin/rvd",
]

/// Every positional operand is a pattern (pkill/pgrep regex, killall name
/// or `-m` regex). One that matches an rv process, is unmodelled, or does
/// not compile is flagged. Option values read as patterns only over-flag.
private func patternOperandsMayMatchRV(_ args: [String]) -> Bool {
    args.contains { word in
        guard word.hasPrefix("-") == false, word.isEmpty == false else { return false }
        if isUnmodelledServiceWord(word) && word.contains("$") { return true }
        guard let regex = try? NSRegularExpression(pattern: word, options: [.caseInsensitive]) else { return true }
        return rvProcessSubjects.contains { subject in
            regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }
    }
}
