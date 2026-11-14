import Foundation
import Testing
import RVDomain
@testable import RVPolicy

@Suite("PolicyCeiling")
struct PolicyCeilingTests {
    private let forcePushCeiling = """
        schema_version = 1
        egress.hosts = ["github.com", "*.githubusercontent.com"]

        [[rule]]
        id = "typed.git:no-force-push"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        """

    private let allowMainLayer = """
        schema_version = 1

        [[rule]]
        id = "typed.git:allow-main"
        verdict = "allow"
        predicate = "gitPush"
        branch = "main"
        """

    // MARK: Parse

    @Test func parsesRulesAndEgressHosts_andRoundTrips() throws {
        let ceiling = try PolicyCeilingTOML.parse(forcePushCeiling)
        #expect(ceiling.rules.count == 1)
        #expect(ceiling.rules[0].verdict == .deny)
        #expect(ceiling.egressHosts == ["github.com", "*.githubusercontent.com"])
        #expect(try PolicyCeilingTOML.parse(PolicyCeilingTOML.render(ceiling)) == ceiling)
        let bare = try PolicyCeilingTOML.parse("schema_version = 1\n")
        #expect(bare == PolicyCeiling())
        #expect(try PolicyCeilingTOML.parse(PolicyCeilingTOML.render(bare)) == bare)
    }

    @Test(arguments: [
        // An allow rule bounds nothing; it is a typo for deny or ask.
        "schema_version = 1\n[[rule]]\nid = \"typed.git:a\"\nverdict = \"allow\"\npredicate = \"filesystemMove\"\n",
        "schema_version = 1\nsafety.level = \"strict\"\n",
        "schema_version = 1\nsecret.allow_paths = [\"/tmp/x\"]\n",
        "schema_version = 1\nunknown = 1\n",
        "egress.hosts = []\n",
        "schema_version = 2\n",
        "schema_version = 1\nschema_version = 1\n",
        "schema_version = 1\negress.hosts = [\"*\"]\n",
        "schema_version = 1\negress.hosts = [\"*github.com\"]\n",
        "schema_version = 1\negress.hosts = [\"10.0.0.1\"]\n",
        "schema_version = 1\negress.hosts = [\"github.com:443\"]\n",
        "schema_version = 1\negress.hosts = [\"a.com\"]\negress.hosts = [\"b.com\"]\n",
        "schema_version = 1\n[[rule]]\nid = \"typed.git:a\"\nverdict = \"deny\"\npredicate = \"nope\"\n",
    ])
    func rejectsAnythingThatCouldWidenTheBound(text: String) {
        #expect(throws: PolicyCeilingError.invalidFile) { try PolicyCeilingTOML.parse(text) }
    }

    // MARK: Egress

    @Test func egressHosts_exactAndSubdomainWildcard() throws {
        let ceiling = try PolicyCeilingTOML.parse(forcePushCeiling)
        #expect(ceiling.egressWitness(host: "github.com", port: 443) == nil)
        #expect(ceiling.egressWitness(host: "GitHub.com.", port: 443) == nil)
        #expect(ceiling.egressWitness(host: "raw.githubusercontent.com", port: 443) == nil)
        // The wildcard is subdomains only, and never a suffix match on a label.
        #expect(ceiling.egressWitness(host: "githubusercontent.com", port: 443) != nil)
        #expect(ceiling.egressWitness(host: "evilgithub.com", port: 443) != nil)
        let witness = try #require(ceiling.egressWitness(host: "Pastebin.com", port: 8443))
        #expect(witness.command == "CONNECT pastebin.com:8443")
        #expect(throws: PolicyCeilingError.egressExceeds(witness)) {
            try ceiling.requireEgress(host: "pastebin.com", port: 8443)
        }
    }

    @Test func egressUnboundedWhenAbsent_closedWhenEmpty() throws {
        #expect(PolicyCeiling().egressWitness(host: "pastebin.com", port: 443) == nil)
        let closed = try PolicyCeilingTOML.parse("schema_version = 1\negress.hosts = []\n")
        #expect(closed.egressWitness(host: "github.com", port: 443) != nil)
    }

    // MARK: Layers

    @Test func repoLayerAboveCeiling_isRefusedAtLoadWithWitness() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            try writeRepo(allowMainLayer, workspace)
            do {
                _ = try workspace.loadEffectiveRules()
                Issue.record("expected a ceiling refusal")
            } catch PolicyCeilingError.exceeds(let witness) {
                #expect(witness.command == "git push --force origin main")
                #expect(witness.candidateRule.rawValue == "typed.git:allow-main")
                #expect(witness.ceilingRule.rawValue == "typed.git:no-force-push")
                let refusal = PolicyCeilingError.exceeds(witness).refusal
                #expect(refusal.contains("git push --force origin main"))
            }
        }
    }

    @Test func machineLayerAboveCeiling_isRefusedAtLoad() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            try workspace.machineStore.saveMachine(try PolicyDocumentTOML.parse(allowMainLayer))
            #expect(throws: PolicyCeilingError.self) { try workspace.loadEffectiveRules() }
        }
    }

    @Test func layersWithinCeiling_loadAsBefore() throws {
        try withPolicyDirs { workspace in
            try writeRepo(allowMainLayer, workspace)
            let before = try workspace.loadEffectiveRules()
            try writeCeiling("schema_version = 1\n[[rule]]\nid = \"typed.git:no-reset\"\nverdict = \"deny\"\npredicate = \"gitReset\"\n", workspace)
            #expect(try workspace.loadEffectiveRules() == before)
            #expect(before.count == 1)
        }
    }

    @Test func invalidCeiling_failsClosedAtLoad() throws {
        try withPolicyDirs { workspace in
            try writeCeiling("schema_version = 1\nverdict = allow\n", workspace)
            #expect(throws: PolicyCeilingError.invalidFile) { try workspace.loadEffectiveRules() }
        }
    }

    @Test func saveAboveCeiling_isRefusedAndWritesNothing() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            let incoming = try PolicyDocumentTOML.parse(allowMainLayer)
            #expect(throws: PolicyCeilingError.self) {
                _ = try workspace.mergeIncoming(incoming, layer: .machine, save: true)
            }
            #expect(FileManager.default.fileExists(atPath: workspace.machineStore.machineFileURL.path) == false)
            // A tightening save is still accepted.
            let tighten = PolicyDocument(rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "deny-main"),
                    verdict: .deny,
                    predicate: .gitPush(force: .any, branch: "main")
                ),
            ])
            _ = try workspace.mergeIncoming(tighten, layer: .machine, save: true)
            #expect(try workspace.loadMachineDocument().rules.count == 1)
            // A preview is never refused: it writes nothing.
            _ = try workspace.mergeIncoming(incoming, layer: .machine, save: false)
        }
    }

    @Test func storeSaveIsOwnerOnlyAndLoads() throws {
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            #expect(try store.load() == nil)
            let ceiling = try PolicyCeilingTOML.parse(forcePushCeiling)
            try store.save(ceiling)
            #expect(try store.load() == ceiling)
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int)
            #expect(mode & 0o777 == 0o600)
        }
    }

    // MARK: Helpers

    private struct Dirs {
        var config: URL
        var repo: URL
        var session: PolicyWorkspace { PolicyWorkspace(configDirectory: config, workspace: repo) }
        var machineStore: TypedRuleStore { TypedRuleStore(baseDirectory: config) }

        func loadEffectiveRules() throws -> [TypedRule] { try session.loadEffectiveRules() }
        func loadMachineDocument() throws -> PolicyDocument { try session.loadMachineDocument() }
        func mergeIncoming(_ document: PolicyDocument, layer: PolicyDocumentLayer, save: Bool) throws -> PolicyDocument {
            try session.mergeIncoming(document, layer: layer, save: save)
        }
    }

    private func withPolicyDirs(_ body: (Dirs) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ceiling-\(UUID().uuidString)", isDirectory: true)
        let dirs = Dirs(
            config: root.appendingPathComponent("config", isDirectory: true),
            repo: root.appendingPathComponent("repo", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: dirs.config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(dirs)
    }

    private func writeCeiling(_ text: String, _ dirs: Dirs) throws {
        try text.write(to: RVPolicyPaths.policyCeilingFile(inConfigDir: dirs.config), atomically: true, encoding: .utf8)
    }

    private func writeRepo(_ text: String, _ dirs: Dirs) throws {
        let url = TypedRuleStore.repoFileURL(workspace: dirs.repo)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
