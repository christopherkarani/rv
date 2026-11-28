import Foundation
import RVDomain
@testable import RVHooks
import Testing

/// B5: rv notices the third try. From the third stop of one rule in a row
/// in one session, the stop carries one calm `again` line before `who`.
struct StopStreakTests {
    private static let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    private static let deny = EvaluationResult(outcome: .deny(
        Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes."), matched: nil))
    private static let command = ShellCommand(rawValue: "git reset --hard")

    private static func text(streak: Int, result: EvaluationResult = deny, command: String = "git reset --hard") -> String? {
        hostDenyText(
            from: result, command: ShellCommand(rawValue: command),
            voice: StopVoice(owner: OwnerName(gecos: "Chris Karani"), streak: streak))
    }

    @Test func firstAndSecondStops_carryNoNote() throws {
        for streak in [0, 1, 2] {
            let text = try #require(Self.text(streak: streak))
            #expect(text.contains("\nagain ") == false)
        }
        #expect(stopStreakNote(2) == nil)
    }

    @Test func thirdStop_saysSoCalmlyBeforeWho() throws {
        let text = try #require(Self.text(streak: 3))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.suffix(2).first == "again   3 tries stopped by this rule. Rephrasing won't get through.")
        #expect(lines.last?.hasPrefix("who     ") == true)
        #expect(try #require(Self.text(streak: 7)).contains("again   7 tries stopped by this rule."))
    }

    /// Acceptance: still one instruction, the rule id, and no way past.
    @Test(arguments: [
        deny,
        EvaluationResult(outcome: .indeterminate(.selfProtection)),
        EvaluationResult(outcome: .indeterminate(.unresolvedInvocation)),
    ])
    func noteAddsNoSecondInstruction(_ result: EvaluationResult) throws {
        let text = try #require(Self.text(streak: 3, result: result, command: "rv uninstall"))
        #expect(text.components(separatedBy: "\nwho ").count == 2)
        #expect(text.contains("\nagain ") == true)
        let again = try #require(text.split(separator: "\n").first { $0.hasPrefix("again") })
        #expect(again.contains("rv ") == false)
        #expect(again.contains("allow-once") == false && again.contains("unlock") == false)
    }

    @Test func fileStop_carriesTheNoteToo() {
        let text = fileStopNotice(
            path: FileToolPath(rawValue: "/Users/c/.ssh/id_ed25519"),
            deny: Deny(ruleID: RuleID(pack: .coreSecrets, pattern: "ssh-key"), reason: "x"),
            voice: StopVoice(owner: .unknown, streak: 4)).text
        #expect(text.contains("\nagain   4 tries stopped by this rule."))
    }

    // MARK: - Counting through the hook door

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [StopStreakKey: Int] = [:]
        private(set) var keys: [StopStreakKey] = []
        func record(_ key: StopStreakKey) -> Int {
            lock.lock(); defer { lock.unlock() }
            keys.append(key)
            counts[key, default: 0] += 1
            return counts[key]!
        }
        var all: [StopStreakKey] { lock.lock(); defer { lock.unlock() }; return keys }
    }

    private static func payload(_ command: String, session: String?) -> String {
        var object: [String: Any] = [
            "hook_event_name": "PreToolUse", "cwd": "/tmp", "tool_name": "Bash",
            "tool_input": ["command": command],
        ]
        if let session { object["session_id"] = session }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func world(_ tally: Tally, result: EvaluationResult = deny) -> HookEvaluateWorld {
        var world = hookWorld(evaluate: { _, _ in result })
        world.countStop = { tally.record($0) }
        return world
    }

    @Test func thirdStopInOneSession_getsTheNote() async {
        let tally = Tally()
        var outputs: [String] = []
        for command in ["git reset --hard", "git reset --hard HEAD", "git  reset --hard"] {
            let wire = await hookWire(host: .claude, stdin: Self.payload(command, session: "s1"), world: Self.world(tally))
            outputs.append(wire.stdout + wire.stderr)
        }
        #expect(outputs[0].contains("tries stopped by this rule") == false)
        #expect(outputs[1].contains("tries stopped by this rule") == false)
        #expect(outputs[2].contains("3 tries stopped by this rule"))
        #expect(tally.all.map(\.rule) == Array(repeating: Self.rule.rawValue, count: 3))
        #expect(Set(tally.all.map(\.host)) == [.claude])
    }

    @Test func anotherSession_startsItsOwnCount() async {
        let tally = Tally()
        for session in ["a", "a", "b"] {
            _ = await hookWire(host: .claude, stdin: Self.payload("git reset --hard", session: session), world: Self.world(tally))
        }
        let wire = await hookWire(host: .claude, stdin: Self.payload("git reset --hard", session: "b"), world: Self.world(tally))
        #expect((wire.stdout + wire.stderr).contains("tries stopped by this rule") == false)
    }

    @Test func noSessionOrAnAllow_countsNothing() async {
        let tally = Tally()
        for _ in 0..<3 {
            _ = await hookWire(host: .claude, stdin: Self.payload("git reset --hard", session: nil), world: Self.world(tally))
            _ = await hookWire(
                host: .claude, stdin: Self.payload("git status", session: "s1"),
                world: Self.world(tally, result: EvaluationResult(outcome: .plain)))
        }
        #expect(tally.all.isEmpty)
    }
}
