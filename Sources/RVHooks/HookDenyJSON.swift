func hookAskJSON(reason: String, rule: String? = nil, next: String? = nil) -> String {
    var body = "\"decision\":\"ask\",\"reason\":\(jsonQuoted(reason)),\"continuation\":\"hostNative\""
    if let rule, rule.isEmpty == false {
        body += ",\"rule\":\(jsonQuoted(rule))"
    }
    if let next, next.isEmpty == false {
        body += ",\"next\":\(jsonQuoted(next))"
    }
    return "{\(body)}\n"
}

func hookDenyJSON(reason: String, rule: String? = nil, next: String? = nil) -> String {
    var body = "\"decision\":\"deny\",\"reason\":\(jsonQuoted(reason))"
    if let rule, rule.isEmpty == false {
        body += ",\"rule\":\(jsonQuoted(rule))"
    }
    if let next, next.isEmpty == false {
        body += ",\"next\":\(jsonQuoted(next))"
    }
    return "{\(body)}\n"
}

/// Official Codex older PreToolUse honor path (`decision: block` + process exit 2).
/// Codex TUI does not honor Claude permission deny JSON. Never emit leftover Ask.
func hookBlockJSON(reason: String) -> String {
    "{\"decision\":\"block\",\"reason\":\(jsonQuoted(reason))}\n"
}

/// Codex TUI fail-opens exit 2 unless this blocking reason is on stderr.
func hookBlockStderr(reason: String) -> String {
    reason.hasSuffix("\n") ? reason : reason + "\n"
}

func jsonQuoted(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"":
            output += "\\\""
        case "\\":
            output += "\\\\"
        case "\n":
            output += "\\n"
        case "\r":
            output += "\\r"
        case "\t":
            output += "\\t"
        default:
            if scalar.value < 0x20 {
                output += String(format: "\\u%04x", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
    }
    output += "\""
    return output
}
