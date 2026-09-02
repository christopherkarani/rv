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

/// Documented PreToolUse ask keys only. Extra `hookSpecificOutput` keys fail-open a deny.
func claudeAskJSON(reason: String) -> String {
    let hookSpecificOutput =
        "{\"hookEventName\":\"PreToolUse\","
        + "\"permissionDecision\":\"ask\","
        + "\"permissionDecisionReason\":\(jsonQuoted(reason))}"
    return "{\"systemMessage\":\(jsonQuoted(reason)),"
        + "\"hookSpecificOutput\":\(hookSpecificOutput)}\n"
}

/// PermissionRequest honor path. `permissionDecision` is PreToolUse-only.
func claudePermissionRequestDenyJSON(reason: String) -> String {
    "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\","
        + "\"decision\":{\"behavior\":\"deny\",\"message\":\(jsonQuoted(reason))}}}\n"
}

func claudePermissionRequestDeny(reason: String) -> HookWire {
    HookWire(stdout: claudePermissionRequestDenyJSON(reason: reason), exitCode: 0)
}
