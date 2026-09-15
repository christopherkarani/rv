import RVDomain

/// Unlock next-step on hook voice when no minted code exists. TTY deny next-action keeps its own casing.
public let ttyUnlockHint = "Run it in Terminal, or rv allow-once."

/// Same sentence as `ttyUnlockHint`. Kept so existing TTY copy sites compile.
public let hookUnlockNext = ttyUnlockHint

/// Six lowercase hex characters minted for `rv allow-once`.
public struct AllowOnceUnlockCode: Hashable, Sendable, Equatable {
    public let rawValue: String

    /// True when `code` is exactly six lowercase hex characters.
    public static func isValid(_ code: String) -> Bool {
        guard code.count == 6 else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f")
        }
    }

    public init?(validating rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// Six lowercase hex characters minted for TTY redeem.
public func isAllowOnceUnlockCode(_ code: String) -> Bool {
    AllowOnceUnlockCode.isValid(code)
}

/// Next-step on host deny/ask JSON. Prefer `.none` over `HookVoiceNext?`.
public enum HookVoiceNext: Sendable, Equatable {
    case none
    case ttyHint
    case minted(AllowOnceUnlockCode)
}

/// Returns the minted allow-once paste line for `code`.
/// Code goes first so truncated host cards still show the paste.
public func unlockLine(for code: AllowOnceUnlockCode) -> String {
    "Paste in Terminal to allow once: rv allow-once \(code.rawValue)."
}

/// Unlock line with a minted code, or the no-code `ttyUnlockHint` constant.
public func hookUnlockNext(code: String?) -> String {
    if let code, let typed = AllowOnceUnlockCode(validating: code) {
        return unlockLine(for: typed)
    }
    return ttyUnlockHint
}

func hookVoiceNextSentence(_ next: HookVoiceNext) -> String? {
    switch next {
    case .none:
        return nil
    case .ttyHint:
        return ttyUnlockHint
    case .minted(let code):
        return unlockLine(for: code)
    }
}

func unlockHookVoiceNext(_ code: AllowOnceUnlockCode?, fallback: HookVoiceNext = .none) -> HookVoiceNext {
    if let code {
        return .minted(code)
    }
    return fallback
}

/// First `rv allow-once <6hex>` in `text`, if present.
public func allowOnceUnlockCode(in text: String) -> AllowOnceUnlockCode? {
    let marker = "rv allow-once "
    guard let range = text.range(of: marker) else { return nil }
    let code = String(text[range.upperBound...].prefix(6))
    return AllowOnceUnlockCode(validating: code)
}

func mintedUnlockNext(_ code: AllowOnceUnlockCode?) -> String? {
    code.map { unlockLine(for: $0) }
}

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
    "Blocked \(hookDenyCommandPreview(command)) (\(ruleID.slashDisplay)). \(ttyUnlockHint)"
}

/// Sentence 1 of `reason`, plus sentence 2 when it is a safe one-line tip.
/// Command prefix stripped, sentence 1 capitalized, both clauses end with `.`.
func hostDenyWhy(_ reason: String, command: ShellCommand?) -> String {
    var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = command.map(hookDenyCommandPreview) ?? ""
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

public func hostDenyLine(
    command: ShellCommand,
    reason: String,
    unlockCode: AllowOnceUnlockCode? = nil
) -> String {
    wrappedHostDeny(why: hostDenyWhy(reason, command: command), unlockCode: unlockCode)
}

public func hostDenyLine(command: ShellCommand, reason: String, unlockCode: String?) -> String {
    hostDenyLine(
        command: command,
        reason: reason,
        unlockCode: unlockCode.flatMap(AllowOnceUnlockCode.init(validating:))
    )
}

/// File-tool deny sentence. Does not preview an empty `ShellCommand`.
public func hostFileDenyLine(reason: String, unlockCode: AllowOnceUnlockCode? = nil) -> String {
    wrappedHostDeny(why: hostDenyWhy(reason, command: nil), unlockCode: unlockCode)
}

private func wrappedHostDeny(why: String, unlockCode: AllowOnceUnlockCode?) -> String {
    let blocked = "RV · Blocked."
    let withoutCode = why.isEmpty ? blocked : "\(blocked) \(why)"
    guard let unlock = mintedUnlockNext(unlockCode) else {
        return withoutCode
    }
    let combined = why.isEmpty ? "\(blocked) \(unlock)" : "\(blocked) \(unlock) \(why)"
    if combined.contains("\u{001B}") || combined.contains("═") || combined.contains("┌") || combined.contains("\n") {
        return withoutCode
    }
    return combined
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
