import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

struct GatedEvaluateExemptionAuditTests {
    @Test func runFile_deniesUnblessedAndAuditsDrop() throws {
        let home = try auditTempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try auditRepoWorkspace(home: home, allowPaths: [".env"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = GatedEvaluate().runFile(
            FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: home.rawValue + "/.env")
            ),
            home: home,
            cwd: WorkingDirectory(validating: workspace.path),
            host: .tty,
            now: now
        )
        guard case .deny = result.decision else {
            Issue.record("expected file deny for unblessed repo literal")
            return
        }
        let rows = try auditRows(home: home)
        #expect(rows.count == 1)
        #expect(rows[0].dropped == [".env"])
        #expect(rows[0].workspace == workspace.path)
    }

    @Test func runFile_blessedAllowsAndWritesNoAudit() throws {
        let home = try auditTempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try auditRepoWorkspace(home: home, allowPaths: [".env"])
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SecretAllowPaths.saveBlessPaths(
            [".env"],
            to: configDir.appendingPathComponent("config.json")
        )
        let result = GatedEvaluate().runFile(
            FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: home.rawValue + "/.env")
            ),
            home: home,
            cwd: WorkingDirectory(validating: workspace.path)
        )
        #expect(result.decision == .allow)
        #expect(
            FileManager.default.fileExists(
                atPath: GatedEvaluate.exemptionDropsFileURL(home: home).path
            ) == false
        )
    }

    @Test func runFile_noRepoPolicy_writesNoAuditFile() throws {
        let home = try auditTempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let result = GatedEvaluate().runFile(
            FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: "/tmp/rv-oracle/src/main.swift")
            ),
            home: home,
            cwd: WorkingDirectory(validating: home.rawValue)
        )
        #expect(result.decision == .allow)
        #expect(
            FileManager.default.fileExists(
                atPath: GatedEvaluate.exemptionDropsFileURL(home: home).path
            ) == false
        )
    }

    @Test func commandDoor_auditsDroppedRepoLiterals() async throws {
        let home = try auditTempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try auditRepoWorkspace(home: home, allowPaths: ["dropped.env"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await GatedEvaluate().peek(
            command: ShellCommand(rawValue: "echo hi"),
            cwd: WorkingDirectory(validating: workspace.path),
            home: home,
            grants: EphemeralAllowOnceTable(),
            now: now,
            allowlist: { .empty },
            host: .tty
        )
        let rows = try auditRows(home: home)
        #expect(rows.count == 1)
        #expect(rows[0].dropped == ["dropped.env"])
    }

    @Test func audit_prunesToCap() throws {
        let home = try auditTempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(RVHistory.maxRows + 5) {
            GatedEvaluate.auditDroppedRepoLiterals(
                ["drop-\(index).env"],
                home: home,
                workspace: nil,
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let rows = try auditRows(home: home)
        #expect(rows.count == RVHistory.maxRows)
        #expect(rows.last?.dropped == ["drop-\(RVHistory.maxRows + 4).env"])
    }

    @Test func audit_nilHome_writesNothing() throws {
        GatedEvaluate.auditDroppedRepoLiterals(
            [".env"],
            home: nil,
            workspace: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

private func auditTempHome() throws -> HomeDirectory {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-audit-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: root.path))
}

private func auditRepoWorkspace(home: HomeDirectory, allowPaths: [String]) throws -> URL {
    let workspace = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        .appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: workspace.appendingPathComponent(".rv", isDirectory: true),
        withIntermediateDirectories: true
    )
    let toml = "schema_version = 1\nsecret.allow_paths = ["
        + allowPaths.map { "\"\($0)\"" }.joined(separator: ", ")
        + "]\n"
    try Data(toml.utf8).write(to: workspace.appendingPathComponent(".rv/policy.toml"))
    return workspace
}

private func auditRows(home: HomeDirectory) throws -> [GatedEvaluate.ExemptionDropRecord] {
    let url = GatedEvaluate.exemptionDropsFileURL(home: home)
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map {
        try JSONDecoder().decode(
            GatedEvaluate.ExemptionDropRecord.self,
            from: Data($0.utf8)
        )
    }
}
