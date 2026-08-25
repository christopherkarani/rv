import RVDomain

private let claudeBlockedBrand = "RV · Blocked"
private let claudeAllowOnceCommand = "rv allow-once"
private let claudeClosingLine =
    "If you need this, run it in Terminal, or use rv allow-once in a TTY."

func claudeSystemMessage(hostDenyText: String) -> String {
    "\(claudeBlockedBrand)\n\(hostDenyText)"
}

func claudeRichPermissionDecisionReason(
    hostDenyText: String,
    match: RuleMatch,
    command: ShellCommand
) -> String {
    var lines = [
        claudeBlockedBrand,
        hostDenyText,
        "Reason: \(match.reason)",
    ]
    if let explanation = match.explanation, explanation.isEmpty == false {
        lines.append("Explanation: \(explanation)")
    }
    lines.append("Rule: \(match.ruleID.rawValue)")
    lines.append("Command: \(hookDenyCommandPreview(command))")
    lines.append(claudeClosingLine)
    return lines.joined(separator: "\n")
}

func claudeRemediation(for match: RuleMatch) -> String {
    var parts: [String] = []
    if let explanation = match.explanation, explanation.isEmpty == false {
        parts.append("\"explanation\":\(jsonQuoted(explanation))")
    }
    let safeAlternative = claudeSafeAlternative(for: match)
    if let safeAlternative, safeAlternative.isEmpty == false {
        parts.append("\"safeAlternative\":\(jsonQuoted(safeAlternative))")
    }
    parts.append("\"allowOnceCommand\":\(jsonQuoted(claudeAllowOnceCommand))")
    return "{\(parts.joined(separator: ","))}"
}

func claudeSafeAlternative(for match: RuleMatch) -> String? {
    let reason = match.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    return reason.isEmpty ? nil : reason
}

func claudeRichDenyJSON(
    hostDenyText: String,
    match: RuleMatch,
    command: ShellCommand
) -> String {
    let systemMessage = claudeSystemMessage(hostDenyText: hostDenyText)
    let permissionDecisionReason = claudeRichPermissionDecisionReason(
        hostDenyText: hostDenyText,
        match: match,
        command: command
    )
    let remediation = claudeRemediation(for: match)
    let hookSpecificOutput =
        "{\"hookEventName\":\"PreToolUse\","
        + "\"permissionDecision\":\"deny\","
        + "\"permissionDecisionReason\":\(jsonQuoted(permissionDecisionReason)),"
        + "\"ruleId\":\(jsonQuoted(match.ruleID.rawValue)),"
        + "\"packId\":\(jsonQuoted(match.packID.rawValue)),"
        + "\"severity\":\(jsonQuoted(match.severity.rawValue)),"
        + "\"remediation\":\(remediation)}"
    return "{\"systemMessage\":\(jsonQuoted(systemMessage)),"
        + "\"hookSpecificOutput\":\(hookSpecificOutput)}\n"
}

func claudeIndeterminateDenyJSON(reason: String) -> String {
    let hookSpecificOutput =
        "{\"hookEventName\":\"PreToolUse\","
        + "\"permissionDecision\":\"deny\","
        + "\"permissionDecisionReason\":\(jsonQuoted(reason))}"
    return "{\"systemMessage\":\(jsonQuoted(reason)),"
        + "\"hookSpecificOutput\":\(hookSpecificOutput)}\n"
}
