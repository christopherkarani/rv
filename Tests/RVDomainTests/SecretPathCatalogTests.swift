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
        ]
    )
    let reason = "Access to a sensitive path is not allowed."
    #expect(SecretPathCatalog.dayOne.rules.allSatisfy { $0.reason == reason })
    #expect(SecretPathCatalog.dayOne.rules[0].kind == .basename(".env"))
    #expect(SecretPathCatalog.dayOne.rules[1].kind == .envVariant)
    #expect(SecretPathCatalog.dayOne.rules[10].kind == .homeSuffix([".ssh"]))
    #expect(SecretPathCatalog.dayOne.rules[16].kind == .hostAuth([".pi", "agent", "auth.json"]))
}

@Test func secretPathCatalog_matchesCanonicalHostPaths() {
    #expect(SecretPathCatalog.dayOne.firstMatch(of: "/isolated-home/.ssh/config")?.pattern == "home-ssh")
    #expect(SecretPathCatalog.dayOne.firstMatch(of: "/repo/.env")?.pattern == "env")
    #expect(SecretPathCatalog.dayOne.firstMatch(of: "/repo/Sources/Foo.swift") == nil)
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
