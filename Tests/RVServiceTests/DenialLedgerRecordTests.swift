import Foundation
import Testing
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
@testable import RVService

struct DenialLedgerRecordTests {
    @Test func fileToolDeny_appendsRedactedRow() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = GatedEvaluate().runFile(
            FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: home.rawValue + "/.env")
            ),
            home: home,
            host: .hook(.claude),
            now: now
        )
        guard case .deny = result.decision else {
            Issue.record("expected file deny")
            return
        }
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].host == .hook(.claude))
        #expect(rows[0].tool == .file(.read))
        #expect(rows[0].ruleID == RuleID(pack: .coreSecrets, pattern: "env"))
        #expect(rows[0].category == .secret(.environment))
        #expect(rows[0].path == "~/.env")
    }

    @Test func allow_doesNotWrite() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = GatedEvaluate().runFile(
            FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: "/tmp/rv-oracle/src/main.swift")
            ),
            home: home,
            host: .hook(.claude),
            now: now
        )
        #expect(result.decision == .allow)
        #expect(
            DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
                .list(now: now)
                .isEmpty
        )
    }

    @Test func blocksDisabled_writesNothing() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(#"{ "blocks": { "enabled": false } }"#.utf8)
            .write(to: configDir.appendingPathComponent("config.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = GatedEvaluate().runFile(
            FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")),
            home: home,
            host: .hook(.claude),
            now: now
        )
        #expect(
            DenialLedger(configDirectory: configDir).list(now: now).isEmpty
        )
    }

    @Test func peek_doesNotWrite() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AllowOnceStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        let result = await GatedEvaluate().run(
            .peek,
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: WorkingDirectory(validating: home.rawValue),
            home: home,
            store: store,
            now: now,
            allowlist: { .empty },
            host: .tty
        )
        guard case .deny = result.decision else {
            Issue.record("expected peek deny")
            return
        }
        #expect(
            DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
                .list(now: now)
                .isEmpty
        )
    }

    @Test func shellDeny_appends() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AllowOnceStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        let result = await GatedEvaluate().run(
            .apply,
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: WorkingDirectory(validating: home.rawValue),
            home: home,
            store: store,
            now: now,
            allowlist: { .empty },
            host: .hook(.grok)
        )
        guard case .deny = result.decision else {
            Issue.record("expected shell deny")
            return
        }
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].host == .hook(.grok))
        #expect(rows[0].tool == .bash)
        #expect(rows[0].ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
        #expect(rows[0].category == .pack(.coreGit))
        #expect(rows[0].path.isEmpty)
    }

    @Test func spendHostAsk_appends() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AllowOnceStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        let result = await GatedEvaluate().spendHostAsk(
            command: ShellCommand(rawValue: "cat .env"),
            cwd: WorkingDirectory(validating: home.rawValue),
            home: home,
            store: store,
            now: now,
            allowlist: { .empty },
            host: .hook(.claude)
        )
        guard case .deny = result.decision else {
            Issue.record("expected spend-host-ask deny")
            return
        }
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].host == .hook(.claude))
        #expect(rows[0].tool == .bash)
        #expect(rows[0].ruleID == RuleID(pack: .coreSecrets, pattern: "env"))
        #expect(rows[0].category == .secret(.environment))
    }

    @Test func hookEvaluateSpendDeny_recordsHookHost() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            clock: { now }
        )
        let stdin = """
        {"toolName":"bash","cwd":"\(home.rawValue)","input":{"command":"cat .env"},"hostAsk":"spend"}
        """
        _ = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: stdin)))
        )
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].host == .hook(.pi))
        #expect(rows[0].tool == .bash)
        #expect(rows[0].category == .secret(.environment))
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-svc-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
