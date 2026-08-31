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

/// Sentence 1 of `reason`, plus sentence 2 when it is a safe one-line tip.
/// Command prefix stripped, sentence 1 capitalized, both clauses end with `.`.
func hostDenyWhy(_ reason: String, command: ShellCommand) -> String {
    var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = hookDenyCommandPreview(command)
    if !preview.isEmpty, text.lowercased().hasPrefix(preview.lowercased()) {
        text = String(text.dropFirst(preview.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let sentence1Raw: String
    let rest: String
    if let end = text.firstRange(of: ". ") {
        sentence1Raw = String(text[..<end.lowerBound])
        rest = String(text[end.upperBound...])
    } else if text.hasSuffix(".") {
        sentence1Raw = String(text.dropLast())
        rest = ""
    } else {
        sentence1Raw = text
        rest = ""
    }

    var sentence1 = sentence1Raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = sentence1.first else {
        return ""
    }
    sentence1 = first.uppercased() + sentence1.dropFirst()
    if !sentence1.hasSuffix(".") {
        sentence1 += "."
    }

    var sentence2 = ""
    if !rest.isEmpty {
        let secondRaw: String
        if let next = rest.firstRange(of: ". ") {
            secondRaw = String(rest[..<next.lowerBound])
        } else {
            secondRaw = rest
        }
        sentence2 = secondRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence2.isEmpty, !sentence2.hasSuffix(".") {
            sentence2 += "."
        }
    }

    if shouldOmitDenySentence2(sentence2, sentence1: sentence1) {
        return sentence1
    }
    return "\(sentence1) \(sentence2)"
}

private func shouldOmitDenySentence2(_ sentence2: String, sentence1: String) -> Bool {
    if sentence2.isEmpty { return true }
    if sentence2.contains("allow-once") { return true }
    if sentence2.contains("ALLOW-") { return true }
    if sentence2.contains("redeem") { return true }
    if sentence2.contains("RV_" + "BYPASS") { return true }
    if sentence2.contains("Terminal") { return true }
    if sentence2.contains("reset --soft") { return true }
    if sentence2.contains("\n") { return true }

    let why = "\(sentence1) \(sentence2)"
    if why.unicodeScalars.count > 180 { return true }

    let line = "RV · Blocked. \(why)"
    if line.contains("\u{001B}") { return true }
    if line.contains("═") { return true }
    if line.contains("┌") { return true }
    if line.contains("\n") { return true }
    return false
}

public func hostDenyLine(command: ShellCommand, reason: String) -> String {
    let why = hostDenyWhy(reason, command: command)
    if why.isEmpty {
        return "RV · Blocked."
    }
    return "RV · Blocked. \(why)"
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
