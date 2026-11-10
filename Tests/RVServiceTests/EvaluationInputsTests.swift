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
    @Test("RV_GUARD_MODE=enforce beats config; env never loosens; default enforce")
    func precedence() throws {
        let observeHome = try guardHome(mode: "observe")
        let enforceHome = try guardHome(mode: "enforce")
        let bare = try guardHome(mode: nil)
        defer { [observeHome, enforceHome, bare].forEach(remove) }
        func mode(_ env: [String: String], _ home: HomeDirectory) -> GuardMode {
            EvaluationInputs.gather(home: home, cwd: nil, environment: env).guardMode
        }
        #expect(mode(["RV_GUARD_MODE": "observe"], enforceHome) == .enforce)
        #expect(mode(["RV_GUARD_MODE": "observe"], bare) == .enforce)
        #expect(mode(["RV_GUARD_MODE": "ENFORCE"], observeHome) == .enforce)
        #expect(mode(["RV_GUARD_MODE": "bogus"], observeHome) == .observe)
        #expect(mode(["RV_GUARD_MODE": "bogus"], bare) == .enforce)
        #expect(mode([:], observeHome) == .observe)
        #expect(mode([:], bare) == .enforce)
    }

    /// AC-007: the explicit environment drives the door, whatever the
    /// process env says. The environment can only tighten: an explicit
    /// `enforce` pins an observe-config home to enforce, and an explicit
    /// `observe` never loosens an enforce-config home.
    @Test("explicit environment, not process env, drives the door; env never loosens")
    func explicitEnvironmentDrivesDoor() async throws {
        let observeHome = try guardHome(mode: "observe")
        let enforceHome = try guardHome(mode: nil)
        defer { [observeHome, enforceHome].forEach(remove) }
        for (home, env) in [(observeHome, "enforce"), (enforceHome, "observe")] {
            let gathered = EvaluationInputs.gather(
                home: home, cwd: nil, environment: ["RV_GUARD_MODE": env]
            )
            #expect(gathered.guardMode == .enforce)
            let result = await GatedEvaluate().gated(
                .apply, request(packDeny), cwd: nil, home: home,
                grants: EphemeralAllowOnceTable(), now: now,
                allowlist: { AllowlistSnapshot(entries: []) },
                host: .tty, tool: .bash, inputs: gathered
            )
            guard case .deny = result.decision else {
                Issue.record("env \(env) must enforce, got \(result.decision)")
                continue
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

    @Test("injected allow-paths drive SecretPathDecider, not the on-disk store")
    func injectedAllowPathsDriveSecretPaths() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let base = inputs(.enforce, home: home)
        func decide(allow: [String]) -> EvaluationResult {
            let injected = EvaluationInputs(
                guardMode: .enforce, judge: base.judge,
                store: PolicyStoreInputs(
                    allowPaths: SecretAllowPaths.EffectiveAllowPaths(
                        effective: SecretAllowPathSet(literals: allow), droppedRepoLiterals: []
                    ),
                    policy: base.store.policy, safety: .normal
                )
            )
            return GatedEvaluate().evaluateAgent(
                request(ShellCommand(rawValue: "cat ~/.env")), cwd: nil, home: home, now: now,
                inputs: injected
            )
        }
        // Disk has no exemptions in either case; only the injected value differs.
        #expect(decide(allow: ["~/.env"]).decision == .allow)
        guard case .deny = decide(allow: []).decision else {
            Issue.record("without the injected exemption the secret path must deny")
            return
        }
    }

    @Test("injected safety drives SecretPathDecider, not the on-disk store")
    func injectedSafetyDrivesSecretPaths() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let base = inputs(.enforce, home: home)
        func decide(disk: SafetyLevel, injected: SafetyLevel) throws -> EvaluationResult {
            try SafetyStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
                .saveMachine(disk)
            let gathered = EvaluationInputs(
                guardMode: .enforce, judge: base.judge,
                store: PolicyStoreInputs(
                    allowPaths: base.store.allowPaths, policy: base.store.policy, safety: injected
                )
            )
            return GatedEvaluate().evaluateAgent(
                request(ShellCommand(rawValue: "ls ~/.ssh/id_rsa")), cwd: nil, home: home,
                now: now, inputs: gathered
            )
        }
        // Metadata reads of secret paths are only guarded under strict.
        guard case .deny = try decide(disk: .normal, injected: .strict).decision else {
            Issue.record("injected strict must guard metadata despite normal on disk")
            return
        }
        #expect(try decide(disk: .strict, injected: .normal).decision == .allow)
    }

    @Test("injected safety drives the Policy gate, not the on-disk store")
    func injectedSafetyDrivesPolicyGate() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-gate-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("node_modules"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", repo.path]
        try git.run()
        git.waitUntilExit()
        let cwd = WorkingDirectory(rawValue: repo.path)
        let base = inputs(.enforce, home: home)
        func decide(disk: SafetyLevel, injected: SafetyLevel) async throws -> EvaluationResult {
            try SafetyStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
                .saveMachine(disk)
            let gathered = EvaluationInputs(
                guardMode: .enforce, judge: base.judge,
                store: PolicyStoreInputs(
                    allowPaths: base.store.allowPaths, policy: base.store.policy, safety: injected
                )
            )
            return await GatedEvaluate().gated(
                .apply, request(ShellCommand(rawValue: "rm -rf node_modules")),
                cwd: cwd, home: home, grants: EphemeralAllowOnceTable(), now: now,
                allowlist: { AllowlistSnapshot(entries: []) },
                host: .tty, tool: .bash, inputs: gathered
            )
        }
        // Balanced (normal) lets contained generated-output deletes through.
        #expect(try await decide(disk: .strict, injected: .normal).decision == .allow)
        guard case .deny = try await decide(disk: .normal, injected: .strict).decision else {
            Issue.record("injected strict must keep the deny despite normal on disk")
            return
        }
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

    @Test("a warming judge fails closed to review on apply and observe, never packs-only")
    func warmingFailsClosedOnBothPostures() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let door = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .warming))
        let enforced = await door.gated(
            .apply, request(judged), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: inputs(.enforce, home: home)
        )
        guard case .deny(let deny) = enforced.decision else {
            Issue.record("warming judge must fail closed on apply, got \(enforced.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        let applyRow = try #require(try judgeLog(home).last)
        #expect(applyRow["live"] as? String == "deny")
        #expect(applyRow["note"] as? String == "judge-warming; context: partial")

        let observed = await door.gated(
            .apply, request(judged), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: inputs(.observe, home: home)
        )
        #expect(observed.outcome == .plain)
        let observeRow = try #require(try judgeLog(home).last)
        #expect(observeRow["guard"] as? String == "observe")
        #expect(observeRow["wouldBe"] as? String == "deny")
        #expect(observeRow["wouldBeRule"] as? String == RuleID(pack: .coreJudge, pattern: "laya-review").rawValue)
        #expect(observeRow["note"] as? String == "judge-warming; context: partial")
    }

    @Test("a busy judge fails closed to review at once, never packs-only")
    func busyFailsClosedToReview() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let door = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .busy))
        let enforced = await door.gated(
            .apply, request(judged), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) },
            host: .tty, tool: .bash, inputs: inputs(.enforce, home: home)
        )
        guard case .deny(let deny) = enforced.decision else {
            Issue.record("busy judge must fail closed on apply, got \(enforced.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        let row = try #require(try judgeLog(home).last)
        #expect(row["live"] as? String == "deny")
        #expect(row["note"] as? String == "judge-busy; context: partial")
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
        #expect(ledgerRows(home).map(\.observed) == [true])
        #expect(ledgerRows(home).first?.ruleID == RuleID(pack: .coreJudge, pattern: "laya-block"))
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

@Suite("Judge port: packs-only floor through the gated door")
struct JudgePortPacksOnlyFloorTests {
    /// Allowed at the door (the unwrap peel finds no spawn or write in it) but
    /// carrying a filesystem-delete identifier, so
    /// `InlineProgramGuard.requiresJudge` flags it.
    static let inline = ShellCommand(rawValue: #"python3 -c 'print(shred)'"#)

    @Test("enforce: unscored inline program is indeterminate; the log keeps the pack allow")
    func enforceFloorsUnscoredInlineProgram() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let unavailable = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .unavailable("x")))
            .evaluateAgent(request(Self.inline), cwd: nil, home: home, now: now, inputs: inputs(.enforce, home: home))
        #expect(unavailable.decision == .indeterminate(.inlineProgramNeedsJudge))
        let unavailableRow = try #require(try judgeLog(home).last)
        #expect(unavailableRow["live"] as? String == "allow")
        #expect(unavailableRow["note"] as? String == "judge-unavailable: x; context: partial")

        let missing = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .failed)).evaluateAgent(
            request(Self.inline), cwd: nil, home: home, now: now,
            inputs: inputs(.enforce, home: home, judge: JudgeSelection(engine: .ft, bundle: nil))
        )
        #expect(missing.decision == .indeterminate(.inlineProgramNeedsJudge))
        let missingRow = try #require(try judgeLog(home).last)
        #expect(missingRow["live"] as? String == "allow")
        #expect(missingRow["note"] as? String == "engine-missing; context: partial")
    }

    @Test("observe: unscored inline program is not floored; would-be stays the pack allow")
    func observeDoesNotFloor() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let observed = GatedEvaluate(EvaluateSession(), judge: FixedJudge(run: .unavailable("x")))
            .evaluateAgent(request(Self.inline), cwd: nil, home: home, now: now, inputs: inputs(.observe, home: home))
        #expect(observed.decision == .allow)
        let row = try #require(try judgeLog(home).last)
        #expect(row["guard"] as? String == "observe")
        #expect(row["wouldBe"] as? String == "allow")
        #expect(row["note"] as? String == "judge-unavailable: x; context: partial")
    }
}
