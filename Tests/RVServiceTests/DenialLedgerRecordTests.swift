import Foundation
import Testing
import RVDomain
import RVHistory
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
            host: "claude",
            now: now
        )
        guard case .deny = result.decision else {
            Issue.record("expected file deny")
            return
        }
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].host == "claude")
        #expect(rows[0].tool == "Read")
        #expect(rows[0].ruleID == "core.secrets:env")
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
            host: "claude",
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
            host: "claude",
            now: now
        )
        #expect(
            DenialLedger(configDirectory: configDir).list(now: now).isEmpty
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
            host: "grok"
        )
        guard case .deny = result.decision else {
            Issue.record("expected shell deny")
            return
        }
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].host == "grok")
        #expect(rows[0].tool == "Bash")
        #expect(rows[0].ruleID == "core.git:reset-hard")
        #expect(rows[0].path.isEmpty)
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-svc-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
