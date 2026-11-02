import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// Fixed judge reading: drives thresholds and observe/enforce without
/// CoreML or a bundle on disk.
private struct FixedJudge: JudgePort {
    let run: JudgeRuntime.JudgeRun
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun { run }
}

/// Builds a judge verdict through its public Codable surface; the type is
/// inferred from the `.verdict` payload, so this target never names it.
private func verdict<T: Decodable>(
    choice: String, risk: Double, truncated: Bool = false
) throws -> T {
    let json = """
    {"choice":"\(choice)","probabilities":{},"riskScore":\(risk),"malicious":0,
     "risk":\(risk),"checkpoint":"fake","latencyMilliseconds":1,"truncated":\(truncated)}
    """
    return try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let fakeBundle = JudgeSelection(
    engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true)
)
private let packDeny = ShellCommand(rawValue: "rm -rf ~")
/// Pack-allowed and outside the safe lane, so it reaches the judge.
private let judged = ShellCommand(rawValue: "python3 deploy.py --prod")

private func inputs(
    _ mode: GuardMode, home: HomeDirectory?, judge: JudgeSelection = fakeBundle
) -> EvaluationInputs {
    EvaluationInputs(guardMode: mode, judge: judge, store: .gather(home: home, cwd: nil))
}

private func request(
    _ command: ShellCommand, provenance: ActionProvenance = .unknown
) -> EvaluationRequest {
    EvaluationRequest(command: command, enabledPacks: dayOnePackIDs, provenance: provenance)
}

@Suite("Evaluation inputs: guard mode")
struct EvaluationInputsGuardModeTests {
    @Test("RV_GUARD_MODE beats config; unknown values fall through; default enforce")
    func precedence() throws {
        let observeHome = try guardHome(mode: "observe")
        let enforceHome = try guardHome(mode: "enforce")
        let bare = try guardHome(mode: nil)
        defer { [observeHome, enforceHome, bare].forEach(remove) }
        func mode(_ env: [String: String], _ home: HomeDirectory) -> GuardMode {
            EvaluationInputs.gather(home: home, cwd: nil, environment: env).guardMode
        }
        #expect(mode(["RV_GUARD_MODE": "observe"], enforceHome) == .observe)
        #expect(mode(["RV_GUARD_MODE": "ENFORCE"], observeHome) == .enforce)
        #expect(mode(["RV_GUARD_MODE": "bogus"], observeHome) == .observe)
        #expect(mode(["RV_GUARD_MODE": "bogus"], bare) == .enforce)
        #expect(mode([:], observeHome) == .observe)
        #expect(mode([:], bare) == .enforce)
    }

    /// AC-007: the explicit environment drives the door, whatever the
    /// process env says. The mode passed is the opposite of the one the
    /// process env (plus an empty home) would produce.
    @Test("explicit environment, not process env, drives observe vs enforce")
    func explicitEnvironmentDrivesDoor() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let processMode = JudgeRuntime.guardMode(
            environment: ProcessInfo.processInfo.environment, config: nil
        )
        let explicit: GuardMode = processMode == .observe ? .enforce : .observe
        let gathered = EvaluationInputs.gather(
            home: home, cwd: nil, environment: ["RV_GUARD_MODE": explicit.rawValue]
        )
        #expect(gathered.guardMode == explicit)
        let result = await GatedEvaluate().gated(
            .apply, request(packDeny), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: gathered
        )
        switch explicit {
        case .observe:
            #expect(result.decision == .allow)
            #expect(ledgerRows(home).isEmpty)
        case .enforce:
            guard case .deny = result.decision else {
                Issue.record("explicit enforce must deny, got \(result.decision)")
                return
            }
            #expect(ledgerRows(home).count == 1)
        }
    }
}

/// Structural proof that config and stores are read once, at gather: the
/// door honours the gathered values even when disk says otherwise, so
/// nothing downstream re-reads them.
@Suite("Evaluation inputs: read once")
struct EvaluationInputsReadOnceTests {
    @Test("gathered observe wins over config enforce, including the judge-log guard field")
    func gatheredObserveOverridesConfig() async throws {
        let home = try guardHome(mode: "enforce")
        defer { remove(home) }
        let result = await GatedEvaluate().gated(
            .peek, request(packDeny), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: inputs(.observe, home: home)
        )
        #expect(result.outcome == .plain)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["guard"] as? String == "observe")
        #expect(rows.first?["wouldBe"] as? String == "deny")
    }

    @Test("gathered enforce wins over config observe on every door")
    func gatheredEnforceOverridesConfig() throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let agent = GatedEvaluate().evaluateAgent(
            request(packDeny), cwd: nil, home: home, now: now,
            inputs: inputs(.enforce, home: home)
        )
        guard case .deny = agent.decision else {
            Issue.record("agent door must enforce, got \(agent.decision)")
            return
        }
        let file = GatedEvaluate().runFile(
            FileToolAction(kind: .read, path: FileToolPath(rawValue: home.rawValue + "/.env")),
            home: home, cwd: nil, host: .tty, now: now, guardMode: .enforce
        )
        guard case .deny = file.decision else {
            Issue.record("file door must enforce, got \(file.decision)")
            return
        }
        #expect(ledgerRows(home).count == 1)
        let safe = GatedEvaluate().evaluateAgent(
            request(ShellCommand(rawValue: "ls -la")), cwd: nil, home: home, now: now,
            inputs: inputs(.enforce, home: home)
        )
        #expect(safe.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.last?["guard"] as? String == "enforce")
        #expect(rows.last?["live"] as? String == "allow")
    }

    @Test("gathered typed-rule failure fails closed without re-reading the store")
    func gatheredStoreIsUsed() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let gathered = inputs(.enforce, home: home)
        let broken = EvaluationInputs(
            guardMode: .enforce,
            judge: gathered.judge,
            store: PolicyStoreInputs(
                allowPaths: gathered.store.allowPaths, policy: nil, safety: gathered.store.safety
            )
        )
        let result = GatedEvaluate().evaluateAgent(
            request(ShellCommand(rawValue: "ls -la")), cwd: nil, home: home, now: now, inputs: broken
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("missing typed rules must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.pattern == "typed-rules-invalid")
    }

    /// A script body runs in its package directory, which here is the
    /// parent of cwd: the body reads that directory's store (broken repo
    /// typed rules), not the gathered cwd store. Holds before and after T6.
    @Test("script body in another package directory reads that directory's store")
    func scriptBodyInParentPackageGathersItsOwnStore() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let pkg = try packageDir(script: "echo hi")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let sub = pkg.appendingPathComponent("sub", isDirectory: true)
        let repoRules = pkg.appendingPathComponent(".rv", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoRules, withIntermediateDirectories: true)
        try "[[[ not toml".write(
            to: repoRules.appendingPathComponent("policy.toml"), atomically: true, encoding: .utf8
        )
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "npm test"),
            cwd: WorkingDirectory(rawValue: sub.path), home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("body under broken package rules must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.pattern == "typed-rules-invalid")
    }
}

@Suite("Evaluation inputs: judge selection")
struct EvaluationInputsJudgeSelectionTests {
    @Test("explicit engine wins even without its bundle; RV_FT_BUNDLE selects FT")
    func selection() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let ftDir = URL(fileURLWithPath: home.rawValue).appendingPathComponent("ft", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ftDir.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true
        )
        try Data().write(to: ftDir.appendingPathComponent("tokenizer.json"))
        func pick(_ env: [String: String]) -> JudgeSelection {
            EvaluationInputs.gather(home: home, cwd: nil, environment: env).judge
        }
        #expect(pick([:]) == JudgeSelection(engine: .laya, bundle: nil))
        #expect(pick(["RV_FT_BUNDLE": ftDir.path]).engine == .ft)
        #expect(pick(["RV_FT_BUNDLE": ftDir.path]).bundle?.path == ftDir.path)
        #expect(
            pick(["RV_FT_BUNDLE": ftDir.path, "RV_JUDGE_ENGINE": "laya"])
                == JudgeSelection(engine: .laya, bundle: nil)
        )
    }
}

@Suite("Judge port thresholds")
struct JudgePortThresholdTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let risk: Double
        let choice: String
        let truncated: Bool
        let provenance: ActionProvenance
        /// Nil: allow. Else the judge rule pattern.
        let pattern: String?
        let pinned: Bool
        var testDescription: String { "risk \(risk) \(choice) \(provenance) truncated=\(truncated)" }
    }

    static let cases: [Case] = [
        Case(risk: 0.10, choice: "allow", truncated: false, provenance: .unknown, pattern: nil, pinned: false),
        Case(risk: 0.35, choice: "allow", truncated: false, provenance: .unknown, pattern: nil, pinned: false),
        Case(risk: 0.35, choice: "allow", truncated: false, provenance: .web, pattern: "laya-review", pinned: false),
        Case(risk: 0.50, choice: "allow", truncated: false, provenance: .unknown, pattern: "laya-review", pinned: false),
        Case(risk: 0.65, choice: "allow", truncated: false, provenance: .unknown, pattern: "laya-review", pinned: false),
        Case(risk: 0.65, choice: "allow", truncated: false, provenance: .toolOutput, pattern: "laya-block", pinned: true),
        Case(risk: 0.85, choice: "allow", truncated: false, provenance: .unknown, pattern: "laya-block", pinned: true),
        Case(risk: 0.10, choice: "review", truncated: false, provenance: .unknown, pattern: "laya-review", pinned: false),
        Case(risk: 0.10, choice: "allow", truncated: true, provenance: .unknown, pattern: "laya-review", pinned: false),
    ]

    @Test("verdict -> provenance thresholds -> raise", arguments: cases)
    func thresholds(_ c: Case) throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let door = GatedEvaluate(
            EvaluateSession(),
            judge: FixedJudge(run: .verdict(try verdict(choice: c.choice, risk: c.risk, truncated: c.truncated)))
        )
        let result = door.evaluateAgent(
            request(judged, provenance: c.provenance), cwd: nil, home: home, now: now,
            inputs: inputs(.enforce, home: home)
        )
        guard let pattern = c.pattern else {
            #expect(result.decision == .allow)
            return
        }
        guard case .deny(let deny) = result.decision else {
            Issue.record("expected \(pattern), got \(result.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: pattern))
        #expect(HookAuthorization.isPinned(result) == c.pinned)
        let row = try #require(try judgeLog(home).last)
        #expect(row["action"] as? String == (c.pinned ? "block" : "review"))
        #expect(row["live"] as? String == "deny")
    }

    @Test("prediction failure fails closed to review; unavailable stays packs-only")
    func failureModes() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let failed = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .failed)).evaluateAgent(
            request(judged), cwd: nil, home: home, now: now, inputs: inputs(.enforce, home: home)
        )
        guard case .deny(let deny) = failed.decision else {
            Issue.record("failed judge must fail closed, got \(failed.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        #expect(try judgeLog(home).last?["note"] as? String == "prediction-failed; context: partial")
        let unavailable = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .unavailable("x")))
            .evaluateAgent(request(judged), cwd: nil, home: home, now: now, inputs: inputs(.enforce, home: home))
        #expect(unavailable.decision == .allow)
        #expect(try judgeLog(home).last?["note"] as? String == "judge-unavailable: x; context: partial")
    }

    @Test("safe lane and missing bundle never consult the judge")
    func judgeSkipped() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let door = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .failed))
        let safe = door.evaluateAgent(
            request(ShellCommand(rawValue: "ls -la")), cwd: nil, home: home, now: now,
            inputs: inputs(.enforce, home: home)
        )
        #expect(safe.decision == .allow)
        let missing = door.evaluateAgent(
            request(judged), cwd: nil, home: home, now: now,
            inputs: inputs(.enforce, home: home, judge: JudgeSelection(engine: .ft, bundle: nil))
        )
        #expect(missing.decision == .allow)
        let notes = try judgeLog(home).compactMap { $0["note"] as? String }
        #expect(notes == ["safe-lane; context: partial", "engine-missing; context: partial"])
    }

    @Test("observe logs the judge's would-be block and allows")
    func observeLogsWouldBeBlock() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let door = GatedEvaluate(
            EvaluateSession(), judge: FixedJudge(run: .verdict(try verdict(choice: "block", risk: 0.95)))
        )
        let result = await door.gated(
            .apply, request(judged), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: inputs(.observe, home: home)
        )
        #expect(result.outcome == .plain)
        #expect(ledgerRows(home).isEmpty)
        let row = try #require(try judgeLog(home).last)
        #expect(row["guard"] as? String == "observe")
        #expect(row["wouldBe"] as? String == "deny")
        #expect(row["wouldBeRule"] as? String == RuleID(pack: .coreJudge, pattern: "laya-block").rawValue)
        #expect(row["action"] as? String == "block")
    }

    @Test("enforce: a judge review on apply reaches the Policy gate and is recorded")
    func enforceReviewThroughGate() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let door = GatedEvaluate(
            EvaluateSession(), judge: FixedJudge(run: .verdict(try verdict(choice: "review", risk: 0.5)))
        )
        let result = await door.gated(
            .apply, request(judged), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: inputs(.enforce, home: home)
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("judge review must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        #expect(ledgerRows(home).count == 1)
    }
}
