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
        allowPaths: SecretAllowPathSet(literals: ["/tmp/rv-oracle/.env"])
    )
    #expect(result.decision == .allow)
}

@Test func evaluateFileTool_allowPathDoesNotExemptHostAuth() {
    let result = evaluateFileTool(
        FileToolAction(
            kind: .read,
            path: FileToolPath(rawValue: "~/.claude/.credentials.json")
        ),
        allowPaths: SecretAllowPathSet(literals: ["~/.claude/.credentials.json"])
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
