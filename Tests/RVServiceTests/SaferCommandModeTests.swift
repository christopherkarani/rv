import Foundation
import Testing
import RVDomain
import RVHooks
import RVPacks
import RVPolicy
@testable import RVService

/// B1: a stop's `safer` line is a command rv allows in the mode that
/// stopped the original. The hook door vets the pack's `safer_command`
/// before it shows it (`GatedEvaluate.allowsSaferCommand`); here every
/// bundled one goes through that vet and through the full door (`GatedEvaluate`: packs, builtins, semantic guards, the
/// observe floor) in guard mode and in watch mode, with every catalog pack
/// on except `strict_git` (it denies even `--force-with-lease` by design;
/// `RuleGuidanceTests` pins the per-pack proof).
@Suite("Safer commands allow in the same mode")
struct SaferCommandModeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func saferCommands() throws -> [(rule: String, command: String)] {
        try PackRegistry.loadAllDocuments().flatMap { document in
            document.guidance.compactMap { guidance in
                guidance.saferCommand.map { (guidance.ruleID.rawValue, $0) }
            }
        }
    }

    private static func home(mode: String?) throws -> HomeDirectory {
        let home = try guardHome(mode: mode)
        let packs = try PackRegistry.loadAllDocuments().map(\.id.rawValue).filter { $0 != "strict_git" }
        try PacksConfigStore.save(PacksConfig(enabled: packs), home: home)
        return home
    }

    private static func allowsInBothModes(_ command: String, cwd: WorkingDirectory, home: HomeDirectory) async -> Bool {
        let verdict = await GatedEvaluate().peekVerdict(
            command: ShellCommand(rawValue: command), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        // Under watch the door allows nearly everything; the safer command
        // must also be one enforce would allow, so the owner never sees
        // "would stop" for the advice itself.
        let wouldBe = verdict.wouldBe?.result.decision ?? verdict.result.decision
        return verdict.result.decision == .allow && wouldBe == .allow
    }

    /// Every safer command a stop shows is one the full door allows, in
    /// guard and in watch mode: the vet agrees with the door on every
    /// bundled one and drops the rest (here `cat /proc/mdstat` outside a
    /// repository, which `builtin.action:unresolved-path` stops), so no
    /// rule is pinned.
    @Test(arguments: [nil, "observe"] as [String?])
    func everyShownSaferCommandAllowsInTheModeThatStopped(_ mode: String?) async throws {
        let home = try Self.home(mode: mode)
        defer { remove(home) }
        let cwd = try #require(WorkingDirectory(validating: home.rawValue))
        let safer = try Self.saferCommands()
        #expect(safer.isEmpty == false)
        var shown = 0
        for (rule, command) in safer {
            let vetted = await GatedEvaluate().allowsSaferCommand(
                ShellCommand(rawValue: command), cwd: cwd, home: home, now: Self.now)
            let allowed = await Self.allowsInBothModes(command, cwd: cwd, home: home)
            #expect(vetted == allowed, "\(rule) suggests \(command): vet \(vetted), door \(allowed) in \(mode ?? "guard")")
            if vetted { shown += 1 }
        }
        #expect(shown > 0)
    }

    /// The vet never reaches the judge: with a judge bundle selected (so
    /// the door would ask it about most safer commands, as the control run
    /// shows), in guard and in watch mode, it makes no judge call, waits on
    /// no slot and logs nothing. Only `cat /proc/mdstat` (the six mdadm
    /// rules, outside a repository) is left out.
    @Test(arguments: [GuardMode.enforce, .observe])
    func theVetNeverReachesTheJudge(_ mode: GuardMode) async throws {
        let home = try Self.home(mode: mode == .observe ? "observe" : nil)
        defer { remove(home) }
        let cwd = try #require(WorkingDirectory(validating: home.rawValue))
        let bundle = URL(fileURLWithPath: home.rawValue).appendingPathComponent("laya-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let inputs = EvaluationInputs(
            guardMode: mode, judge: JudgeSelection(engine: .ft, bundle: bundle, shadow: false),
            store: .gather(home: home, cwd: cwd))
        let safer = try Self.saferCommands()

        // Control: the same door, deciding as usual, does ask the judge.
        let control = CountingJudge()
        let judged = GatedEvaluate(EvaluateSession(), judge: control)
        for (_, command) in safer {
            _ = await judged.decideVerdict(
                .peek, GatedEvaluate.makeRequest(command: ShellCommand(rawValue: command), home: home),
                cwd: cwd, home: home, grants: EphemeralAllowOnceTable(), now: Self.now,
                allowlist: { AllowlistSnapshot(entries: []) }, host: .tty, tool: .bash,
                previewsWouldBe: true, inputs: inputs)
        }
        #expect(control.calls > 0)

        let counting = CountingJudge()
        let door = GatedEvaluate(EvaluateSession(), judge: counting)
        var dropped: Set<String> = []
        for (rule, command) in safer {
            let shown = await door.allowsSaferCommand(
                ShellCommand(rawValue: command), cwd: cwd, home: home, now: Self.now, inputs: inputs)
            if shown == false { dropped.insert(rule) }
        }
        #expect(counting.calls == 0)
        #expect(dropped == Self.mdadmRules, "\(dropped.sorted())")
    }

    /// `cat /proc/mdstat`, outside a repository, is stopped by
    /// `builtin.action:unresolved-path`: the vet leaves these out.
    private static let mdadmRules: Set<String> = [
        "system.disk:mdadm-create", "system.disk:mdadm-fail", "system.disk:mdadm-grow",
        "system.disk:mdadm-remove", "system.disk:mdadm-stop", "system.disk:mdadm-zero-superblock",
    ]

    /// End to end through rvd's hook door: a stop whose safer command rv
    /// allows shows it; one whose safer command rv would stop shows none.
    @Test func theHookDoorShowsOnlyAllowedSaferCommands() async throws {
        let home = try Self.home(mode: nil)
        defer { remove(home) }
        let cwd = try #require(WorkingDirectory(validating: home.rawValue))
        let live = LiveEvaluateWorld(home: home, clock: { Self.now }, allowlist: { _, _ in .empty })
        let world = HookEvaluateWorld.live(world: live, host: .claude, pending: nil, clock: { Self.now })
        func stop(_ command: String) async throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": home.rawValue,
                "tool_input": ["command": command],
            ])
            let reply = try await HookDoor.run(
                host: .claude, stdin: String(decoding: data, as: UTF8.self), world: world,
                deadline: HookDeadline(budget: .seconds(600)))
            return reply.stdout
        }
        let mdadm = try #require(try Self.saferCommands().first { $0.rule == "system.disk:mdadm-zero-superblock" })
        #expect(await Self.allowsInBothModes(mdadm.command, cwd: cwd, home: home) == false)
        let zero = try await stop("mdadm --zero-superblock /dev/sdb1")
        #expect(zero.contains("system.disk/mdadm-zero-superblock"), "\(zero)")
        #expect(zero.contains("\\nsafer   ") == false, "\(zero)")
        let reset = try await stop("git reset --hard")
        #expect(reset.contains("core.git/reset-hard"), "\(reset)")
        #expect(reset.contains("\\nsafer   git status\\n"), "\(reset)")
    }

    @Test func liveVoiceReadsTheBundledAdvice() throws {
        let resetHard = try #require(RuleID(rawValue: "core.git:reset-hard"))
        #expect(StopVoice.live.advice(resetHard)?.saferCommand == "git status")
        let rmRf = try #require(RuleID(rawValue: "core.filesystem:rm-rf-root-home"))
        #expect(StopVoice.live.advice(rmRf)?.whoActs?.hasPrefix("you") == true)
        // A builtin, an indeterminate id or an unknown pack has no pack JSON.
        #expect(StopVoice.live.advice(ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID) == nil)
        #expect(StopVoice.live.advice(RuleID(pack: PackID(rawValue: "no.such-pack"), pattern: "x")) == nil)
        #expect(StopVoice.live.advice(RuleID(pack: PackID(rawValue: "../core.git"), pattern: "reset-hard")) == nil)
    }

    /// Every bundled rule's stop says why in under ten words, one line,
    /// and never in the words of a way past rv.
    @Test func everyRuleWhyIsUnderTenWords() throws {
        for document in try PackRegistry.loadAllDocuments() {
            for rule in document.destructive {
                let why = stopWhy(rule.reason, command: nil)
                #expect(why.isEmpty == false, "\(document.id.rawValue):\(rule.name)")
                #expect(why.split(separator: " ").count <= stopWhyWordLimit, "\(document.id.rawValue):\(rule.name) \(why)")
                #expect(why.contains("\n") == false)
                #expect(why.lowercased().contains("allow-once") == false)
            }
        }
    }

    @Test func everyBundledSaferCommandPrintsAsOneLine() throws {
        for (rule, command) in try Self.saferCommands() {
            let id = try #require(RuleID(rawValue: rule))
            let notice = stopNotice(
                command: ShellCommand(rawValue: "x"),
                deny: Deny(ruleID: id, reason: "x"),
                voice: StopVoice(owner: .unknown, advice: { _ in StopAdvice(saferCommand: command) })
            )
            #expect(notice.safer == command, "\(rule)")
            #expect(notice.text.split(separator: "\n").count == 4, "\(rule)")
        }
    }
}

/// A judge that counts its calls and answers unavailable.
private final class CountingJudge: JudgePort, Sendable {
    private let count = UnfairLock(0)
    var calls: Int { count.withLock { $0 } }

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        count.withLock { $0 += 1 }
        return .unavailable("counted")
    }
}
