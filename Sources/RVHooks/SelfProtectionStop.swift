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
// The `who` line names the human's command, the one the agent tried, only
// when it is a plain `rv` invocation that cannot weaken rv (storing a key,
// turning a guard up, `ownerPasteable`); anything else (an uninstall, a
// watch mode, a pipe, a script) asks them to run it in their own terminal.
// The safer command is that verb's help page (`rvHelpPageVerbs`), which
// self-protection lets through and the hook door checks is allowed before
// it shows it, so the agent can read about the command without the judge
// in the way.

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
        safer: voice.offersSelfProtectionHelp ? command.flatMap(selfProtectionSaferCommand) : nil,
        who: words.flatMap(ownerPasteable).map { ownerRunsLine($0, owner: voice.owner) }
            ?? ownTerminalLine(owner: voice.owner)
    )
}

/// The help page a self-protection stop of `command` offers, or nil.
public func selfProtectionSaferCommand(_ command: ShellCommand) -> String? {
    plainRVInvocation(command).flatMap(rvHelpCommand)
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

/// The agent's command, for the owner to paste, only when it cannot
/// weaken rv: storing a key (`rv secrets set NAME ...`) or turning a
/// host's guard up (`rv host mode <host> enforce|block`). rv never asks
/// the owner, in its own voice, to run an uninstall, a watch mode, a
/// pause, an allowlist entry or an unlock the agent picked; those get the
/// own-terminal line.
func ownerPasteable(_ words: [String]) -> String? {
    let verbs = Array(words.dropFirst())
    let secrets = CommandVocabulary.Command.secrets.rawValue
    let host = CommandVocabulary.Command.host.rawValue
    switch verbs.first {
    case secrets? where verbs.count >= 3 && verbs[1] == "set" && verbs[2].hasPrefix("-") == false:
        break
    case host? where verbs.count == 4 && verbs[1] == "mode" && ["enforce", "block"].contains(verbs[3]):
        break
    default:
        return nil
    }
    return words.joined(separator: " ")
}

/// The verbs whose help page an agent may read without the judge, and
/// that a self-protection stop may offer: each one's `--help` (also after
/// one subcommand word) only prints help. Verbs that pass their arguments
/// on to another program (`run`, `box`, `opencode`, `workspace`, `mcp`),
/// that evaluate or run what follows (`explain`, `test`, `try`, `check`,
/// `prompt`, `hook`, `term`), and the unlock verbs are left out.
public let rvHelpPageVerbs: [CommandVocabulary.Command] = [
    .wait, .news, .packs, .protect, .policy, .scan, .service, .setup, .initialize, .uninstall, .doctor,
    .egress, .safety, .blocks, .log, .host, .pause, .audit, .secrets, .login, .managed, .report,
]

/// `rv <verb> [<sub>] --help` for a plain rv invocation: the verb (one of
/// `rvHelpPageVerbs`) and at most one lowercase subcommand word, the exact
/// form self-protection lets through. Nil for any other verb.
func rvHelpCommand(_ words: [String]) -> String? {
    let verbs = words.dropFirst().prefix(while: isHelpWord).prefix(2)
    guard let verb = verbs.first, rvHelpPageVerbs.contains(where: { $0.rawValue == verb }) else { return nil }
    return ([CommandVocabulary.program] + verbs + ["--help"]).joined(separator: " ")
}

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
