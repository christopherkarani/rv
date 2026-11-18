import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// `PolicyWorkspace.loadStatus()`: what evaluation loads for one (config
/// dir, workspace), via the same `loadEffective` step order the door uses.
@Suite("PolicyLoadStatus")
struct PolicyLoadStatusTests {
    private let denyForcePush = """
        schema_version = 1

        [[rule]]
        id = "typed.git:no-force-push"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        """

    private let askForcePush = """
        schema_version = 1

        [[rule]]
        id = "typed.git:ask-force-push"
        verdict = "ask"
        predicate = "gitPush"
        force = "force"
        """

    @Test func cleanLoad_reportsLoadedWithEachLayersHash() throws {
        try withDirs { dirs in
            let machine = try PolicyDocumentTOML.parse(askForcePush)
            try TypedRuleStore(baseDirectory: dirs.config).saveMachine(machine)

            let status = dirs.session.loadStatus()

            #expect(status.state == .loaded)
            #expect(status.failure == nil)
            #expect(status.machine?.hash == PolicyRevisionIdentity.hash(machine))
            #expect(status.machine?.ruleCount == 1)
            #expect(status.machine?.exceedsCeiling == false)
            #expect(status.repo?.hash == PolicyRevisionIdentity.hash(PolicyDocument()))
            #expect(status.repo?.ruleCount == 0)
            #expect(status.ceilingRuleCount == nil)
            #expect(status.effectiveRuleCount == 1)
            #expect(status.configDirectory == dirs.config.path)
            #expect(status.workspace == dirs.repo.path)
            // The same load evaluation runs: it agrees with loadEffectiveRules.
            #expect(try dirs.session.loadEffectiveRules().count == status.effectiveRuleCount)
        }
    }

    @Test func corruptMachinePolicy_isFailedWithTheReason() throws {
        try withDirs { dirs in
            try "schema_version = 1\n[[rule]]\nverdict = ???\n".write(
                to: TypedRuleStore(baseDirectory: dirs.config).machineFileURL, atomically: true, encoding: .utf8)

            let status = dirs.session.loadStatus()

            #expect(status.state == .failed)
            #expect(status.failure == .machineInvalid)
            #expect(status.machine == nil)
            #expect(status.effectiveRuleCount == nil)
            // Evaluation fails closed on the same input: no last-good fallback.
            #expect(throws: TypedRuleStoreError.invalidFile) { try dirs.session.loadEffectiveRules() }
        }
    }

    @Test func corruptRepoPolicy_isFailedAsRepo() throws {
        try withDirs { dirs in
            let url = TypedRuleStore.repoFileURL(workspace: dirs.repo)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "not toml at all [[[".write(to: url, atomically: true, encoding: .utf8)

            let status = dirs.session.loadStatus()

            #expect(status.state == .failed)
            #expect(status.failure == .repoInvalid)
        }
    }

    @Test func invalidCeiling_isFailedAsCeiling() throws {
        try withDirs { dirs in
            try "schema_version = 1\nverdict = allow\n".write(
                to: RVPolicyPaths.policyCeilingFile(inConfigDir: dirs.config), atomically: true, encoding: .utf8)

            let status = dirs.session.loadStatus()

            #expect(status.state == .failed)
            #expect(status.failure == .ceilingInvalid)
            #expect(throws: PolicyCeilingError.invalidFile) { try dirs.session.loadEffectiveRules() }
        }
    }

    /// A hand-edited layer that asks where the ceiling denies still loads:
    /// the ceiling's deny wins at evaluation. Status says so instead of
    /// claiming a failure evaluation does not have.
    @Test func layerExceedingTheCeiling_loadsAndIsFlagged() throws {
        try withDirs { dirs in
            try denyForcePush.write(
                to: RVPolicyPaths.policyCeilingFile(inConfigDir: dirs.config), atomically: true, encoding: .utf8)
            // Written past the store's save gate, as a hand edit would be.
            try askForcePush.write(
                to: TypedRuleStore(baseDirectory: dirs.config).machineFileURL, atomically: true, encoding: .utf8)

            let status = dirs.session.loadStatus()

            #expect(status.state == .loaded)
            #expect(status.machine?.exceedsCeiling == true)
            #expect(status.repo?.exceedsCeiling == false)
            #expect(status.ceilingRuleCount == 1)
            #expect(try dirs.session.loadEffectiveRules().first?.verdict == .deny)
        }
    }

    @Test func noWorkspace_hasNoRepoLayer() throws {
        try withDirs { dirs in
            let status = PolicyWorkspace(configDirectory: dirs.config).loadStatus()
            #expect(status.state == .loaded)
            #expect(status.repo == nil)
            #expect(status.workspace == nil)
        }
    }

    @Test func noHome_hasNoMachineLayer_andStillLoadsRepo() throws {
        try withDirs { dirs in
            let status = PolicyWorkspace(home: nil, workspace: dirs.repo).loadStatus()
            #expect(status.state == .loaded)
            #expect(status.machine == nil)
            #expect(status.configDirectory == nil)
            #expect(status.repo != nil)
        }
    }

    // MARK: File shape

    /// A repo whose `.rv` is a file has no repo policy (ENOTDIR reads as
    /// absent, as `fileExists` did), so it loads instead of denying.
    @Test func repoDotRvIsAFile_readsAsAbsent() throws {
        try withDirs { dirs in
            try "not a directory".write(
                to: dirs.repo.appendingPathComponent(".rv"), atomically: true, encoding: .utf8)

            let status = dirs.session.loadStatus()

            #expect(status.state == .loaded)
            #expect(status.repo?.hash == PolicyRevisionIdentity.hash(PolicyDocument()))
            #expect(try dirs.session.loadEffectiveRules().isEmpty)
        }
    }

    /// A machine config directory that is a file reads as no machine policy,
    /// but the ceiling step refuses it (only ENOENT is "no ceiling"), so
    /// evaluation denies.
    @Test func machineConfigDirIsAFile_deniesViaTheCeiling() throws {
        try withDirs { dirs in
            try FileManager.default.removeItem(at: dirs.config)
            try "not a directory".write(to: dirs.config, atomically: true, encoding: .utf8)

            let status = dirs.session.loadStatus()

            #expect(status.state == .failed)
            #expect(status.failure == .ceilingInvalid)
            #expect(status.problem == .unreadable)
            #expect(throws: PolicyCeilingError.invalidFile) { try dirs.session.loadEffectiveRules() }
        }
    }

    @Test func nonUTF8Policy_isFailedAsNotUTF8() throws {
        try withDirs { dirs in
            try Data([0x73, 0xFF, 0xFE, 0x0A]).write(to: TypedRuleStore(baseDirectory: dirs.config).machineFileURL)

            let status = dirs.session.loadStatus()

            #expect(status.failure == .machineInvalid)
            #expect(status.problem == .notUTF8)
        }
    }

    /// The ceiling still never follows a symlink, even to a valid file.
    @Test func symlinkedCeiling_isFailedAsSymlink() throws {
        try withDirs { dirs in
            let target = dirs.repo.appendingPathComponent("ceiling-elsewhere.toml")
            try denyForcePush.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: RVPolicyPaths.policyCeilingFile(inConfigDir: dirs.config), withDestinationURL: target)

            let status = dirs.session.loadStatus()

            #expect(status.failure == .ceilingInvalid)
            #expect(status.problem == .symlink)
        }
    }

    /// A save evaluation could not load is refused with nothing written.
    @Test func saveLargerThanTheCap_isRefusedAndNothingChanges() throws {
        try withDirs { dirs in
            let store = TypedRuleStore(baseDirectory: dirs.config)
            let small = try PolicyDocumentTOML.parse(denyForcePush)
            try store.saveMachine(small)
            let before = try Data(contentsOf: store.machineFileURL)
            let rules = (0..<20_000).map { index in
                PolicyDocumentRule(
                    id: RuleID(rawValue: "typed.git:bulk-\(index)")!, verdict: .deny, predicate: .gitReset(mode: nil))
            }

            #expect(throws: TypedRuleStoreError.documentTooLarge) {
                try store.saveMachine(PolicyDocument(rules: rules))
            }

            #expect(try Data(contentsOf: store.machineFileURL) == before)
            #expect(try store.loadMachineDocument().rules.map(\.id) == small.rules.map(\.id))
        }
    }

    @Test func statusRoundTripsThroughJSON() throws {
        try withDirs { dirs in
            let status = dirs.session.loadStatus()
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(PolicyLoadStatus.self, from: data) == status)
        }
    }

    // MARK: Helpers

    private struct Dirs {
        var config: URL
        var repo: URL
        var session: PolicyWorkspace { PolicyWorkspace(configDirectory: config, workspace: repo) }
    }

    private func withDirs(_ body: (Dirs) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-load-status-\(UUID().uuidString)", isDirectory: true)
        let dirs = Dirs(
            config: root.appendingPathComponent("config", isDirectory: true),
            repo: root.appendingPathComponent("repo", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: dirs.config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(dirs)
    }
}
