public enum SecretPathKind: Sendable, Equatable {
    case basename(String)
    case envVariant
    case homeSuffix([String])
    case hostAuth([String])
}

public struct SecretPathRule: Sendable, Equatable {
    public var pattern: String
    public var kind: SecretPathKind
    public var reason: String

    public init(pattern: String, kind: SecretPathKind, reason: String) {
        self.pattern = pattern
        self.kind = kind
        self.reason = reason
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

private func dayOneRule(_ pattern: String, _ kind: SecretPathKind) -> SecretPathRule {
    SecretPathRule(pattern: pattern, kind: kind, reason: dayOneReason)
}

private let dayOneRules: [SecretPathRule] = [
    dayOneRule("env", .basename(".env")),
    dayOneRule("env-variant", .envVariant),
    dayOneRule("npmrc", .basename(".npmrc")),
    dayOneRule("pypirc", .basename(".pypirc")),
    dayOneRule("netrc", .basename(".netrc")),
    dayOneRule("git-credentials", .basename(".git-credentials")),
    dayOneRule("id-rsa", .basename("id_rsa")),
    dayOneRule("id-ed25519", .basename("id_ed25519")),
    dayOneRule("id-ecdsa", .basename("id_ecdsa")),
    dayOneRule("credentials", .basename("credentials")),
    dayOneRule("home-ssh", .homeSuffix([".ssh"])),
    dayOneRule("home-aws", .homeSuffix([".aws"])),
    dayOneRule("home-gcp", .homeSuffix([".gcp"])),
    dayOneRule("home-gcloud", .homeSuffix([".config", "gcloud"])),
    dayOneRule("home-kube", .homeSuffix([".kube", "config"])),
    dayOneRule("home-docker", .homeSuffix([".docker", "config.json"])),
    dayOneRule("host-pi-auth", .hostAuth([".pi", "agent", "auth.json"])),
    dayOneRule("host-grok-auth", .hostAuth([".grok", "auth.json"])),
    dayOneRule("host-opencode-auth", .hostAuth([".local", "share", "opencode", "auth.json"])),
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
