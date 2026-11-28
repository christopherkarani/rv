#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVHistory
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

    // MARK: Evaluation overlay

    private let askForcePushLayer = """
        schema_version = 1

        [[rule]]
        id = "typed.git:ask-force"
        verdict = "ask"
        predicate = "gitPush"
        force = "force"
        """

    private static let forcePushMain = SemanticAction.git(.push(remote: "origin", refspec: "main", force: .force))

    @Test func ceilingDeny_appliesWhereLayersAreSilent() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            let rules = try workspace.loadEffectiveRules()
            #expect(rules.map(\.id.rawValue) == ["typed.git:no-force-push"])
            let verdict = try #require(ActionPolicyEngine.typedRestriction(Self.forcePushMain, rules: rules))
            guard case .hardDeny = verdict.decision else {
                Issue.record("ceiling deny must deny with silent layers")
                return
            }
        }
    }

    @Test func repoAllowUnderCeiling_loads_andTheCeilingStillDenies() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            try writeRepo(allowMainLayer, workspace)
            let rules = try workspace.loadEffectiveRules()
            let verdict = try #require(ActionPolicyEngine.typedRestriction(Self.forcePushMain, rules: rules))
            guard case .hardDeny = verdict.decision else {
                Issue.record("a layer allow must not lift the ceiling")
                return
            }
        }
    }

    @Test func machineAskUnderCeilingDeny_loads_andTheDenyWins() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            try workspace.machineStore.saveMachine(try PolicyDocumentTOML.parse(askForcePushLayer))
            let rules = try workspace.loadEffectiveRules()
            // Same predicate: the restrict-only overlay keeps the stronger verdict.
            #expect(rules.count == 1)
            #expect(rules.first?.verdict == .deny)
            let verdict = try #require(ActionPolicyEngine.typedRestriction(Self.forcePushMain, rules: rules))
            guard case .hardDeny = verdict.decision else {
                Issue.record("ceiling deny must win over a layer ask")
                return
            }
        }
    }

    @Test func layersKeepTheirRules_andGainTheCeiling() throws {
        try withPolicyDirs { workspace in
            try writeRepo(allowMainLayer, workspace)
            let before = try workspace.loadEffectiveRules()
            try writeCeiling("schema_version = 1\n[[rule]]\nid = \"typed.git:no-reset\"\nverdict = \"deny\"\npredicate = \"gitReset\"\n", workspace)
            let after = try workspace.loadEffectiveRules()
            #expect(Array(after.prefix(before.count)) == before)
            #expect(after.dropFirst(before.count).map(\.id.rawValue) == ["typed.git:no-reset"])
        }
    }

    @Test func invalidCeiling_failsClosedAtLoad() throws {
        try withPolicyDirs { workspace in
            try writeCeiling("schema_version = 1\nverdict = allow\n", workspace)
            #expect(throws: PolicyCeilingError.invalidFile) { try workspace.loadEffectiveRules() }
        }
    }

    /// A cloned repo can ship a large `.rv/policy.toml`. Setting a ceiling
    /// adds no containment enumeration per command: loading and evaluating
    /// costs about what it costs without one. (Containment of 1024
    /// distinct-branch push rules took ~7.9 s, the whole hook budget.)
    @Test func largeRepoLayerUnderCeiling_costsAboutTheSameAsWithout() throws {
        try withPolicyDirs { workspace in
            let rules = (0..<1024).map { index in
                """
                [[rule]]
                id = "typed.git:b\(index)"
                verdict = "\(index.isMultiple(of: 2) ? "allow" : "ask")"
                predicate = "gitPush"
                branch = "branch-\(index)"
                """
            }
            try writeRepo("schema_version = 1\n\n" + rules.joined(separator: "\n\n") + "\n", workspace)
            let action = SemanticAction.git(.push(remote: "origin", refspec: "branch-1", force: .force))
            let clock = ContinuousClock()
            let without = try clock.measure {
                let effective = try workspace.loadEffectiveRules()
                #expect(effective.count == 1024)
                #expect(ActionPolicyEngine.typedRestriction(action, rules: effective) != nil)
            }
            // The layer is contained in this ceiling, so a containment check
            // would have to enumerate every branch class before saying so.
            try writeCeiling(
                "schema_version = 1\n[[rule]]\nid = \"typed.git:no-release\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nbranch = \"release\"\n",
                workspace)
            let release = SemanticAction.git(.push(remote: "origin", refspec: "release", force: .none))
            let with = try clock.measure {
                let effective = try workspace.loadEffectiveRules()
                #expect(effective.count == 1025)
                #expect(ActionPolicyEngine.typedRestriction(action, rules: effective) != nil)
                guard case .hardDeny? = ActionPolicyEngine.typedRestriction(release, rules: effective)?.decision else {
                    Issue.record("the ceiling must deny a push to release")
                    return
                }
            }
            #expect(with < without * 2 + .seconds(1), "with a ceiling \(with), without \(without)")
        }
    }

    // MARK: Saves

    @Test func saveAskUnderCeilingDeny_isRefusedAndWritesNothing() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            let incoming = try PolicyDocumentTOML.parse(askForcePushLayer)
            do {
                _ = try workspace.mergeIncoming(incoming, layer: .machine, save: true)
                Issue.record("expected a ceiling refusal")
            } catch let error as PolicyCeilingError {
                #expect(error.refusal.hasPrefix("git push --force exceeds the policy ceiling"), "\(error.refusal)")
                #expect(error.refusal.hasSuffix("(check: rv why 'git push --force')"), "\(error.refusal)")
            }
            #expect(FileManager.default.fileExists(atPath: workspace.machineStore.machineFileURL.path) == false)
            // A preview is never refused: it writes nothing.
            _ = try workspace.mergeIncoming(incoming, layer: .machine, save: false)
        }
    }

    @Test func saveAllowUnderCeiling_isAdvisoryAndSaves() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            let incoming = try PolicyDocumentTOML.parse(allowMainLayer)
            _ = try workspace.mergeIncoming(incoming, layer: .repo, save: true)
            #expect(try workspace.session.loadRepoDocument().rules.count == 1)
            let ceiling = try #require(try workspace.session.loadCeiling())
            #expect(ceiling.check(incoming) == .contained)
            guard case .exceeds(let note) = ceiling.advisory(incoming) else {
                Issue.record("expected an advisory witness for the allow")
                return
            }
            #expect(note.command == "git push --force origin main")
        }
    }

    @Test func tighteningSave_isAccepted() throws {
        try withPolicyDirs { workspace in
            try writeCeiling(forcePushCeiling, workspace)
            let tighten = PolicyDocument(rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "deny-main"),
                    verdict: .deny,
                    predicate: .gitPush(force: .any, branch: "main")
                ),
            ])
            _ = try workspace.mergeIncoming(tighten, layer: .machine, save: true)
            #expect(try workspace.loadMachineDocument().rules.count == 1)
        }
    }

    // MARK: Replace (owner `ceiling set`)

    @Test func replaceCeiling_refusesWhenMachineAlreadyExceeds_andWritesNothing() throws {
        try withPolicyDirs { workspace in
            try workspace.machineStore.saveMachine(try PolicyDocumentTOML.parse(askForcePushLayer))
            let ceiling = try PolicyCeilingTOML.parse(forcePushCeiling)
            #expect(throws: PolicyCeilingError.self) { try workspace.session.replaceCeiling(ceiling) }
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            #expect(try store.load() == nil)
            #expect(FileManager.default.fileExists(atPath: store.revisionsURL.path) == false)
        }
    }

    @Test func replaceCeiling_writesOwnerOnly_andAppendsARevision() throws {
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            #expect(try store.load() == nil)
            let ceiling = try PolicyCeilingTOML.parse(forcePushCeiling)
            try workspace.session.replaceCeiling(ceiling)
            try workspace.session.replaceCeiling(PolicyCeiling())
            #expect(try store.load() == PolicyCeiling())
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int)
            #expect(mode & 0o777 == 0o600)
            let lines = try String(contentsOf: store.revisionsURL, encoding: .utf8)
                .split(separator: "\n")
            #expect(lines.count == 2)
            #expect(lines[0].contains("no-force-push"))
            let logMode = try #require(
                FileManager.default.attributesOfItem(atPath: store.revisionsURL.path)[.posixPermissions] as? Int)
            #expect(logMode & 0o777 == 0o600)
        }
    }

    @Test func replaceCeiling_appendFailure_leavesCeilingUnchanged() throws {
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            let first = try PolicyCeilingTOML.parse(forcePushCeiling)
            try workspace.session.replaceCeiling(first)
            try FileManager.default.removeItem(at: store.revisionsURL)
            // A directory, then a symlink, where the revision log goes.
            try FileManager.default.createDirectory(at: store.revisionsURL, withIntermediateDirectories: false)
            try expectWriteFailed(containing: "ceiling.toml is unchanged") {
                try workspace.session.replaceCeiling(PolicyCeiling())
            }
            #expect(try store.load() == first)
            try FileManager.default.removeItem(at: store.revisionsURL)
            let elsewhere = workspace.config.appendingPathComponent("elsewhere.jsonl")
            try FileManager.default.createSymbolicLink(at: store.revisionsURL, withDestinationURL: elsewhere)
            try expectWriteFailed(containing: "ceiling.toml is unchanged") {
                try workspace.session.replaceCeiling(PolicyCeiling())
            }
            #expect(try store.load() == first)
            #expect(FileManager.default.fileExists(atPath: elsewhere.path) == false)
            #expect(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("tmp").path) == false)
        }
    }

    @Test func replaceCeiling_renameFailureAfterAppend_saysTheLogLineNeverTookEffect() throws {
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            // A non-empty directory at ceiling.toml: the rename cannot replace it.
            try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
            try "x".write(to: store.fileURL.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
            try expectWriteFailed(containing: "never took effect") {
                try workspace.session.replaceCeiling(try PolicyCeilingTOML.parse(forcePushCeiling))
            }
            let lines = try String(contentsOf: store.revisionsURL, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 1)
            #expect(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("tmp").path) == false)
        }
    }

    @Test func replaceCeiling_recordsConfigChangedWithItsDirection() throws {
        try withPolicyDirs { workspace in
            try ConfigChangeAudit.$authorization.withValue("owner (test)") {
                try workspace.session.replaceCeiling(try PolicyCeilingTOML.parse(forcePushCeiling))
            }
            try workspace.session.replaceCeiling(PolicyCeiling())
            let events = AuditLedger(configDirectory: workspace.config).events(AuditFilter(kinds: ["config"]))
            #expect(events.map(\.kind) == [.configChanged, .configChanged])
            #expect(events.map(\.subject) == ["policy.ceiling", "policy.ceiling"])
            #expect(events.map { $0.detail["direction"] ?? "" } == ["tightening", "loosening"])
            #expect(events.map { $0.detail["rule_count"] ?? "" } == ["1", "0"])
            #expect(events.first?.detail["prior"] == ConfigChangeAudit.unset)
            #expect(events.first?.detail["authorized_by"] == "owner (test)")
            #expect(events.last?.detail["prior"] == events.first?.detail["new"])
            // The event names the content hash the revision log records, never the body.
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            let log = try String(contentsOf: store.revisionsURL, encoding: .utf8)
            for event in events {
                #expect(log.contains("\"sha256\":\"\(event.detail["new"] ?? "-")\""))
                #expect(event.detail.values.contains { $0.contains("gitPush") } == false)
            }
            let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: workspace.config)).get()
            #expect(report.isIntact)
        }
    }

    @Test func replaceCeiling_unrecordable_refusesLooseningButStillTightens() throws {
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            // audit.jsonl as a directory: every append fails.
            try FileManager.default.createDirectory(
                at: AuditLog.fileURL(configDirectory: workspace.config), withIntermediateDirectories: true)
            let first = try PolicyCeilingTOML.parse(forcePushCeiling)
            try workspace.session.replaceCeiling(first)
            #expect(try store.load() == first)
            #expect(throws: ConfigChangeUnrecorded.self) {
                try workspace.session.replaceCeiling(PolicyCeiling())
            }
            #expect(try store.load() == first)
            // An unreadable current ceiling cannot be classified: loosening.
            try "not toml".write(to: store.fileURL, atomically: true, encoding: .utf8)
            #expect(throws: ConfigChangeUnrecorded.self) {
                try workspace.session.replaceCeiling(first)
            }
            let lines = try String(contentsOf: store.revisionsURL, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 1)
        }
    }

    @Test func ceilingDirection_tightensOnlyWhenNothingLoosens() throws {
        let first = try PolicyCeilingTOML.parse(forcePushCeiling)
        #expect(PolicyCeilingStore.direction(from: .missing, to: first) == .tightening)
        #expect(PolicyCeilingStore.direction(from: .missing, to: PolicyCeiling()) == .tightening)
        #expect(PolicyCeilingStore.direction(from: .ceiling(first), to: first) == .tightening)
        #expect(PolicyCeilingStore.direction(from: .ceiling(first), to: PolicyCeiling()) == .loosening)
        #expect(PolicyCeilingStore.direction(from: .invalid, to: first) == .loosening)
        let bounded = PolicyCeiling(egressHosts: ["github.com"])
        #expect(PolicyCeilingStore.direction(from: .ceiling(PolicyCeiling()), to: bounded) == .tightening)
        #expect(PolicyCeilingStore.direction(from: .ceiling(bounded), to: PolicyCeiling()) == .loosening)
    }

    @Test func replaceCeiling_refusesAboveTheReadCap() throws {
        try withPolicyDirs { workspace in
            let huge = PolicyCeiling(rules: (0..<4000).map { index in
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "no-push-\(index)"),
                    verdict: .deny,
                    predicate: .gitPush(force: .any, branch: "branch-number-\(index)")
                )
            })
            #expect(PolicyCeilingTOML.render(huge).utf8.count > PolicyCeiling.maximumBytes)
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            // replaceCeiling would stop earlier (containment is indeterminate
            // above 1024 rules); the size cap is the writer's own guard.
            try expectWriteFailed(containing: "larger than 256 KiB") {
                try store.commitLocked(huge, recordedAt: Date())
            }
            #expect(try store.load() == nil)
            #expect(FileManager.default.fileExists(atPath: store.revisionsURL.path) == false)
        }
    }

    // MARK: Loosening diff

    @Test func diff_namesDroppedAndDowngradedRulesAndWidenedEgress() throws {
        let old = try PolicyCeilingTOML.parse("""
            schema_version = 1
            egress.hosts = ["github.com"]

            [[rule]]
            id = "typed.git:no-force-push"
            verdict = "deny"
            predicate = "gitPush"
            force = "force"

            [[rule]]
            id = "typed.git:no-hard-reset"
            verdict = "deny"
            predicate = "gitReset"
            mode = "hard"
            """)
        let new = try PolicyCeilingTOML.parse("""
            schema_version = 1
            egress.hosts = ["github.com", "*.example.com"]

            [[rule]]
            id = "typed.git:ask-hard-reset"
            verdict = "ask"
            predicate = "gitReset"
            mode = "hard"
            """)
        #expect(PolicyCeilingDiff.loosenings(from: old, to: new) == [
            "drops deny rule typed.git:no-force-push (gitPush:force:-)",
            "downgrades rule typed.git:no-hard-reset (gitReset:hard) from deny to ask",
            "adds egress host *.example.com",
        ])
        #expect(PolicyCeilingDiff.loosenings(from: new, to: old) == [])
        #expect(PolicyCeilingDiff.loosenings(from: old, to: PolicyCeiling(rules: old.rules)) == [
            "removes egress.hosts: egress approvals become unbounded",
        ])
    }

    // MARK: Store load

    @Test func load_symlinkDirectoryFIFOAndOversize_areInvalid() throws {
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            let target = workspace.config.appendingPathComponent("elsewhere.toml")
            try forcePushCeiling.write(to: target, atomically: true, encoding: .utf8)

            try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
            #expect(throws: PolicyCeilingError.invalidFile) { try store.load() }
            try FileManager.default.removeItem(at: store.fileURL)

            // A dangling link is not "no ceiling".
            try FileManager.default.createSymbolicLink(
                at: store.fileURL, withDestinationURL: workspace.config.appendingPathComponent("missing"))
            #expect(throws: PolicyCeilingError.invalidFile) { try store.load() }
            try FileManager.default.removeItem(at: store.fileURL)

            try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
            #expect(throws: PolicyCeilingError.invalidFile) { try store.load() }
            try FileManager.default.removeItem(at: store.fileURL)

            #expect(mkfifo(store.fileURL.path, 0o600) == 0)
            #expect(throws: PolicyCeilingError.invalidFile) { try store.load() }
            try FileManager.default.removeItem(at: store.fileURL)

            let huge = "schema_version = 1\n" + String(repeating: "#", count: PolicyCeiling.maximumBytes)
            try huge.write(to: store.fileURL, atomically: true, encoding: .utf8)
            #expect(throws: PolicyCeilingError.invalidFile) { try store.load() }
            try FileManager.default.removeItem(at: store.fileURL)

            #expect(try store.load() == nil)
        }
    }

    @Test func load_unreadableFile_isInvalidNotAbsent() throws {
        guard getuid() != 0 else { return }
        try withPolicyDirs { workspace in
            let store = PolicyCeilingStore(configDirectory: workspace.config)
            try forcePushCeiling.write(to: store.fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path) }
            #expect(throws: PolicyCeilingError.invalidFile) { try store.load() }
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

    private func expectWriteFailed(containing text: String, _ body: () throws -> Void) throws {
        do {
            try body()
            Issue.record("expected writeFailed")
        } catch PolicyCeilingError.writeFailed(let reason) {
            #expect(reason.contains(text), "\(reason)")
        }
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
