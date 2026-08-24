import RVDomain

/// Unlock next-step on hook voice. TTY deny next-action keeps its own casing.
public let hookUnlockNext = "Run it in Terminal, or rv allow-once."

/// Max characters of the command's first line in hook deny JSON.
public let hookDenyCommandPreviewLimit = 96

/// First line of `command` for host deny text. Extra lines and overlong
/// first lines become a trailing ellipsis so Grok/Pi/OpenCode never paste
/// a heredoc body into the transcript.
public func hookDenyCommandPreview(_ command: ShellCommand) -> String {
    var firstLine = ""
    var sawBreak = false
    for ch in command.rawValue {
        if ch == "\n" || ch == "\r" {
            sawBreak = true
            break
        }
        firstLine.append(ch == "\t" ? " " : ch)
    }
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    let clipped = trimmed.count > hookDenyCommandPreviewLimit
        ? String(trimmed.prefix(hookDenyCommandPreviewLimit))
        : trimmed
    if sawBreak || trimmed.count > hookDenyCommandPreviewLimit {
        return clipped + "…"
    }
    return clipped
}

public func hostDenyLine(command: ShellCommand, ruleID: RuleID) -> String {
    "Blocked \(hookDenyCommandPreview(command)) (\(displayRuleID(ruleID))). \(hookUnlockNext)"
}

public func hostDenyText(from result: EvaluationResult, command: ShellCommand) -> String? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate:
        return incompleteEvalSentence
    case .deny(let deny):
        return hostDenyLine(command: command, ruleID: deny.ruleID)
    }
}
