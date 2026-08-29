import Testing
@testable import RVDomain

@Test func packID_coreSecrets_isVirtualAndNotDayOne() {
    #expect(PackID.coreSecrets.rawValue == "core.secrets")
    #expect(PackID(validating: "core.secrets") == PackID.coreSecrets)
    #expect(dayOnePackIDs.contains(.coreSecrets) == false)
    #expect(dayOnePackIDs.map(\.rawValue) == ["core.filesystem", "core.git"])
}

@Test func ruleID_coreSecrets_usesColonPattern() {
    let rule = RuleID(pack: .coreSecrets, pattern: "env")
    #expect(rule.rawValue == "core.secrets:env")
}

@Test func secretPathCatalog_empty_hasNoRules() {
    #expect(SecretPathCatalog.empty.rules.isEmpty)
}

@Test func secretPathCatalog_dayOne_isClosedTableInSpecOrder() {
    let patterns = SecretPathCatalog.dayOne.rules.map(\.pattern)
    #expect(
        patterns == [
            "env",
            "env-variant",
            "npmrc",
            "pypirc",
            "netrc",
            "git-credentials",
            "id-rsa",
            "id-ed25519",
            "id-ecdsa",
            "credentials",
            "home-ssh",
            "home-aws",
            "home-gcp",
            "home-gcloud",
            "home-kube",
            "home-docker",
            "host-pi-auth",
            "host-grok-auth",
            "host-opencode-auth",
            "home-azure",
            "home-gnupg",
            "home-keychains",
            "home-keyrings",
            "home-password-store",
            "home-gh",
        ]
    )
    let reason = "Access to a sensitive path is not allowed."
    #expect(SecretPathCatalog.dayOne.rules.allSatisfy { $0.reason == reason })
    #expect(SecretPathCatalog.dayOne.rules[0].kind == .basename(".env"))
    #expect(SecretPathCatalog.dayOne.rules[0].category == .environment)
    #expect(SecretPathCatalog.dayOne.rules[1].kind == .envVariant)
    #expect(SecretPathCatalog.dayOne.rules[10].kind == .homeSuffix([".ssh"]))
    #expect(SecretPathCatalog.dayOne.rules[10].category == .ssh)
    #expect(SecretPathCatalog.dayOne.rules[16].kind == .hostAuth([".pi", "agent", "auth.json"]))
    #expect(SecretPathCatalog.dayOne.rules[16].category == .host)
    #expect(SecretPathCatalog.dayOne.rules[21].category == .keychain)
}

@Test func secretPathCatalog_matchesCanonicalHostPaths() {
    #expect(SecretPathCatalog.dayOne.firstMatch(of: "/isolated-home/.ssh/config")?.pattern == "home-ssh")
    #expect(SecretPathCatalog.dayOne.firstMatch(of: "/repo/.env")?.pattern == "env")
    #expect(SecretPathCatalog.dayOne.firstMatch(of: "/repo/Sources/Foo.swift") == nil)
}

@Test func secretPathCatalog_matchesHomeAliasesAndNewHostSecrets() {
    let catalog = SecretPathCatalog.dayOne
    #expect(catalog.firstMatch(of: "~/.ssh/config")?.pattern == "home-ssh")
    #expect(catalog.firstMatch(of: "$HOME/.aws/credentials")?.pattern == "credentials")
    #expect(catalog.firstMatch(of: "${HOME}/.aws/config")?.pattern == "home-aws")
    #expect(catalog.firstMatch(of: "/isolated-home/.gnupg/secring.gpg")?.pattern == "home-gnupg")
    #expect(catalog.firstMatch(of: "/isolated-home/Library/Keychains/login.keychain-db")?.pattern == "home-keychains")
    #expect(catalog.firstMatch(of: "/Library/Keychains/System.keychain")?.pattern == "home-keychains")
    #expect(catalog.firstMatch(of: "/isolated-home/.local/share/keyrings/login.keyring")?.pattern == "home-keyrings")
    #expect(catalog.firstMatch(of: "~/.password-store/foo.gpg")?.pattern == "home-password-store")
    #expect(catalog.firstMatch(of: "$HOME/.azure/accessTokens.json")?.pattern == "home-azure")
    #expect(catalog.firstMatch(of: "${HOME}/.config/gh/hosts.yml")?.pattern == "home-gh")
    #expect(catalog.firstMatch(of: "/isolated-home/.ssh/config")?.category == .ssh)
    #expect(catalog.firstMatch(of: "/isolated-home/Library/Keychains/x")?.category == .keychain)
}

@Test func secretPathCatalog_categoriesAreExplicitAndClosed() {
    let byPattern = Dictionary(
        uniqueKeysWithValues: SecretPathCatalog.dayOne.rules.map { ($0.pattern, $0.category) }
    )
    #expect(byPattern["home-ssh"] == .ssh)
    #expect(byPattern["home-aws"] == .cloud)
    #expect(byPattern["home-kube"] == .kubernetes)
    #expect(byPattern["home-docker"] == .container)
    #expect(byPattern["env"] == .environment)
    #expect(byPattern["host-pi-auth"] == .host)
    #expect(Set(SecretPathCatalog.dayOne.rules.map(\.category)).count == 8)
}

@Test func secretPathDeny_projectsAsExistingDestructive() {
    let rule = RuleID(pack: .coreSecrets, pattern: "env")
    let steps = explainSteps(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "Access to a sensitive path is not allowed."),
                matched: nil
            )
        )
    )
    #expect(steps.last == .destructive(.rule(rule)))
}
