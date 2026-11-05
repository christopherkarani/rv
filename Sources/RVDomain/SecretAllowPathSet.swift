/// Literal file or directory exemptions for non-host-auth catalog hits.
///
/// Host-auth rows (`SecretPathCategory.host`) are never exempted.
public struct SecretAllowPathSet: Sendable, Equatable {
    public var literals: [String]

    public init(literals: [String]) {
        self.literals = literals
    }

    public static let empty = SecretAllowPathSet(literals: [])

    /// A spelling with a `..` component is never exempt: `fixtures/../.env`
    /// names `.env`, not a file under an allowed `fixtures`. `.` components
    /// are dropped, so `./.env` reads as `.env`.
    public func exempts(_ path: String, rule: SecretPathRule, home: HomePath? = nil) -> Bool {
        guard rule.category != .host,
              let candidate = Self.lexical(Self.normalize(path, home: home))
        else { return false }
        for literal in literals {
            guard let allow = Self.lexical(Self.normalize(literal, home: home)) else { continue }
            if Self.covers(candidate: candidate, allow: allow) {
                return true
            }
        }
        return false
    }

    /// `path` without `.` components or repeated slashes; nil when it climbs
    /// with `..`, which only the filesystem can settle.
    static func lexical(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.contains("..") == false else { return nil }
        let kept = parts.filter { $0 != "." }
        let joined = kept.joined(separator: "/")
        if path.hasPrefix("/") { return "/" + joined }
        return joined.isEmpty ? path : joined
    }

    public static func normalize(_ path: String, home: HomePath?) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        if let home {
            let homePath = home.rawValue
            if value == "~" { return homePath }
            if value.hasPrefix("~/") {
                return homePath + "/" + value.dropFirst(2)
            }
            if value.hasPrefix("${HOME}") {
                return homePath + value.dropFirst(7)
            }
            if value.hasPrefix("$HOME") {
                let rest = value.dropFirst(5)
                if rest.isEmpty || rest.hasPrefix("/") {
                    return homePath + rest
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
