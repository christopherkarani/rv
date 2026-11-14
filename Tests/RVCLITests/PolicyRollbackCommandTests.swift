import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVTheme
@testable import RVCLI

/// `rv policy rollback`: preview by default, `--save` behind the same owner
/// check as `rv policy apply --save`, then the store's gated rollback.
@Suite("PolicyRollbackCommand")
struct PolicyRollbackCommandTests {
    @Test func isRegisteredUnderPolicy() {
        let children = Policy.configuration.subcommands.map { $0.configuration.commandName }
        #expect(children.contains("rollback"))
        #expect(Policy.helpMessage().contains("rollback"))
        let help = HelpDispatch.text(.policy, palette: colorOffPalette)
        #expect(help.contains("rv policy rollback <revision> [--repo] [--save]"))
        #expect(help.contains("rv policy show --revision <n> [--repo]"))
    }

    @Test func revisionArgumentAcceptsListSpelling() {
        #expect(PolicyRevisionNumber(argument: "3")?.value == 3)
        #expect(PolicyRevisionNumber(argument: "r12")?.value == 12)
        for bad in ["0", "r0", "-1", "r", "", "x", "r1x", "+2", "1.0", "٣"] {
            #expect(PolicyRevisionNumber(argument: bad) == nil, "\(bad)")
        }
    }

    @Test func previewPrintsDiffAndRiskWithoutWriting() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([denyPush])
            try fixture.saveMachine([denyPush, allowDiscard])
            let before = try fixture.snapshot()
            let output = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: output
            ) {
                try await PolicyRollbackCommand.parse(["r1"]).run()
            }

            let text = output.stdout
            #expect(text.contains("rollback machine r1"))
            #expect(text.contains("restore: r1 "))
            #expect(text.contains("head:    r2 "))
            #expect(text.contains("recorded "))
            #expect(text.contains("  - typed.git:discard-allow allow gitDiscardWorktree pathspec=- (machine)"))
            #expect(text.contains("risk: none"))
            #expect(text.contains("preview only: nothing was written; add --save to restore"))
            // Authenticated or not, a preview never writes.
            #expect(try fixture.snapshot() == before)
        }
    }

    @Test func saveIsRefusedAtTheOwnerCheckExactlyLikeApply() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([denyPush])
            try fixture.saveMachine([denyPush, allowDiscard])
            let share = fixture.workspace.appendingPathComponent("share.toml")
            try PolicyDocumentTOML.render(PolicyDocument(rules: [askReset])).write(
                to: share, atomically: true, encoding: .utf8)
            let before = try fixture.snapshot()
            let rollbackOutput = CLIOutputCapture()
            let applyOutput = CLIOutputCapture()

            // No owner authentication given: both mutations refuse the same way.
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path, output: rollbackOutput
            ) {
                await #expect(throws: ExitCode(OwnerConfirmation.refusalExitCode)) {
                    try await PolicyRollbackCommand.parse(["1", "--save"]).run()
                }
            }
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path, output: applyOutput
            ) {
                await #expect(throws: ExitCode(OwnerConfirmation.refusalExitCode)) {
                    try await Policy.Apply.parse([share.path, "--save"]).run()
                }
            }

            #expect(rollbackOutput.stderr == "rv: roll the machine policy back to r1 needs owner authentication, which was not given\n")
            #expect(applyOutput.stderr.hasSuffix("needs owner authentication, which was not given\n"))
            #expect(try fixture.snapshot() == before)
        }
    }

    @Test func authenticatedSaveRestoresAsNewHead() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([denyPush])
            try fixture.saveMachine([denyPush, allowDiscard])
            let output = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: output
            ) {
                try await PolicyRollbackCommand.parse(["1", "--save"]).run()
            }

            #expect(output.stdout.contains("rollback machine r1"))
            #expect(output.stdout.hasSuffix("restored r1 as r3\n"))
            #expect(try fixture.session.loadMachineDocument().rules == [denyPush])
            let revisions = try fixture.session.listRevisions(layer: .machine)
            #expect(revisions.map(\.revision) == [1, 2, 3])
            #expect(revisions[2].hash == revisions[0].hash)
        }
    }

    @Test func relaxingRestoreIsRefusedWithExitTwo() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([allowPush])
            try fixture.saveMachine([denyPush])
            let before = try fixture.snapshot()
            let preview = CLIOutputCapture()
            let saved = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: preview
            ) {
                try await PolicyRollbackCommand.parse(["1"]).run()
            }
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: saved
            ) {
                await #expect(throws: ExitCode(2)) {
                    try await PolicyRollbackCommand.parse(["1", "--save"]).run()
                }
            }

            #expect(preview.stdout.contains("[blocking] verdict-relaxed"))
            #expect(preview.stdout.contains("preview only: --save would be refused"))
            #expect(saved.stdout.contains("refused: nothing was written"))
            #expect(saved.stderr == "rv policy rollback: blocked by policy risk findings\n")
            #expect(try fixture.snapshot() == before)
        }
    }

    @Test func unknownRevisionAndBrokenLogsRefuse() async throws {
        try await withRollbackFixture { fixture in
            let empty = CLIOutputCapture()
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: empty
            ) {
                await #expect(throws: ExitCode(1)) {
                    try await PolicyRollbackCommand.parse(["1", "--save"]).run()
                }
            }
            #expect(empty.stderr == "rv policy rollback: unknown revision r1 (see rv policy list)\n")

            try fixture.saveMachine([denyPush])
            try fixture.saveMachine([denyPush, allowDiscard])
            let unknown = CLIOutputCapture()
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: unknown
            ) {
                await #expect(throws: ExitCode(1)) {
                    try await PolicyRollbackCommand.parse(["9"]).run()
                }
            }
            #expect(unknown.stderr == "rv policy rollback: unknown revision r9 (see rv policy list)\n")

            let display = fixture.store.machineRevisionsURL
            let lines = try String(contentsOf: display, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
            try (String(lines[0]) + "\n").write(to: display, atomically: true, encoding: .utf8)
            let corrupted = CLIOutputCapture()
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: corrupted
            ) {
                await #expect(throws: ExitCode(1)) {
                    try await PolicyRollbackCommand.parse(["1", "--save"]).run()
                }
            }
            #expect(corrupted.stderr == "rv policy rollback: the policy revision log failed verification; nothing was changed\n")

            try FileManager.default.removeItem(at: display)
            let missing = CLIOutputCapture()
            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: missing
            ) {
                await #expect(throws: ExitCode(1)) {
                    try await PolicyRollbackCommand.parse(["1", "--save"]).run()
                }
            }
            #expect(missing.stderr == "rv policy rollback: the policy revision log is missing; nothing was changed\n")
            #expect(try fixture.session.loadMachineDocument().rules == [denyPush, allowDiscard])
        }
    }

    @Test func repoScopePreviewsAndRestoresTheRepoLayer() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([denyPush])
            try fixture.session.upsert(askReset, layer: .repo)
            try fixture.session.upsert(allowDiscard, layer: .repo)
            let preview = CLIOutputCapture()
            let saved = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: preview
            ) {
                try await PolicyRollbackCommand.parse(["1", "--repo"]).run()
                await #expect(throws: ExitCode(1)) {
                    try await PolicyRollbackCommand.parse(["3", "--repo"]).run()
                }
            }
            #expect(preview.stdout.contains("rollback repo r1"))
            #expect(preview.stdout.contains("  - typed.git:discard-allow allow gitDiscardWorktree pathspec=- (repo)"))
            #expect(preview.stderr == "rv policy rollback: unknown revision r3 (see rv policy list --repo)\n")

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: saved
            ) {
                try await PolicyRollbackCommand.parse(["1", "--repo", "--save"]).run()
            }
            #expect(saved.stdout.hasSuffix("restored r1 as r3\n"))
            #expect(try fixture.session.loadRepoDocument().rules == [askReset])
            #expect(try fixture.session.loadMachineDocument().rules == [denyPush])
            #expect(try fixture.session.listRevisions(layer: .machine).count == 1)
        }
    }

    @Test func jsonShapeForPreviewAndRestore() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([denyPush])
            try fixture.saveMachine([denyPush, allowDiscard])
            let preview = CLIOutputCapture()
            let saved = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: preview
            ) {
                try await PolicyRollbackCommand.parse(["1", "--json"]).run()
            }
            let document = try jsonObject(preview.stdout)
            #expect(Set(document.keys) == ["schema", "layer", "outcome", "target", "head", "live_parses", "effective", "risk"])
            #expect(document["schema"] as? String == "rv.policy.rollback.v1")
            #expect(document["layer"] as? String == "machine")
            #expect(document["outcome"] as? String == "preview")
            #expect(document["live_parses"] as? Bool == true)
            let target = try #require(document["target"] as? [String: Any])
            #expect(Set(target.keys) == ["revision", "hash", "rule_count", "recorded_at"])
            #expect(target["revision"] as? Int == 1)
            #expect((target["recorded_at"] as? String)?.hasSuffix("Z") == true)
            #expect((document["head"] as? [String: Any])?["revision"] as? Int == 2)
            let effective = try #require(document["effective"] as? [String: Any])
            #expect((effective["added"] as? [Any])?.isEmpty == true)
            #expect((effective["changed"] as? [Any])?.isEmpty == true)
            let removed = try #require(effective["removed"] as? [[String: Any]])
            #expect(removed.count == 1)
            #expect(removed.first?["verdict"] as? String == "allow")
            let risk = try #require(document["risk"] as? [String: Any])
            #expect(risk["blocking"] as? Int == 0)
            #expect(preview.stdout.contains("toml") == false)

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: saved
            ) {
                try await PolicyRollbackCommand.parse(["1", "--save", "--json"]).run()
            }
            // One JSON document, no human preview mixed in.
            let restored = try jsonObject(saved.stdout)
            #expect(restored["outcome"] as? String == "restored")
            #expect((restored["restored_as"] as? [String: Any])?["revision"] as? Int == 3)
        }
    }

    @Test func blockedJsonCarriesTheFindings() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([allowPush])
            try fixture.saveMachine([denyPush])
            let output = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path,
                ownerAuthOutcome: .authenticated, output: output
            ) {
                await #expect(throws: ExitCode(2)) {
                    try await PolicyRollbackCommand.parse(["1", "--save", "--json"]).run()
                }
            }
            let document = try jsonObject(output.stdout)
            #expect(document["outcome"] as? String == "blocked")
            let risk = try #require(document["risk"] as? [String: Any])
            #expect(risk["blocking"] as? Int == 1)
            let findings = try #require(risk["findings"] as? [[String: Any]])
            #expect(findings.first?["kind"] as? String == "verdict-relaxed")
            #expect(findings.first?["severity"] as? String == "blocking")
        }
    }

    @Test func showRevisionPrintsThatRevisionsTOML() async throws {
        try await withRollbackFixture { fixture in
            try fixture.saveMachine([denyPush])
            try fixture.saveMachine([denyPush, allowDiscard])
            let output = CLIOutputCapture()

            try await withCLIProcess(
                home: fixture.home, workspacePath: fixture.workspace.path, output: output
            ) {
                try await Policy.Show.parse(["--revision", "r1"]).run()
                await #expect(throws: ExitCode(1)) {
                    try await Policy.Show.parse(["--revision", "4"]).run()
                }
            }
            let entries = try fixture.session.listRevisions(layer: .machine)
            #expect(output.stdout == entries[0].toml)
            #expect(try PolicyDocumentTOML.parse(output.stdout).rules == [denyPush])
            #expect(output.stderr == "rv policy show: unknown revision r4 (see rv policy list)\n")
            #expect(throws: (any Error).self) { try Policy.Show.parse(["--revision", "1", "--effective"]) }
            #expect(throws: (any Error).self) { try Policy.Show.parse(["--repo"]) }
        }
    }
}

private let denyPush = PolicyDocumentRule(
    id: RuleID(pack: .coreGit, pattern: "force-push-main"),
    verdict: .deny,
    predicate: .gitPush(force: .exactly(.force), branch: "main")
)

private let allowPush = PolicyDocumentRule(
    id: RuleID(pack: .coreGit, pattern: "force-push-main"),
    verdict: .allow,
    predicate: .gitPush(force: .exactly(.force), branch: "main")
)

private let allowDiscard = PolicyDocumentRule(
    id: RuleID(pack: .typedGit, pattern: "discard-allow"),
    verdict: .allow,
    predicate: .gitDiscardWorktree(pathspec: nil)
)

private let askReset = PolicyDocumentRule(
    id: RuleID(pack: .typedGit, pattern: "reset-ask"),
    verdict: .ask,
    predicate: .gitReset(mode: nil)
)



private struct RollbackFixture {
    let home: HomeDirectory
    let workspace: URL
    var config: URL { RVPolicyPaths.configDirectory(home: home) }
    var session: PolicyWorkspace { PolicyWorkspace(home: home, workspace: workspace) }
    var store: TypedRuleStore { TypedRuleStore(baseDirectory: config) }

    func saveMachine(_ rules: [PolicyDocumentRule]) throws {
        try store.saveMachine(PolicyDocument(rules: rules))
    }

    /// Every regular file under HOME and the workspace with its bytes.
    func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for root in [URL(fileURLWithPath: home.rawValue, isDirectory: true), workspace] {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = enumerator?.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files[url.path] = try Data(contentsOf: url)
                }
            }
        }
        return files
    }
}

private func withRollbackFixture(_ body: (RollbackFixture) async throws -> Void) async throws {
    let home = try isolatedHome()
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rollback-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: home.rawValue, isDirectory: true))
        try? FileManager.default.removeItem(at: workspace)
    }
    try await body(RollbackFixture(home: home, workspace: workspace))
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
