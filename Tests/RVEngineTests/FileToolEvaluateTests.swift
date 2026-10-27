import Testing
import RVDomain
@testable import RVEngine

@Test func evaluateFileTool_deniesCatalogHitWithCoreSecretsPattern() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/rv-oracle/.env"))
    )
    guard case .deny(let deny, let matched) = result.outcome else {
        Issue.record("expected deny for .env")
        return
    }
    #expect(deny.ruleID.rawValue == "core.secrets:env")
    #expect(deny.reason == "Access to a sensitive path is not allowed.")
    #expect(matched?.ruleID.rawValue == "core.secrets:env")
    #expect(matched?.patternName == "env")
    #expect(UnlockableDeny.isPinned(result))
    #expect(UnlockableDeny.matches(result: result, cwd: WorkingDirectory(validating: "/tmp")) == false)
}

@Test func evaluateFileTool_allowsOrdinaryProjectFile() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/rv-oracle/src/main.swift"))
    )
    #expect(result.decision == .allow)
    #expect(UnlockableDeny.isPinned(result) == false)
}

@Test func evaluateFileTool_emptyPathDeniesWithoutPackEvaluate() {
    let result = evaluateFileTool(
        FileToolAction(kind: .write, path: FileToolPath(rawValue: "   "))
    )
    guard case .deny(let deny, _) = result.outcome else {
        Issue.record("expected deny for empty path")
        return
    }
    #expect(deny.ruleID.pack == .coreSecrets)
    #expect(UnlockableDeny.isPinned(result))
}

@Test func evaluateFileTool_allowPathSuppressesProjectEnv() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")),
        secretPaths: SecretPathDecider(allowPaths: SecretAllowPathSet(literals: ["/tmp/rv-oracle/.env"]))
    )
    #expect(result.decision == .allow)
}

@Test func evaluateFileTool_allowPathDoesNotExemptHostAuth() {
    let result = evaluateFileTool(
        FileToolAction(
            kind: .read,
            path: FileToolPath(rawValue: "~/.claude/.credentials.json")
        ),
        secretPaths: SecretPathDecider(allowPaths: SecretAllowPathSet(literals: ["~/.claude/.credentials.json"]))
    )
    guard case .deny(let deny, _) = result.outcome else {
        Issue.record("expected host-auth deny")
        return
    }
    #expect(deny.ruleID.rawValue == "core.secrets:host-claude-auth")
}

@Test func evaluateFileTool_hostAuthHitsArePinned() {
    let result = evaluateFileTool(
        FileToolAction(
            kind: .read,
            path: FileToolPath(rawValue: "~/.claude/.credentials.json")
        )
    )
    guard case .deny(let deny, _) = result.outcome else {
        Issue.record("expected deny for Claude credentials")
        return
    }
    #expect(deny.ruleID.rawValue == "core.secrets:host-claude-auth")
    #expect(UnlockableDeny.isPinned(result))
}

// MARK: - Alias resolution (F-2: symlink aliases must not disarm path rules)

private func mapping(_ pairs: [String: String]) -> SecretPathResolution {
    SecretPathResolution { candidate in pairs[candidate] }
}

@Test func evaluateFileTool_symlinkResolvesToSecretPath() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "$HOME/ss/k")),
        secretPaths: SecretPathDecider(resolution: mapping(["$HOME/ss/k": "~/.ssh/id_rsa"]))
    )
    guard case .deny(let deny, _) = result.outcome else {
        Issue.record("expected deny for resolved id_rsa")
        return
    }
    #expect(deny.ruleID.rawValue == "core.secrets:id-rsa")
    #expect(UnlockableDeny.isPinned(result))
}

@Test func evaluateFileTool_resolvedAliasExemptable() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "$HOME/ss/k")),
        secretPaths: SecretPathDecider(
            allowPaths: SecretAllowPathSet(literals: ["~/.env"]),
            resolution: mapping(["$HOME/ss/k": "~/.env"])
        )
    )
    #expect(result.decision == .allow)
}

@Test func evaluateFileTool_typedExemptDoesNotExemptResolved() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "~/b/.env")),
        secretPaths: SecretPathDecider(
            allowPaths: SecretAllowPathSet(literals: ["~/b/.env"]),
            resolution: mapping(["~/b/.env": "~/.aws/config"])
        )
    )
    guard case .deny(let deny, _) = result.outcome else {
        Issue.record("expected deny for resolved aws config")
        return
    }
    #expect(deny.ruleID.rawValue == "core.secrets:home-aws")
}

@Test func evaluateFileTool_resolvedToBenignPath_overridesTypedMatch() {
    // The file genuinely is /tmp/ok.txt; a typed .env spelling resolving
    // to it must not deny on cosmetics.
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "~/.env")),
        secretPaths: SecretPathDecider(resolution: mapping(["~/.env": "/tmp/ok.txt"]))
    )
    #expect(result.decision == .allow)
}

@Test func evaluateFileTool_noResolution_keepsTypedOnlyBehavior() {
    let result = evaluateFileTool(
        FileToolAction(kind: .read, path: FileToolPath(rawValue: "~/.ssh/id_rsa"))
    )
    guard case .deny(let deny, _) = result.outcome else {
        Issue.record("expected deny for id_rsa")
        return
    }
    #expect(deny.ruleID.rawValue == "core.secrets:id-rsa")
}
