import Foundation

/// rvd reads its posture knobs (`RV_GUARD_MODE`, `RV_JUDGE_ENGINE`,
/// `RV_FT_BUNDLE`, `RV_LAYA_BUNDLE`) from its launch environment and must
/// stay running to guard anything. An agent command that edits the
/// launchd/systemd user environment for `RV_*`, or that stops, unloads,
/// restarts or kills rv's own service (labels and units named `dev.rv.*`,
/// the `rvd` process), weakens rv exactly like `rv uninstall`.
///
/// A dynamic head (`$L setenv ...`) may be any of these programs, and an
/// unmodelled operand (`$X`, glob) where the target is decided fails
/// closed. Read-only forms (`launchctl list|print|getenv`, `systemctl
/// status`, `pgrep rvd`) and other services pass.
func retunesOrStopsRVService(_ launched: [LaunchedCommand]) -> Bool {
    let argvs = launched.map { (words: $0.guardArgv.map(foldedWord), dynamic: $0.headIsDynamic) }
    for (words, dynamic) in argvs {
        guard let program = words.first else { continue }
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

private func launchctlWeakens(_ args: [String]) -> Bool {
    guard let verbIndex = args.firstIndex(where: { $0.hasPrefix("-") == false }) else { return false }
    let verb = args[verbIndex]
    let rest = Array(args[(verbIndex + 1)...])
    let operands = rest.filter { $0.hasPrefix("-") == false }
    if isUnmodelledServiceWord(verb) { return true }
    switch verb {
    case "setenv", "unsetenv":
        return operands.contains(where: namesRVVariable)
    case "kickstart":
        // Only `-k` kills the running instance (to restart it).
        let kills = rest.contains { $0.hasPrefix("-") && $0.hasPrefix("--") == false && $0.contains("k") }
        return kills && operands.contains(where: namesRVService)
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
