import RVDomain

func claudeRichDenyJSON(
    hostDenyText: String,
    match: RuleMatch
) -> String {
    let hookSpecificOutput =
        "{\"hookEventName\":\"PreToolUse\","
        + "\"permissionDecision\":\"deny\","
        + "\"permissionDecisionReason\":\(jsonQuoted(hostDenyText)),"
        + "\"ruleId\":\(jsonQuoted(match.ruleID.rawValue)),"
        + "\"packId\":\(jsonQuoted(match.packID.rawValue)),"
        + "\"severity\":\(jsonQuoted(match.severity.rawValue))}"
    return "{\"systemMessage\":\(jsonQuoted(hostDenyText)),"
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
