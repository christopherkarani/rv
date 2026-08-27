import RVDomain

/// Unlock next-step on hook voice. TTY deny next-action keeps its own casing.
public let hookUnlockNext = "Run it in Terminal, or rv allow-once."

/// Hook-voice deny sentence for a payload addressed to this host that could not
/// be decoded. Fail-closed twin of `incompleteEvalSentence`.
public func malformedHookSentence(_ malformation: HookMalformation) -> String {
    switch malformation {
    case .unreadable:
        return "rv received a hook payload it could not read and blocked the command. Run it in Terminal."
    case .missingCommand:
        return "rv received a shell hook with no command text and blocked the command. Run it in Terminal."
    }
}

/// Max characters of the command's first line in hook deny JSON.
public let hookDenyCommandPreviewLimit = 96

/// First line of `command` for host deny text. Extra lines and overlong
/// first lines become a trailing ellipsis so Grok/Pi/OpenCode never paste
/// a heredoc body into the transcript.
public func hookDenyCommandPreview(_ command: ShellCommand) -> String {
    var raw = command.rawValue
    while let last = raw.last, last == "\n" || last == "\r" {
        raw.removeLast()
    }
    var firstLine = ""
    var sawBreak = false
    for ch in raw {
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

/// Ask JSON reason. Deny hook payload must not use this line.
public func hostAskLine(command: ShellCommand, ruleID: RuleID) -> String {
    "Blocked \(hookDenyCommandPreview(command)) (\(displayRuleID(ruleID))). \(hookUnlockNext)"
}

/// First sentence of `reason`, command prefix stripped, capitalized, with a period.
func hostDenyWhy(_ reason: String, command: ShellCommand) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    var sentence = trimmed
    if let end = trimmed.firstRange(of: ". ") {
        sentence = String(trimmed[..<end.lowerBound])
    } else if sentence.hasSuffix(".") {
        sentence = String(sentence.dropLast())
    }
    sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = hookDenyCommandPreview(command)
    if sentence.lowercased().hasPrefix(preview.lowercased()) {
        sentence = String(sentence.dropFirst(preview.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let first = sentence.first else {
        return ""
    }
    let capitalized = first.uppercased() + sentence.dropFirst()
    return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
}

public func hostDenyLine(command: ShellCommand, reason: String) -> String {
    let preview = hookDenyCommandPreview(command)
    let why = hostDenyWhy(reason, command: command)
    if why.isEmpty {
        return "Blocked \(preview)."
    }
    return "Blocked \(preview). \(why)"
}

public func hostDenyText(from result: EvaluationResult, command: ShellCommand) -> String? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate:
        return incompleteEvalSentence
    case .deny(let deny):
        return hostDenyLine(command: command, reason: deny.reason)
    }
}
