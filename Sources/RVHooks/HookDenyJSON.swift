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

private func jsonQuoted(_ value: String) -> String {
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
