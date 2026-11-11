import RVDomain

/// The Secret Service keyring is where rv keeps stored secrets on Linux
/// (`SecretServiceTool`), and it has no per-application access control: any
/// process of this user on the session bus can read an unlocked item. On
/// macOS the Keychain asks before another program reads rv's items; here the
/// hook guard is that check. `touchesSecretService` is true when a launched
/// command is `secret-tool` (any verb: `lookup`/`search` reveal values,
/// `store`/`clear` replace or remove them), a dynamic head given a
/// `secret-tool` verb, or when the command text names the Secret Service on
/// D-Bus (`org.freedesktop.secrets`, through `gdbus`, `busctl`, `dbus-send`
/// or an inline script). It is a `core.secrets` deny like a keyring file read
/// (`home-keyrings`); the owner runs `secret-tool` in their own terminal.
///
/// It does not see a program that links libsecret and reads the keyring
/// itself: like any same-user process, that one is outside what a command
/// check can judge.
public enum SecretServiceGuard {
    static let patternName = "secret-service"
    public static let ruleID = RuleID(pack: .coreSecrets, pattern: patternName)
    static let reason =
        "Reading or changing the Secret Service keyring (where rv keeps stored secrets on Linux) is not allowed."

    private static let toolName = "secret-tool"
    private static let toolVerbs: Set<String> = ["lookup", "search", "store", "clear", "lock", "unlock"]
    /// The Secret Service's well-known bus name and object path.
    private static let busMentions = ["org.freedesktop.secrets", "org/freedesktop/secrets"]

    public static func touchesSecretService(_ command: ShellCommand) -> Bool {
        let folded = foldHiddenMentions(command.rawValue)
        if busMentions.contains(where: { folded.contains($0) }) { return true }
        return launchedCommandHeads(command.rawValue).contains { launched in
            if launched.truncated { return folded.contains(toolName) }
            guard let head = launched.guardArgv.first else { return false }
            if commandName(head) == toolName { return true }
            guard launched.headIsDynamic else { return false }
            return launched.guardArgv.dropFirst().contains { toolVerbs.contains(foldedWord($0)) }
        }
    }

    static func match(searchText: String) -> RuleMatch {
        RuleMatch(ruleID: ruleID, severity: .high, reason: reason, regex: nil, matchedText: nil, searchText: searchText)
    }
}
