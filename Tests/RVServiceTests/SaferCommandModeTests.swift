import Foundation
import Testing
import RVDomain
import RVHooks
import RVPacks
import RVPolicy
@testable import RVService

/// B1: a stop's `safer` line is a command rv allows in the mode that
/// stopped the original. Every bundled `safer_command` goes through the
/// full door (`GatedEvaluate`: packs, builtins, semantic guards, the
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

    /// Safer commands the full door still stops, in both modes: `cat
    /// /proc/mdstat` (every `system.disk` mdadm rule) is denied by
    /// `builtin.action:unresolved-path`, which the pack-only proof in
    /// `RuleGuidanceTests` does not run. Pack data to fix (G lane); pinned
    /// so the set cannot grow silently.
    static let saferCommandsTheDoorStops: Set<String> = [
        "system.disk:mdadm-create",
        "system.disk:mdadm-fail",
        "system.disk:mdadm-grow",
        "system.disk:mdadm-remove",
        "system.disk:mdadm-stop",
        "system.disk:mdadm-zero-superblock",
    ]

    @Test(arguments: [nil, "observe"] as [String?])
    func everySaferCommandAllowsInTheModeThatStopped(_ mode: String?) async throws {
        let home = try Self.home(mode: mode)
        defer { remove(home) }
        let cwd = try #require(WorkingDirectory(validating: home.rawValue))
        let safer = try Self.saferCommands()
        #expect(safer.isEmpty == false)
        var failures = 0
        var stopped: Set<String> = []
        for (rule, command) in safer {
            let verdict = await GatedEvaluate().peekVerdict(
                command: ShellCommand(rawValue: command), cwd: cwd, home: home,
                grants: EphemeralAllowOnceTable(), now: Self.now,
                allowlist: { AllowlistSnapshot(entries: []) }
            )
            // Under watch the door allows nearly everything; the safer
            // command must also be one enforce would allow, so the owner
            // never sees "would stop" for the advice itself.
            let wouldBe = verdict.wouldBe?.result.decision ?? verdict.result.decision
            if verdict.result.decision != .allow || wouldBe != .allow {
                stopped.insert(rule)
                if Self.saferCommandsTheDoorStops.contains(rule) { continue }
                failures += 1
                Issue.record("\(rule) suggests \(command): mode \(mode ?? "guard") gives \(verdict.result.decision), would be \(wouldBe)")
            }
        }
        #expect(failures == 0)
        #expect(stopped == Self.saferCommandsTheDoorStops, "fixed? drop it from saferCommandsTheDoorStops")
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
