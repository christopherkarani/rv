import RVDomain

// MARK: - Self-protection says its name (North Star B2, S3)
//
// A command that would weaken rv (`rv uninstall`, `rv secrets set`, `rv
// host mode claude observe`, ...) is not a crash and not "rv could not
// finish". It is rv protecting itself, and the stop says so, in the same
// shape as every other stop:
//
//     ✕ rv protects itself   rv secrets set STRIPE_KEY (rv.indeterminate/selfProtection)
//     why     agents can't change rv's own settings
//     safer   rv secrets set --help
//     who     ask Chris to run  rv secrets set STRIPE_KEY
//
// The `who` line names the human's command, the one the agent tried, when
// it is a plain `rv` invocation the owner can paste; anything else (a
// pipe, a script, a clipped line) asks them to run it in their own
// terminal. The safer command is that verb's help page, which
// self-protection always lets through (`isHelpPageRequest`), so the agent
// can read what the owner will run without the judge in the way.

/// The verdict word self-protection uses in place of `Stopped`.
public let selfProtectionVerdict = "rv protects itself"

/// Why, in under ten words.
public let selfProtectionWhy = "agents can't change rv's own settings"

/// The stop for a command self-protection floored.
public func selfProtectionStopNotice(command: ShellCommand?, voice: StopVoice = .plain) -> StopNotice {
    let words = command.flatMap(plainRVInvocation)
    return StopNotice(
        verdict: selfProtectionVerdict,
        subject: command.map(hookDenyCommandPreview),
        rule: indeterminateStopRule(.selfProtection),
        why: selfProtectionWhy,
        safer: words.flatMap(rvHelpCommand),
        who: words.map { ownerRunsLine($0.joined(separator: " "), owner: voice.owner) }
            ?? ownTerminalLine(owner: voice.owner),
        again: stopStreakNote(voice.streak)
    )
}

/// The words of `command` when it is one plain `rv` invocation: `rv`
/// first, then only words made of letters, digits and `._/:=@,+-`. No
/// shell syntax, quotes, variables, globs or second command, and short
/// enough to show whole, so the owner pastes exactly what the agent tried.
func plainRVInvocation(_ command: ShellCommand) -> [String]? {
    let raw = command.rawValue.trimmingCharacters(in: .whitespaces)
    guard raw.count <= hookDenyCommandPreviewLimit else { return nil }
    let words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count >= 2, words[0] == CommandVocabulary.program else { return nil }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:=@,+-".unicodeScalars)
    guard words.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
    return words
}

/// `rv <verb> [<sub>] --help` for a plain rv invocation: the leading
/// lowercase words (at most two), the exact form self-protection lets
/// through. Nil when the verb itself is not such a word.
func rvHelpCommand(_ words: [String]) -> String? {
    let verbs = words.dropFirst().prefix(while: isHelpWord).prefix(2)
    // A help page for an unlock verb still reads as "run allow-once": the
    // agent is never pointed at one, not even its help.
    guard let verb = verbs.first, unlockVerbs.contains(verb) == false else { return nil }
    return ([CommandVocabulary.program] + verbs + ["--help"]).joined(separator: " ")
}

private let unlockVerbs: Set<String> = [
    CommandVocabulary.Command.allowOnce.rawValue, CommandVocabulary.Command.allowlist.rawValue, "unlock",
]

private func isHelpWord(_ word: String) -> Bool {
    guard let first = word.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
    return word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "-" }
}

// MARK: - Advice rv gives for its own rules

/// Advice for rules no pack JSON carries: rv's own secret-path rule for its
/// config dir (S3). Reading `~/.config/rv` is never the way to a key; the
/// names are one command away, and `rv run --secret` uses the value
/// without showing it.
public func builtinStopAdvice(_ rule: RuleID) -> StopAdvice? {
    guard rule.rawValue == "core.secrets:home-rv-config" else { return nil }
    return StopAdvice(saferCommand: CommandVocabulary.Command.secrets.invocation + " list")
}
