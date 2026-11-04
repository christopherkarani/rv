import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// Characterization of what each door writes to disk, per guard mode: the
/// exemption-drops audit, judge log, and denial ledger. These pin the
/// on-disk effect output so moving the writes behind effect values cannot
/// change which rows land in which file, their content, or their order.
@Suite("Gated effects characterization")
struct GatedEffectCharacterizationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    enum Door: String, Sendable, CaseIterable {
        case peek, apply, agent, file
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let door: Door
        let mode: GuardMode
        let audits: Int
        let judgeRows: Int
        let ledgerRows: Int
        var testDescription: String { "\(door.rawValue) \(mode.rawValue)" }
    }

    /// A pack deny (shell doors) or a secret read (file door), evaluated in a
    /// workspace whose repo policy drops one unblessed literal.
    static let cases: [Case] = [
        Case(door: .peek, mode: .enforce, audits: 1, judgeRows: 0, ledgerRows: 0),
        Case(door: .apply, mode: .enforce, audits: 1, judgeRows: 0, ledgerRows: 1),
        Case(door: .agent, mode: .enforce, audits: 1, judgeRows: 0, ledgerRows: 0),
        Case(door: .file, mode: .enforce, audits: 1, judgeRows: 0, ledgerRows: 1),
        Case(door: .peek, mode: .observe, audits: 1, judgeRows: 1, ledgerRows: 0),
        Case(door: .apply, mode: .observe, audits: 1, judgeRows: 1, ledgerRows: 0),
        Case(door: .agent, mode: .observe, audits: 1, judgeRows: 1, ledgerRows: 0),
        Case(door: .file, mode: .observe, audits: 1, judgeRows: 0, ledgerRows: 0),
    ]

    @Test("rows per file, per door and guard mode", arguments: cases)
    func rowsPerDoor(_ c: Case) async throws {
        let home = try guardHome(mode: c.mode.rawValue)
        defer { remove(home) }
        let repo = try effectRepo(in: home, named: "repo", dropping: ["dropped.env"])
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let packDeny = ShellCommand(rawValue: "rm -rf ~")
        switch c.door {
        case .peek:
            _ = await GatedEvaluate().peek(
                command: packDeny, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { .empty }
            )
        case .apply:
            _ = await GatedEvaluate().apply(
                command: packDeny, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { .empty }
            )
        case .agent:
            _ = GatedEvaluate().evaluateAgent(
                EvaluationRequest(command: packDeny, enabledPacks: dayOnePackIDs),
                cwd: cwd, home: home, now: Self.now
            )
        case .file:
            _ = GatedEvaluate().runFile(
                FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + "/.env")),
                home: home, cwd: cwd, host: .tty, now: Self.now
            )
        }
        let audits = try exemptionRows(home)
        #expect(audits.count == c.audits)
        #expect(audits.first?.dropped == ["dropped.env"])
        #expect(audits.first?.workspace == repo.path)
        #expect(audits.first?.recordedAt == Self.now.timeIntervalSince1970)
        let judgeRows = try judgeLog(home)
        #expect(judgeRows.count == c.judgeRows)
        #expect(judgeRows.first?["guard"] as? String == (c.judgeRows == 0 ? nil : c.mode.rawValue))
        #expect(judgeRows.first?["peek"] as? Bool == (c.door == .peek && c.judgeRows == 1 ? true : nil))
        #expect(ledgerRows(home).count == c.ledgerRows)
    }

    @Test("one apply writes all three files; judge row bytes are pinned")
    func applyWritesAllThree() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let repo = try effectRepo(in: home, named: "repo", dropping: ["dropped.env"])
        let door = GatedEvaluate(
            EvaluateSession(),
            judge: EffectFixedJudge(run: .verdict(try effectVerdict(choice: "review", risk: 0.5)))
        )
        let result = await door.gated(
            .apply,
            EvaluationRequest(command: ShellCommand(rawValue: "python3 deploy.py --prod"), enabledPacks: dayOnePackIDs),
            cwd: WorkingDirectory(validating: repo.path), home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude), tool: .bash,
            inputs: EvaluationInputs(
                guardMode: .enforce,
                judge: JudgeSelection(engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle")),
                store: .gather(home: home, cwd: WorkingDirectory(validating: repo.path))
            )
        )
        guard case .deny = result.decision else {
            Issue.record("judge review must deny, got \(result.decision)")
            return
        }
        #expect(try exemptionRows(home).map(\.dropped) == [["dropped.env"]])
        let hash = String(RVDigest.sha256Hex([UInt8](result.matchingView.rawValue.utf8)).prefix(16))
        let expected = #"{"action":"review","checkpoint":"fake","choice":"review","engine":"ft","guard":"enforce","hash":""#
            + hash
            + #"","live":"deny","malicious":0,"ms":1,"note":"context: partial","risk":0.5,"ts":"2027-01-15T08:00:00Z"}"#
            + "\n"
        #expect(try judgeLogText(home) == expected)
        let ledger = ledgerRows(home)
        #expect(ledger.count == 1)
        #expect(ledger.first?.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        #expect(ledger.first?.host == .hook(.claude))
        #expect(ledger.first?.category == .pack(.coreJudge))
        #expect(ledger.first?.timestamp == Self.now)
    }

    @Test("observe peek judge row bytes are pinned")
    func observePeekRowBytes() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let result = await GatedEvaluate().peek(
            command: ShellCommand(rawValue: "rm -rf ~"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now, allowlist: { .empty }
        )
        #expect(result.decision == .allow)
        let hash = String(RVDigest.sha256Hex([UInt8](result.matchingView.rawValue.utf8)).prefix(16))
        let rule = try #require(try judgeLog(home).first?["wouldBeRule"] as? String)
        let engine = try #require(try judgeLog(home).first?["engine"] as? String)
        let expected = #"{"engine":""# + engine + #"","guard":"observe","hash":""# + hash
            + #"","live":"allow","note":"context: partial","peek":true,"ts":"2027-01-15T08:00:00Z","wouldBe":"deny","wouldBeRule":""#
            + rule + #""}"# + "\n"
        #expect(try judgeLogText(home) == expected)
    }

    @Test("script bodies audit their own workspace, after the command, in body order")
    func scriptBodyAuditsInOrder() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let repo = try effectRepo(in: home, named: "repo", dropping: ["repo.env"])
        let pkgA = try effectRepo(in: home, named: "repo/pkgA", dropping: ["a.env"])
        let pkgB = try effectRepo(in: home, named: "repo/pkgB", dropping: ["b.env"])
        for pkg in [pkgA, pkgB] {
            try #"{"scripts":{"test":"echo hi"}}"#
                .write(to: pkg.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        }
        _ = await GatedEvaluate().peek(
            command: ShellCommand(rawValue: "cd pkgA && npm test && cd ../pkgB && npm test"),
            cwd: WorkingDirectory(validating: repo.path), home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now, allowlist: { .empty }
        )
        let rows = try exemptionRows(home)
        #expect(rows.map(\.dropped) == [["repo.env"], ["a.env"], ["b.env"]])
        #expect(rows.map { $0.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } } == ["repo", "pkgA", "pkgB"])
    }
}

// MARK: - Helpers

/// Fixed judge reading for effect characterization.
struct EffectFixedJudge: JudgePort {
    let run: JudgeRuntime.JudgeRun
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun { run }
}

/// Judge verdict through its Codable surface; this target never names the type.
func effectVerdict<T: Decodable>(choice: String, risk: Double) throws -> T {
    let json = """
    {"choice":"\(choice)","probabilities":{},"riskScore":\(risk),"malicious":0,
     "risk":\(risk),"checkpoint":"fake","latencyMilliseconds":1,"truncated":false}
    """
    return try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A workspace under `home` whose repo policy lists `dropping` as allow-paths
/// with no machine blessing, so every evaluation there drops them.
func effectRepo(in home: HomeDirectory, named name: String, dropping: [String]) throws -> URL {
    let workspace = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
        at: workspace.appendingPathComponent(".rv", isDirectory: true),
        withIntermediateDirectories: true
    )
    let toml = "schema_version = 1\nsecret.allow_paths = ["
        + dropping.map { "\"\($0)\"" }.joined(separator: ", ")
        + "]\n"
    try Data(toml.utf8).write(to: workspace.appendingPathComponent(".rv/policy.toml"))
    return workspace
}

func exemptionRows(_ home: HomeDirectory) throws -> [GatedEvaluate.ExemptionDropRecord] {
    let url = GatedEvaluate.exemptionDropsFileURL(home: home)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").map {
        try JSONDecoder().decode(GatedEvaluate.ExemptionDropRecord.self, from: Data($0.utf8))
    }
}

func judgeLogText(_ home: HomeDirectory) throws -> String {
    let file = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("judge-log.jsonl")
    return try String(contentsOf: file, encoding: .utf8)
}
