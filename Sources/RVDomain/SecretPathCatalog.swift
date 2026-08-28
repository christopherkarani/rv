public enum SecretPathCategory: String, Sendable, Equatable, Codable {
    case environment
    case credentials
    case ssh
    case cloud
    case kubernetes
    case container
    case keychain
    case host
}

public enum SecretPathKind: Sendable, Equatable {
    case basename(String)
    case envVariant
    case homeSuffix([String])
    case hostAuth([String])
}

public struct SecretPathRule: Sendable, Equatable {
    public var pattern: String
    public var kind: SecretPathKind
    public var category: SecretPathCategory
    public var reason: String

    public init(
        pattern: String,
        kind: SecretPathKind,
        category: SecretPathCategory,
        reason: String
    ) {
        self.pattern = pattern
        self.kind = kind
        self.category = category
        self.reason = reason
    }
}

/// Inspectable hit from `SecretPathCatalog`. One catalog, one matcher.
public struct SecretPathMatch: Sendable, Equatable, Codable {
    public var pattern: String
    public var category: SecretPathCategory

    public init(pattern: String, category: SecretPathCategory) {
        self.pattern = pattern
        self.category = category
    }

    public init(_ rule: SecretPathRule) {
        self.pattern = rule.pattern
        self.category = rule.category
    }

    public var ruleID: RuleID {
        RuleID(pack: .coreSecrets, pattern: pattern)
    }
}

public struct SecretPathCatalog: Sendable, Equatable {
    public var rules: [SecretPathRule]

    public init(rules: [SecretPathRule]) {
        self.rules = rules
    }

    public static let empty = SecretPathCatalog(rules: [])

    public static let dayOne = SecretPathCatalog(rules: dayOneRules)

    /// First configured rule that matches `path`. Reused by the secret-path
    /// guard and the filesystem analyzer — not a second scanner.
    public func firstMatch(of path: String) -> SecretPathRule? {
        rules.first { Self.matches(path, $0.kind) }
    }

    private static func matches(_ candidate: String, _ kind: SecretPathKind) -> Bool {
        switch kind {
        case .basename(let name):
            return lastComponent(candidate) == name
        case .envVariant:
            return isEnvVariant(lastComponent(candidate))
        case .homeSuffix(let parts), .hostAuth(let parts):
            return matchesSuffix(candidate, parts: parts)
        }
    }
}

private let dayOneReason = "Access to a sensitive path is not allowed."

private func dayOneRule(
    _ pattern: String,
    _ kind: SecretPathKind,
    _ category: SecretPathCategory
) -> SecretPathRule {
    SecretPathRule(pattern: pattern, kind: kind, category: category, reason: dayOneReason)
}

/// Conservative host-secret table. Append-only: first match wins, existing
/// secret-path `rule_id`s stay stable. Linux and macOS path shapes only.
private let dayOneRules: [SecretPathRule] = [
    dayOneRule("env", .basename(".env"), .environment),
    dayOneRule("env-variant", .envVariant, .environment),
    dayOneRule("npmrc", .basename(".npmrc"), .credentials),
    dayOneRule("pypirc", .basename(".pypirc"), .credentials),
    dayOneRule("netrc", .basename(".netrc"), .credentials),
    dayOneRule("git-credentials", .basename(".git-credentials"), .credentials),
    dayOneRule("id-rsa", .basename("id_rsa"), .ssh),
    dayOneRule("id-ed25519", .basename("id_ed25519"), .ssh),
    dayOneRule("id-ecdsa", .basename("id_ecdsa"), .ssh),
    dayOneRule("credentials", .basename("credentials"), .credentials),
    dayOneRule("home-ssh", .homeSuffix([".ssh"]), .ssh),
    dayOneRule("home-aws", .homeSuffix([".aws"]), .cloud),
    dayOneRule("home-gcp", .homeSuffix([".gcp"]), .cloud),
    dayOneRule("home-gcloud", .homeSuffix([".config", "gcloud"]), .cloud),
    dayOneRule("home-kube", .homeSuffix([".kube", "config"]), .kubernetes),
    dayOneRule("home-docker", .homeSuffix([".docker", "config.json"]), .container),
    dayOneRule("host-pi-auth", .hostAuth([".pi", "agent", "auth.json"]), .host),
    dayOneRule("host-grok-auth", .hostAuth([".grok", "auth.json"]), .host),
    dayOneRule("host-opencode-auth", .hostAuth([".local", "share", "opencode", "auth.json"]), .host),
    dayOneRule("home-azure", .homeSuffix([".azure"]), .cloud),
    dayOneRule("home-gnupg", .homeSuffix([".gnupg"]), .keychain),
    dayOneRule("home-keychains", .homeSuffix(["Library", "Keychains"]), .keychain),
    dayOneRule("home-keyrings", .homeSuffix([".local", "share", "keyrings"]), .keychain),
    dayOneRule("home-password-store", .homeSuffix([".password-store"]), .keychain),
    dayOneRule("home-gh", .homeSuffix([".config", "gh"]), .credentials),
]

private let envVariantExemptions: Set<String> = [
    ".env.example",
    ".env.sample",
    ".env.template",
    ".env.defaults",
]

private func lastComponent(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}

private func isEnvVariant(_ name: String) -> Bool {
    guard name.hasPrefix(".env.") else { return false }
    if envVariantExemptions.contains(name) { return false }
    if name.hasPrefix(".env.example.") { return false }
    if name.hasPrefix(".env.sample.") { return false }
    return true
}

private func hasPathPrefix(_ candidate: String, prefix: String) -> Bool {
    candidate == prefix || candidate.hasPrefix(prefix + "/")
}

private func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let lastStart = haystack.count - needle.count
    var start = 0
    while start <= lastStart {
        var matched = true
        var offset = 0
        while offset < needle.count {
            if haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            offset += 1
        }
        if matched { return true }
        start += 1
    }
    return false
}

private func matchesSuffix(_ candidate: String, parts: [String]) -> Bool {
    let joined = parts.joined(separator: "/")
    if hasPathPrefix(candidate, prefix: "~/" + joined) { return true }
    if hasPathPrefix(candidate, prefix: "$HOME/" + joined) { return true }
    if hasPathPrefix(candidate, prefix: "${HOME}/" + joined) { return true }
    let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    return containsContiguous(components, parts)
}
