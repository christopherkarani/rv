import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// Characterization of the observe/enforce branch on all three doors
/// (gated peek/apply, `evaluateAgent`, file door). Guard mode comes from
/// an isolated home's `config.json`, so these hold before and after the
/// branch is unified behind `EvaluationInputs`.
@Suite("Guard mode characterization")
struct GuardModeCharacterizationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let packDeny = ShellCommand(rawValue: "rm -rf ~")

    @Test("observe: apply of a pack deny allows, records an observed denial, logs would-be deny")
    func observeApplyLogsWouldBe() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(result.decision == .allow)
        #expect(result.outcome == .plain)
        #expect(ledgerRows(home).map(\.observed) == [true])
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["guard"] as? String == "observe")
        #expect(rows.first?["wouldBe"] as? String == "deny")
        #expect(rows.first?["live"] as? String == "allow")
        #expect(rows.first?["peek"] == nil)
    }

    @Test("observe: peek tags the judge-log row")
    func observePeekTagsRow() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let result = await GatedEvaluate().peek(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(result.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["peek"] as? Bool == true)
        #expect(rows.first?["wouldBe"] as? String == "deny")
    }

    @Test("observe: file door allows a secret read and records only an observed denial")
    func observeFileDoor() throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let result = GatedEvaluate().runFile(
            FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + "/.env")),
            home: home, host: .hook(.claude), now: Self.now
        )
        #expect(result.decision == .allow)
        #expect(result.outcome == .plain)
        #expect(ledgerRows(home).map(\.observed) == [true])
        #expect(try judgeLog(home).isEmpty)
    }

    @Test("enforce: file door denies and records")
    func enforceFileDoor() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = GatedEvaluate().runFile(
            FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + "/.env")),
            home: home, host: .hook(.claude), now: Self.now
        )
        guard case .deny = result.decision else {
            Issue.record("enforce file door must deny, got \(result.decision)")
            return
        }
        #expect(ledgerRows(home).count == 1)
    }

    @Test("observe: evaluateAgent allows a pack deny and logs would-be deny")
    func observeAgent() throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let result = GatedEvaluate().evaluateAgent(
            EvaluationRequest(command: Self.packDeny, enabledPacks: dayOnePackIDs),
            cwd: nil, home: home
        )
        #expect(result.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["wouldBe"] as? String == "deny")
        #expect(rows.first?["peek"] == nil)
    }

    @Test("enforce: evaluateAgent keeps a pack deny and writes no judge row")
    func enforceAgent() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = GatedEvaluate().evaluateAgent(
            EvaluationRequest(command: Self.packDeny, enabledPacks: dayOnePackIDs),
            cwd: nil, home: home
        )
        guard case .deny = result.decision else {
            Issue.record("enforce agent must deny, got \(result.decision)")
            return
        }
        #expect(try judgeLog(home).isEmpty)
        #expect(ledgerRows(home).isEmpty)
    }

    @Test("enforce: safe-lane allow logs a live safe-lane row")
    func enforceSafeLane() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "ls -la"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(result.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["guard"] as? String == "enforce")
        #expect(rows.first?["live"] as? String == "allow")
        #expect(rows.first?["note"] as? String == "safe-lane; context: partial")
        #expect(rows.first?["wouldBe"] == nil)
    }

    @Test("enforce: non-safe allow with no bundle logs engine-missing and stays allow")
    func enforceEngineMissing() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "python3 deploy.py --prod"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(result.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["note"] as? String == "engine-missing; context: partial")
        #expect(rows.first?["live"] as? String == "allow")
    }

    @Test("observe: non-safe allow with no bundle logs a would-be allow with no note")
    func observeEngineMissing() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "python3 deploy.py --prod"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(result.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["note"] as? String == "context: partial")
        #expect(rows.first?["wouldBe"] as? String == "allow")
    }

    @Test("invalid config guard mode falls through to enforce")
    func invalidConfigEnforces() async throws {
        let home = try guardHome(mode: "bogus")
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: Self.packDeny, cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        guard case .deny = result.decision else {
            Issue.record("bogus guard.mode must enforce, got \(result.decision)")
            return
        }
        #expect(ledgerRows(home).count == 1)
    }

    @Test("observe: poisoned package script is logged as would-be deny, not enforced")
    func observeScriptDeny() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let pkg = try packageDir(script: "rm -rf ~/Documents")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "npm test"),
            cwd: WorkingDirectory(rawValue: pkg.path), home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(result.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["wouldBe"] as? String == "deny")
    }

    @Test("enforce: poisoned package script denies before the judge (no judge row)")
    func enforceScriptDeny() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let pkg = try packageDir(script: "rm -rf ~/Documents")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "npm test"),
            cwd: WorkingDirectory(rawValue: pkg.path), home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        guard case .deny = result.decision else {
            Issue.record("poisoned script must deny, got \(result.decision)")
            return
        }
        #expect(try judgeLog(home).isEmpty)
    }
}

// MARK: - Helpers

func guardHome(mode: String?) throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-guard-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let home = try #require(HomeDirectory(validating: url.path))
    if let mode {
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try #"{"guard":{"mode":"\#(mode)"}}"#
            .write(to: config.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    }
    return home
}

func remove(_ home: HomeDirectory) {
    try? FileManager.default.removeItem(atPath: home.rawValue)
}

func judgeLog(_ home: HomeDirectory) throws -> [[String: Any]] {
    let file = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("judge-log.jsonl")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").map { line in
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

func ledgerRows(_ home: HomeDirectory) -> [DenialLedgerRecord] {
    DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        .records(asOf: Date(timeIntervalSince1970: 1_800_000_000))
}

func packageDir(script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-guard-pkg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"scripts":{"test":"\#(script)"}}"#
        .write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    return dir
}
