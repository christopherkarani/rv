/// Shared clustered-short parse for git and filesystem flag tokens.
func clusteredShorts(_ token: String) -> [Character]? {
    guard token.hasPrefix("-"), token.hasPrefix("--") == false, token.count > 1 else {
        return nil
    }
    if token.contains("=") { return nil }
    return Array(token.dropFirst())
}

/// Git long-option `=value`. Named apart from unwrap's private `attachedValue`.
func gitAttachedValue(_ token: String, long: String) -> String? {
    let prefix = long + "="
    guard token.hasPrefix(prefix) else { return nil }
    let value = String(token.dropFirst(prefix.count))
    return value.isEmpty ? nil : value
}
