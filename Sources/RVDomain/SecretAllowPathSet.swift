/// Literal file or directory exemptions for non-host-auth catalog hits.
///
/// Host-auth rows (`SecretPathCategory.host`) are never exempted.
public struct SecretAllowPathSet: Sendable, Equatable {
    public var literals: [String]

    public init(literals: [String]) {
        self.literals = literals
    }

    public static let empty = SecretAllowPathSet(literals: [])

    public func exempts(_ path: String, rule: SecretPathRule, home: String? = nil) -> Bool {
        guard rule.category != .host else { return false }
        let candidate = Self.normalize(path, home: home)
        for literal in literals {
            if Self.covers(candidate: candidate, allow: Self.normalize(literal, home: home)) {
                return true
            }
        }
        return false
    }

    public static func normalize(_ path: String, home: String?) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        if let home, home.isEmpty == false {
            if value == "~" { return home }
            if value.hasPrefix("~/") {
                return home + "/" + value.dropFirst(2)
            }
            if value.hasPrefix("${HOME}") {
                return home + value.dropFirst(7)
            }
            if value.hasPrefix("$HOME") {
                let rest = value.dropFirst(5)
                if rest.isEmpty || rest.hasPrefix("/") {
                    return home + rest
                }
            }
            return value
        }
        if value.hasPrefix("~/") {
            return "$HOME/" + value.dropFirst(2)
        }
        if value.hasPrefix("${HOME}") {
            return "$HOME" + value.dropFirst(7)
        }
        return value
    }

    public static func covers(candidate: String, allow: String) -> Bool {
        if candidate == allow { return true }
        if candidate.hasPrefix(allow + "/") { return true }
        if allow.hasPrefix("/") == false,
           allow.hasPrefix("$HOME") == false,
           allow.hasPrefix("~") == false,
           candidate.hasSuffix("/" + allow)
        {
            return true
        }
        return false
    }
}
