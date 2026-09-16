import Testing
import RVDomain
@testable import RVEngine

@Test func documentationQuery_matchesHelpAndVersionOnly() {
    #expect(isDocumentationQuery("unlink --help"))
    #expect(isDocumentationQuery("mkfs --version"))
    #expect(isDocumentationQuery("pvremove -h"))
    #expect(isDocumentationQuery("dropdb --help --version"))
    #expect(isDocumentationQuery("FLUSHALL --help"))
    #expect(isDocumentationQuery("shutdown --help"))
    #expect(isDocumentationQuery("kafka-delete-records.sh --help"))
}

@Test func documentationQuery_rejectsPayloadAndBareCommand() {
    #expect(isDocumentationQuery("unlink") == false)
    #expect(isDocumentationQuery("unlink /tmp/x") == false)
    #expect(isDocumentationQuery("mkfs /dev/sda") == false)
    #expect(isDocumentationQuery("git reset --hard --help") == false)
    #expect(isDocumentationQuery("rm -rf --help") == false)
    #expect(isDocumentationQuery("mkfs --help | less") == false)
    #expect(isDocumentationQuery("pvremove --help --verbose") == false)
}

@Test func evaluate_documentationQuery_allowsCommandNameHelp() throws {
    let result = try runDocs("mkfs --help")
    #expect(result.decision == .allow)
    let unlink = try runDocs("unlink --help")
    #expect(unlink.decision == .allow)
    let bare = try runDocs("mkfs /dev/sda")
    guard case .deny(let deny) = bare.decision else {
        Issue.record("payload must still deny")
        return
    }
    #expect(deny.ruleID.rawValue == "core.filesystem:mkfs-name")
}

@Test func evaluate_documentationQuery_doesNotLiftResetHardHelp() throws {
    let result = try runDocs("git reset --hard --help")
    guard case .deny(let deny) = result.decision else {
        Issue.record("git reset --hard --help must still deny")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
}

private func runDocs(_ command: String) throws -> EvaluationResult {
    let packs = docsPacks()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        engine: engine,
        compiled: compiled
    )
}

private func docsPacks() -> [PackSnapshot] {
    [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["mkfs", "unlink", "rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "mkfs-name",
                    pattern: #"mkfs\s+"#,
                    severity: .high,
                    reason: "mkfs formats a device"
                ),
                DestructiveRule(
                    name: "unlink-name",
                    pattern: #"\bunlink\s+\S"#,
                    severity: .high,
                    reason: "unlink deletes a path"
                ),
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                )
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                )
            ]
        )
    ]
}
