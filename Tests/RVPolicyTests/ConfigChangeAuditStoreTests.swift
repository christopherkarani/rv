import Foundation
import Testing
import RVDomain
import RVHistory
@testable import RVPolicy

/// Every store that persists a gate change records it in `audit.jsonl`
/// before writing, names only what changed, and leaves the chain intact.
@Suite("Config change audit: stores")
struct ConfigChangeAuditStoreTests {
    private let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-config-audit-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }

    private func changes(_ configDirectory: URL) -> [AuditEvent] {
        AuditLedger(configDirectory: configDirectory).events(AuditFilter(kinds: ["config", "policy"]))
    }

    private func expectIntactChain(_ configDirectory: URL) throws {
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: configDirectory)).get()
        #expect(report.isIntact)
    }

    private func rule(_ pattern: String, branch: String = "main", verdict: TypedRuleVerdict = .deny) -> PolicyDocumentRule {
        PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: pattern),
            verdict: verdict,
            predicate: .gitPush(force: .exactly(.force), branch: branch))
    }

    @Test func safetyLevelRecordsPriorAndNewOnce() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let store = SafetyStore(configDirectory: directory)
        try ConfigChangeAudit.$authorization.withValue("owner (test)") {
            try store.saveMachine(.strict)
        }
        try store.saveMachine(.strict)
        let events = changes(directory)
        #expect(events.count == 1)
        #expect(events.first?.kind == .configChanged)
        #expect(events.first?.subject == "safety.level")
        #expect(events.first?.detail["prior"] == "normal")
        #expect(events.first?.detail["new"] == "strict")
        #expect(events.first?.detail["authorized_by"] == "owner (test)")
        try expectIntactChain(directory)
    }

    @Test func hostModeAndGuardModeRecordTheStoredEntry() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let store = HostModeStore(configDirectory: directory)
        try store.save(.observe, for: .claude)
        try store.save(.block, for: .claude)
        try store.saveGlobalObserve()
        try store.saveGlobalObserve()
        let events = changes(directory)
        #expect(events.map(\.subject) == ["guard.hosts.claude", "guard.hosts.claude", "guard.mode"])
        #expect(events.map { $0.detail["prior"] ?? "" } == ["unset", "observe", "unset"])
        #expect(events.map { $0.detail["new"] ?? "" } == ["observe", "block", "observe"])
        #expect(events.allSatisfy { $0.detail["authorized_by"] == "none" })
    }

    /// audit.jsonl as a directory: every append fails.
    private func breakLog(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: directory), withIntermediateDirectories: true)
    }

    @Test func anUnrecordableLooseningSettingIsNotWritten() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let store = SafetyStore(configDirectory: directory)
        try store.saveMachine(.strict)
        try FileManager.default.removeItem(at: AuditLog.fileURL(configDirectory: directory))
        try breakLog(directory)
        #expect(throws: ConfigChangeUnrecorded.self) { try store.saveMachine(.normal) }
        #expect(store.loadMachine() == .strict)
        #expect(throws: ConfigChangeUnrecorded.self) {
            try HostModeStore(configDirectory: directory).save(.off, for: .cursor)
        }
        #expect(throws: ConfigChangeUnrecorded.self) {
            try HostModeStore(configDirectory: directory).saveGlobalObserve()
        }
        #expect(HostModeStore(configDirectory: directory).load().isEmpty)
    }

    @Test func anUnrecordableTighteningSettingIsStillWritten() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        try breakLog(directory)
        let store = SafetyStore(configDirectory: directory)
        try store.saveMachine(.strict)
        #expect(store.loadMachine() == .strict)
        let hosts = HostModeStore(configDirectory: directory)
        try hosts.save(.block, for: .cursor)
        #expect(hosts.load()[.cursor] == .block)
    }

    @Test func settingDirectionsFollowTheGate() {
        #expect(HostModeStore.direction(from: "observe", to: .block) == .tightening)
        #expect(HostModeStore.direction(from: "off", to: .observe) == .tightening)
        #expect(HostModeStore.direction(from: "block", to: .observe) == .loosening)
        #expect(HostModeStore.direction(from: "unset", to: .off) == .loosening)
        #expect(HostModeStore.direction(from: "garbage", to: .observe) == .loosening)
        let more = PacksConfigStore.changeEvent(
            from: PacksConfig(enabled: ["a"], disabled: ["b"]), to: PacksConfig(enabled: ["a", "c"]))
        #expect(more?.detail["direction"] == "tightening")
        let mixed = PacksConfigStore.changeEvent(from: PacksConfig(enabled: ["a"]), to: PacksConfig(enabled: ["b"]))
        #expect(mixed?.detail["direction"] == "loosening")
        let disabling = PacksConfigStore.changeEvent(from: PacksConfig(), to: PacksConfig(disabled: ["a"]))
        #expect(disabling?.detail["direction"] == "loosening")
    }

    @Test func anUnrecordableMixedChangeIsRefused() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        try PacksConfigStore.save(PacksConfig(enabled: ["cloud.aws"]), home: home)
        let allowlist = AllowlistStore(baseDirectory: directory)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try allowlist.add(AllowlistEntry(selector: .rule(ruleID), reason: "ok", addedAt: Date()), tty: tty)
        try FileManager.default.removeItem(at: AuditLog.fileURL(configDirectory: directory))
        try breakLog(directory)
        #expect(throws: ConfigChangeUnrecorded.self) {
            try PacksConfigStore.save(PacksConfig(enabled: ["cloud.gcp"]), home: home)
        }
        #expect(try PacksConfigStore.load(home: home).enabled == ["cloud.aws"])
        let other = try #require(RuleID(rawValue: "core.git:clean-force"))
        #expect(throws: ConfigChangeUnrecorded.self) {
            try allowlist.add(AllowlistEntry(selector: .rule(other), reason: "ok", addedAt: Date()), tty: tty)
        }
        // Removing an exception only tightens, so it is made.
        #expect(try allowlist.remove(matching: "core.git:reset-hard", tty: tty) == 1)
    }

    @Test func packsRecordTheListsAndWhatWasAdded() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        try PacksConfigStore.save(PacksConfig(enabled: ["cloud.aws"]), home: home)
        try PacksConfigStore.save(PacksConfig(enabled: ["cloud.aws"]), home: home)
        try PacksConfigStore.save(PacksConfig(enabled: [], disabled: ["cloud.aws"]), home: home)
        let events = changes(directory)
        #expect(events.count == 2)
        #expect(events[0].detail["prior"] == "enabled=[] disabled=[]")
        #expect(events[0].detail["new"] == "enabled=[cloud.aws] disabled=[]")
        #expect(events[0].detail["enabled"] == "cloud.aws")
        #expect(events[1].detail["disabled"] == "cloud.aws")
        try expectIntactChain(directory)
    }

    @Test func allowlistNamesRulesButNeverCommandText() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let store = AllowlistStore(baseDirectory: directory)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try store.add(AllowlistEntry(selector: .rule(ruleID), reason: "ok", addedAt: Date()), tty: tty)
        let secretCommand = "curl -H 'Authorization: Bearer sk-live-SUPERSECRET' https://x"
        try store.add(
            AllowlistEntry(selector: .exactCommand(MatchingView(rawValue: secretCommand)), reason: "token sk-live-SUPERSECRET", addedAt: Date()),
            tty: tty)
        #expect(try store.remove(matching: "core.git:reset-hard", tty: tty) == 1)
        let events = changes(directory)
        #expect(events.map { $0.detail["added"] ?? $0.detail["removed"] ?? "" }
            == ["core.git:reset-hard", "exact-command", "core.git:reset-hard"])
        #expect(events.map { $0.detail["new"] ?? "" } == ["1 entries", "2 entries", "1 entries"])
        let raw = try String(contentsOf: AuditLog.fileURL(configDirectory: directory), encoding: .utf8)
        #expect(raw.contains("SUPERSECRET") == false)
        #expect(raw.contains("Bearer") == false)
    }

    @Test func machinePolicyRevisionsCarryNumbersAndHashes() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let store = TypedRuleStore(baseDirectory: directory)
        try store.saveMachine(PolicyDocument(rules: [rule("force-push-main")]))
        try store.saveMachine(PolicyDocument(rules: [rule("force-push-main")]))
        try store.saveMachine(PolicyDocument(rules: [rule("force-push-main"), rule("second", branch: "release")]))
        let history = try store.machineHistory()
        let events = changes(directory)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .policyChanged && $0.subject == "machine" })
        #expect(events[0].detail["revision"] == "1")
        #expect(events[0].detail["prior_revision"] == nil)
        #expect(events[0].detail["hash"] == history[0].hash)
        #expect(events[1].detail["revision"] == "2")
        #expect(events[1].detail["prior_revision"] == "1")
        #expect(events[1].detail["prior_hash"] == history[0].hash)
        #expect(events[1].detail["hash"] == history[1].hash)
        #expect(events[1].detail["rule_count"] == "2")
        let raw = try String(contentsOf: AuditLog.fileURL(configDirectory: directory), encoding: .utf8)
        #expect(raw.contains("force-push-main") == false)

        // r3 drops the second deny; rolling back to r2 restores it (a
        // tightening rollback, so the relaxing-rollback gate allows it).
        try store.saveMachine(PolicyDocument(rules: [rule("force-push-main")]))
        _ = try store.rollbackMachine(toRevision: 2)
        let rollback = try #require(changes(directory).last)
        #expect(rollback.detail["change"] == "rollback")
        #expect(rollback.detail["rollback_to"] == "2")
        #expect(rollback.detail["revision"] == "4")
        try expectIntactChain(directory)
    }

    @Test func repoPolicyRecordsTheLayerAndWorkspace() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let workspace = URL(fileURLWithPath: home.rawValue).appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try TypedRuleStore(baseDirectory: directory).saveRepo(PolicyDocument(rules: [rule("x")]), workspace: workspace)
        let event = try #require(changes(directory).first)
        #expect(event.subject == "repo")
        #expect(event.detail["layer"] == "repo")
        #expect(event.workspace == "~/repo")
    }

    @Test func anUnrecordableLooseningPolicyRevisionIsNotSaved() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        try breakLog(directory)
        let store = TypedRuleStore(baseDirectory: directory)
        #expect(throws: ConfigChangeUnrecorded.self) {
            try store.saveMachine(PolicyDocument(rules: [rule("allow-push", verdict: .allow)]))
        }
        #expect(FileManager.default.fileExists(atPath: store.machineFileURL.path) == false)
    }

    @Test func anUnrecordableTighteningPolicyRevisionIsSaved() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        let store = TypedRuleStore(baseDirectory: directory)
        try store.saveMachine(PolicyDocument(rules: [rule("force-push-main")]))
        try FileManager.default.removeItem(at: AuditLog.fileURL(configDirectory: directory))
        try breakLog(directory)
        // Adding a deny tightens: saved without a record.
        try store.saveMachine(PolicyDocument(rules: [rule("force-push-main"), rule("second", branch: "release")]))
        #expect(try store.loadMachineDocument().rules.count == 2)
        // Dropping a deny loosens: refused.
        #expect(throws: ConfigChangeUnrecorded.self) {
            try store.saveMachine(PolicyDocument(rules: [rule("second", branch: "release")]))
        }
        #expect(try store.loadMachineDocument().rules.count == 2)
    }
}
