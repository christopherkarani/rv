import RVDomain

/// REQ-009: first token, then ` …` when more tokens exist; empty → `[redacted]`.
public func redactMatchingView(_ matchingView: MatchingView) -> String {
    let text = matchingView.rawValue
    guard text.isEmpty == false else { return "[redacted]" }
    let tokens = text.split(whereSeparator: \.isWhitespace)
    guard let head = tokens.first else { return "[redacted]" }
    if tokens.count == 1 {
        return String(head)
    }
    return "\(head) …"
}
