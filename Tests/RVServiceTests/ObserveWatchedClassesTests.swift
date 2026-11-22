import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

/// Honest watch mode (North Star C1, Chris's Q5): under observe only
/// catastrophic commands and rv's own protection stop. An unresolved path,
/// a write outside the repository and nesting past the unwrap limit are
/// watched (logged as a would-be stop, then run); enforce stops each.
@Suite("Observe: watched classes vs stopped in every mode")
struct ObserveWatchedClassesTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: The floor's rule, one class at a time

    private static let classDenies: [Deny] = [
        ActionPolicyEngine.Builtin.unresolvedFilesystem,
        ActionPolicyEngine.Builtin.outsideRepository,
        ActionPolicyEngine.Builtin.unwrapLimited,
    ]

    @Test("the watched classes are exactly unresolved-path, out-of-repo-write, unwrap-limited")
    func watchedClassSet() {
        #expect(ObserveFloor.watchedClasses == [.unresolvedPath, .outOfRepoWrite, .unwrapLimited])
        for deny in Self.classDenies {
            #expect(ObserveFloor.isWatchedClass(deny.ruleID), "\(deny.ruleID.rawValue)")
        }
        #expect(ObserveFloor.isWatchedClass(ActionPolicyEngine.Builtin.protectedPath.ruleID) == false)
        #expect(ObserveFloor.isWatchedClass(RuleID(pack: .coreGit, pattern: "reset-hard")) == false)
    }

    /// A readable command with a watched-class deny is observed.
    @Test("floor: a watched-class deny on a readable command is observed", arguments: classDenies)
    func readableClassDenyIsObserved(deny: Deny) {
        #expect(floorRule("touch /etc/x", result: Self.denied(deny)) == .observed)
    }

    /// A command rv cannot see still stops (it could switch rv off), but
    /// as `observe.floor:unanalyzable`, never as the class's own hard deny.
    @Test("floor: a watched-class deny rv cannot see stops as unanalyzable", arguments: classDenies)
    func opaqueClassDenyStopsAsUnanalyzable(deny: Deny) {
        let ruling = floorRule(#"eval "$X"; touch /etc/x"#, result: Self.denied(deny))
        #expect(ruling == .enforce(EvaluationResult(outcome: .indeterminate(.observeUnanalyzable))))
    }

    @Test("floor: any other deny rv cannot see keeps its own rule")
    func opaquePackDenyIsKept() {
        let deny = Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
        let result = Self.denied(deny)
        #expect(floorRule(#"eval "$X"; git reset --hard"#, result: result) == .enforce(result))
    }

    @Test("floor: a watched-class deny that touches rv keeps its deny")
    func selfProtectionKeepsClassDeny() throws {
        let home = try #require(HomeDirectory(rawValue: "/Users/agent"))
        let result = Self.denied(ActionPolicyEngine.Builtin.outsideRepository)
        #expect(floorRule("touch ~/.local/bin/rvd", result: result, home: home) == .enforce(result))
    }

    // MARK: Through the gate: observe vs enforce

    @Test(
        "a watched class: observe lets it run with a would-be stop, enforce stops it",
        arguments: [
            ("touch /etc/rv-watched", BuiltinRule.outOfRepoWrite),
            ("cp notes.txt /opt/rv-watched/notes.txt", .outOfRepoWrite),
            ("rm -rf /tmp/rv-a /tmp/rv-b", .outOfRepoWrite),
            ("env env env env env env env env env env ls", .unwrapLimited),
            (#"bash -c 'bash -c "bash -c \"bash -c ls\""'"#, .unwrapLimited),
        ]
    )
    func watchedInObserveStoppedInEnforce(command: String, rule: BuiltinRule) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .allow, "\(command)")
        #expect(observed.stoppedInEveryMode == false)
        #expect(observed.wouldBe?.result.decision == .deny(Self.builtin(rule)), "\(command)")
        #expect(observed.wouldBe?.authorization == .denyPinned)
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision == .deny(Self.builtin(rule)), "\(command)")
        #expect(enforced.wouldBe == nil)
        #expect(enforced.stoppedInEveryMode == false)
    }

    /// Part of the command is a program rv cannot read: enforce stops it on
    /// the class's rule; observe stops it too, for rv's own protection.
    @Test(
        "a watched class rv cannot see: stopped in every mode, as unanalyzable under observe",
        arguments: [
            (#"perl -e 'alarm 20; exec @ARGV' npx --no-install @smithery/cli --help"#, BuiltinRule.unwrapLimited),
            (#"bash -c "$(cat f)""#, .unwrapLimited),
            (#"eval "$X"; touch /etc/rv-watched"#, .outOfRepoWrite),
        ]
    )
    func opaqueClassStopsInEveryMode(command: String, rule: BuiltinRule) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision == .indeterminate(.observeUnanalyzable), "\(command)")
        #expect(observed.stoppedInEveryMode)
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision == .deny(Self.builtin(rule)), "\(command)")
    }

    @Test(
        "catastrophic commands and rv's own files stop in observe, as in enforce",
        arguments: [
            "rm -rf ~",
            "rm -rf /",
            "chmod -R 777 /",
            "cat ~/.config/rv/config.json",
            "echo x > ~/.claude/settings.json",
            "rv host mode claude off",
        ]
    )
    func stoppedInEveryMode(command: String) async throws {
        let place = try Self.place()
        defer { remove(place.observe); remove(place.enforce) }
        let observed = await Self.verdict(command, home: place.observe, cwd: place.cwd)
        #expect(observed.result.decision != .allow, "\(command)")
        #expect(observed.stoppedInEveryMode, "\(command)")
        let enforced = await Self.verdict(command, home: place.enforce, cwd: place.cwd)
        #expect(enforced.result.decision != .allow, "\(command)")
        #expect(enforced.stoppedInEveryMode == false)
    }

    // MARK: Helpers

    private static func builtin(_ rule: BuiltinRule) -> Deny {
        switch rule {
        case .unresolvedPath: ActionPolicyEngine.Builtin.unresolvedFilesystem
        case .outOfRepoWrite: ActionPolicyEngine.Builtin.outsideRepository
        case .unwrapLimited: ActionPolicyEngine.Builtin.unwrapLimited
        default: Deny(ruleID: rule.ruleID, reason: "")
        }
    }

    private static func denied(_ deny: Deny) -> EvaluationResult {
        EvaluationResult(outcome: .deny(deny, matched: nil))
    }

    private func floorRule(
        _ command: String, result: EvaluationResult, home: HomeDirectory? = nil
    ) -> ObserveFloor.Ruling {
        ObserveFloor.rule(
            result,
            door: .shell(ShellCommand(rawValue: command), store: .gather(home: home, cwd: nil)),
            context: ObserveFloor.Context(home: home, cwd: nil, rvdPIDs: { [] })
        )
    }

    /// An observe home, an enforce home and a repository cwd.
    private static func place() throws -> (observe: HomeDirectory, enforce: HomeDirectory, cwd: WorkingDirectory) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-watched-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true
        )
        return (
            try guardHome(mode: "observe"), try guardHome(mode: "enforce"),
            try #require(WorkingDirectory(validating: repo.path))
        )
    }

    private static func verdict(_ command: String, home: HomeDirectory, cwd: WorkingDirectory) async -> GatedVerdict {
        await GatedEvaluate().peekVerdict(
            command: ShellCommand(rawValue: command), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: now, allowlist: { AllowlistSnapshot(entries: []) }
        )
    }
}

/// `judge.mode` shadow (the default, Chris 2026-11-21): the judge scores
/// and logs, never decides.
@Suite("Judge shadow mode")
struct JudgeShadowModeTests {
    @Test("unset, shadow or unknown judge.mode selects a shadow judge; only live decides")
    func selectionFollowsConfig() throws {
        let cases: [(String, Bool)] = [
            ("{}", true),
            (#"{"judge":{"mode":"shadow"}}"#, true),
            (#"{"judge":{"mode":"bogus"}}"#, true),
            (#"{"judge":{"mode":"live"}}"#, false),
        ]
        for (json, shadow) in cases {
            let config = GuardConfig(jsonData: Data(json.utf8))
            #expect(JudgeRuntime.selection(home: nil, config: config).shadow == shadow, "\(json)")
        }
    }

    /// A blocking judge over a pack-allow: shadow allows and logs the
    /// judge's would-be; live blocks. Pack denies stand either way.
    @Test("shadow: a judge block never decides, and is logged as a would-be")
    func shadowLogsButNeverDecides() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let shadowed = await blockingJudge("brew list", home: home, shadow: true)
        #expect(shadowed.decision == .allow)
        let rows = try judgeLog(home)
        #expect(rows.count == 1)
        #expect(rows.first?["wouldBe"] as? String == "deny")

        let live = await blockingJudge("brew list", home: home, shadow: false)
        #expect(live.decision != .allow)

        let packDeny = await blockingJudge("git reset --hard", home: home, shadow: true)
        guard case .deny(let deny) = packDeny.decision else {
            Issue.record("a pack deny must stand under a shadow judge, got \(packDeny.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
    }

    private func blockingJudge(_ command: String, home: HomeDirectory, shadow: Bool) async -> EvaluationResult {
        let block: JudgeRuntime.JudgeRun
        do {
            block = .verdict(try effectVerdict(choice: "block", risk: 1.0))
        } catch {
            Issue.record("verdict: \(error)")
            return EvaluationResult(outcome: .plain)
        }
        let inputs = EvaluationInputs(
            guardMode: .enforce,
            judge: JudgeSelection(
                engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true),
                shadow: shadow
            ),
            store: .gather(home: home, cwd: nil)
        )
        return await GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: block)).gated(
            .apply,
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Date(timeIntervalSince1970: 1_800_000_000),
            allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs
        )
    }
}
