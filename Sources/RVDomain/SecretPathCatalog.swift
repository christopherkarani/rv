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
