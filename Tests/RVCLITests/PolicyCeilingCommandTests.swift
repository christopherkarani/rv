import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
import Synchronization
@testable import RVCLI

@Suite("PolicyCeilingCommand")
struct PolicyCeilingCommandTests {
    private let ceilingText = """
        schema_version = 1

        [[rule]]
        id = "typed.git:no-force-push"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        """

    private let allowMain = """
        schema_version = 1

        [[rule]]
        id = "typed.git:allow-main"
        verdict = "allow"
        predicate = "gitPush"
        branch = "main"
        """

    private let askForce = """
        schema_version = 1

        [[rule]]
        id = "typed.git:ask-force-main"
        verdict = "ask"
        predicate = "gitPush"
        force = "force"
        branch = "main"
        """

    @Test func subcommandsAreRegistered() {
        let children = Policy.configuration.subcommands.map { $0.configuration.commandName }
        #expect(children.contains("check"))
        #expect(children.contains("ceiling"))
        #expect(PolicyCeilingCommand.configuration.subcommands.map { $0.configuration.commandName } == ["show", "set"])
    }

    @Test func check_withoutCeiling_boundsNothing() throws {
        try withCeilingContext { home, workspace in
            let report = try PolicyCeilingRun.check(home: home, workspace: workspace, file: nil)
            #expect(report.ceilingSet == false)
            #expect(report.withinCeiling)
            #expect(report.pretty == "ceiling: none (no ceiling.toml)")
        }
    }

    @Test func check_printsWitnessForTheLayerAboveTheCeiling() throws {
        try withCeilingContext { home, workspace in
            try writeCeiling(ceilingText, home: home)
            try writeRepo(askForce, workspace: workspace)
            let report = try PolicyCeilingRun.check(home: home, workspace: workspace, file: nil)
            #expect(report.withinCeiling == false)
            #expect(report.layers.map(\.status) == ["within", "exceeds"])
            #expect(report.layers[1].witness?.command == "git push --force origin main")
            #expect(report.pretty.contains(
                "repo: exceeds the ceiling\n  witness: rv why 'git push --force origin main'"), "\(report.pretty)")
            let robot = try RobotJSON.encode(report)
            #expect(robot.contains("git push --force origin main"))
        }
    }

    @Test func check_layerAllowUnderCeiling_isAdvisoryNotExceeding() throws {
        try withCeilingContext { home, workspace in
            try writeCeiling(ceilingText, home: home)
            try writeRepo(allowMain, workspace: workspace)
            let report = try PolicyCeilingRun.check(home: home, workspace: workspace, file: nil)
            #expect(report.withinCeiling)
            #expect(report.layers.map(\.status) == ["within", "within"])
            #expect(report.layers[1].advisory?.command == "git push --force origin main")
            #expect(report.pretty.contains("  note: rule typed.git:allow-main says allow on"), "\(report.pretty)")
        }
    }

    @Test func checkCommand_exitCodesSeparateExceedsFromInvalid() async throws {
        let (home, workspace) = try makeDirs()
        defer { cleanup(home, workspace) }
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, workspacePath: workspace.path, output: out) {
            var within = try PolicyCheck.parse(["--ceiling"])
            try await within.run()
            try writeCeiling(ceilingText, home: home)
            try writeRepo(askForce, workspace: workspace)
            var exceeds = try PolicyCheck.parse(["--ceiling"])
            await #expect(throws: ExitCode(1)) { try await exceeds.run() }
            try writeCeiling("schema_version = 1\nbogus = 1\n", home: home)
            var invalid = try PolicyCheck.parse(["--ceiling"])
            await #expect(throws: ExitCode(2)) { try await invalid.run() }
        }
    }

    @Test func check_sharedFile() throws {
        try withCeilingContext { home, workspace in
            try writeCeiling(ceilingText, home: home)
            let share = workspace.appendingPathComponent("share.toml")
            try askForce.write(to: share, atomically: true, encoding: .utf8)
            let report = try PolicyCeilingRun.check(home: home, workspace: workspace, file: share)
            #expect(report.layers.count == 1)
            #expect(report.layers[0].status == "exceeds")
        }
    }

    @Test func check_invalidCeiling_throws() throws {
        try withCeilingContext { home, workspace in
            try writeCeiling("schema_version = 1\nbogus = 1\n", home: home)
            #expect(throws: PolicyCeilingError.invalidFile) {
                _ = try PolicyCeilingRun.check(home: home, workspace: workspace, file: nil)
            }
        }
    }

    @Test func set_savesAfterOwnerConfirmation() async throws {
        try await withAsyncCeilingContext(owner: .authenticated) { home, workspace in
            let file = workspace.appendingPathComponent("ceiling.toml")
            try ceilingText.write(to: file, atomically: true, encoding: .utf8)
            let outcome = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file)
            #expect(outcome.saved)
            let store = PolicyCeilingStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
            #expect(try store.load()?.rules.count == 1)
            #expect(FileManager.default.fileExists(atPath: store.revisionsURL.path))
        }
    }

    @Test func set_invalidRepoFile_isReportedNotRefused() async throws {
        try await withAsyncCeilingContext(owner: .authenticated) { home, workspace in
            try writeRepo("schema_version = 1\nnot toml at all\n", workspace: workspace)
            let file = workspace.appendingPathComponent("ceiling.toml")
            try ceilingText.write(to: file, atomically: true, encoding: .utf8)
            let preview = Mutex<[String]>([])
            let outcome = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file) { lines in
                preview.withLock { $0 = lines }
            }
            #expect(outcome.saved)
            let shown = preview.withLock { $0 }
            #expect(shown.contains("repo: invalid policy file (not checked)"), "\(shown)")
        }
    }

    @Test func set_showsWhatTheNewCeilingLoosens_beforeThePrompt_andStillSaves() async throws {
        try await withAsyncCeilingContext(owner: .authenticated) { home, workspace in
            try writeCeiling(ceilingText, home: home)
            let file = workspace.appendingPathComponent("ceiling.toml")
            try "schema_version = 1\negress.hosts = [\"github.com\"]\n".write(to: file, atomically: true, encoding: .utf8)
            let preview = Mutex<[String]>([])
            let outcome = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file) { lines in
                preview.withLock { $0 = lines }
            }
            #expect(outcome.saved)
            #expect(outcome.lines == ["saved ceiling.toml"])
            let shown = preview.withLock { $0 }
            #expect(shown.contains("this ceiling loosens the current one:"), "\(shown)")
            #expect(shown.contains("  drops deny rule typed.git:no-force-push (gitPush:force:-)"), "\(shown)")
        }
    }

    @Test func set_oversizedOrSpecialSourceFile_isRefusedBeforeThePrompt() async throws {
        try await withAsyncCeilingContext(owner: nil) { home, workspace in
            let file = workspace.appendingPathComponent("ceiling.toml")
            try ("schema_version = 1\n" + String(repeating: "#", count: PolicyCeiling.maximumBytes))
                .write(to: file, atomically: true, encoding: .utf8)
            let outcome = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file)
            #expect(outcome == .init(lines: ["rv policy ceiling set: invalid ceiling file"], saved: false))
            let directory = workspace.appendingPathComponent("dir.toml", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fromDirectory = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: directory)
            #expect(fromDirectory.saved == false)
        }
    }

    @Test func set_recordsTheOwnerAuthorization() async throws {
        try await withAsyncCeilingContext(owner: .authenticated) { home, workspace in
            let file = workspace.appendingPathComponent("ceiling.toml")
            try ceilingText.write(to: file, atomically: true, encoding: .utf8)
            _ = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file)
            let events = AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
                .events(AuditFilter(kinds: ["config"]))
            #expect(events.map(\.subject) == ["policy.ceiling"])
            #expect(events.first?.detail["authorized_by"]?.hasPrefix("owner") == true, "\(events)")
        }
    }

    @Test func set_whenALooseningCannotBeRecorded_exits74() async throws {
        let (home, workspace) = try makeDirs()
        defer { cleanup(home, workspace) }
        let config = RVPolicyPaths.configDirectory(home: home)
        try writeCeiling(ceilingText, home: home)
        let log = AuditLog.fileURL(configDirectory: config)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("loose.toml")
        try "schema_version = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let output = CLIOutputCapture()
        try await withCLIProcess(
            home: home, workspacePath: workspace.path, ownerAuthOutcome: .authenticated, output: output
        ) {
            var command = try PolicyCeilingCommand.SetCeiling.parse([file.path])
            do {
                try await command.run()
                Issue.record("an unrecordable loosening was stored")
            } catch let exit as ExitCode {
                #expect(exit.rawValue == ConfigChangeRefusal.exitCode)
            }
        }
        #expect(output.stderr.hasPrefix(
            "rv policy ceiling set: the audit log could not record the policy.ceiling change"), "\(output.stderr)")
        let store = PolicyCeilingStore(configDirectory: config)
        #expect(try store.load()?.rules.count == 1)
    }

    @Test func set_refusesWhenMachineLayerAlreadyExceeds() async throws {
        try await withAsyncCeilingContext(owner: .authenticated) { home, workspace in
            try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
                .saveMachine(try PolicyDocumentTOML.parse(askForce))
            let file = workspace.appendingPathComponent("ceiling.toml")
            try ceilingText.write(to: file, atomically: true, encoding: .utf8)
            let outcome = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file)
            #expect(outcome.saved == false)
            #expect(outcome.lines.contains("  witness: rv why 'git push --force origin main'"), "\(outcome.lines)")
            let store = PolicyCeilingStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
            #expect(try store.load() == nil)
        }
    }

    @Test func set_withoutOwner_writesNothing() async throws {
        try await withAsyncCeilingContext(owner: nil) { home, workspace in
            let file = workspace.appendingPathComponent("ceiling.toml")
            try ceilingText.write(to: file, atomically: true, encoding: .utf8)
            await #expect(throws: (any Error).self) {
                _ = try await PolicyCeilingRun.set(home: home, workspace: workspace, file: file)
            }
            let store = PolicyCeilingStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
            #expect(try store.load() == nil)
        }
    }

    @Test func applySave_aboveCeiling_isRefusedWithWitness() async throws {
        try await withAsyncCeilingContext(owner: .authenticated) { home, workspace in
            try writeCeiling(ceilingText, home: home)
            let session = PolicyWorkspace(home: home, workspace: workspace)
            do {
                _ = try session.mergeIncoming(try PolicyDocumentTOML.parse(askForce), layer: .repo, save: true)
                Issue.record("expected a ceiling refusal")
            } catch let error as PolicyCeilingError {
                #expect(error.refusal.hasPrefix("git push --force origin main exceeds the policy ceiling"))
                #expect(error.refusal.contains("check: rv why 'git push --force origin main'"), "\(error.refusal)")
            }
        }
    }

    // MARK: Helpers

    private func writeCeiling(_ text: String, home: HomeDirectory) throws {
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try text.write(to: RVPolicyPaths.policyCeilingFile(inConfigDir: config), atomically: true, encoding: .utf8)
    }

    private func writeRepo(_ text: String, workspace: URL) throws {
        let repoFile = TypedRuleStore.repoFileURL(workspace: workspace)
        try FileManager.default.createDirectory(
            at: repoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: repoFile, atomically: true, encoding: .utf8)
    }

    private func withCeilingContext(_ body: (HomeDirectory, URL) throws -> Void) throws {
        let (home, workspace) = try makeDirs()
        defer { cleanup(home, workspace) }
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            try body(home, workspace)
        }
    }

    private func withAsyncCeilingContext(
        owner: UIAuthenticationOutcome?,
        _ body: (HomeDirectory, URL) async throws -> Void
    ) async throws {
        let (home, workspace) = try makeDirs()
        defer { cleanup(home, workspace) }
        try await withCLIProcess(home: home, workspacePath: workspace.path, ownerAuthOutcome: owner) {
            try await body(home, workspace)
        }
    }

    private func makeDirs() throws -> (HomeDirectory, URL) {
        let home = try isolatedHome()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ceiling-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (home, workspace)
    }

    private func cleanup(_ home: HomeDirectory, _ workspace: URL) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: home.rawValue, isDirectory: true))
        try? FileManager.default.removeItem(at: workspace)
    }
}
