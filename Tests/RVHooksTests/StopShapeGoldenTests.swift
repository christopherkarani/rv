import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// B1 goldens: the exact bytes every host codec writes for four
/// representative stops, in a named owner's voice with pack advice. One
/// file per host under `Fixtures/stop-shape/`; a missing file is written
/// from the current output and fails the run, so a new host gets a golden
/// to review rather than a silent pass.
@Suite("Stop shape goldens")
struct StopShapeGoldenTests {
    /// The voice rvd speaks in on a Mac whose full name is "Chris Karani",
    /// with the advice the bundled packs carry for these rules.
    static let voice = StopVoice(owner: OwnerName(gecos: "Chris Karani,,,")) { rule in
        switch rule.rawValue {
        case "core.git:reset-hard":
            StopAdvice(saferCommand: "git status")
        case "core.filesystem:rm-rf-root-home":
            StopAdvice(whoActs: "you, in your own terminal, for your own files; an admin for system files")
        default:
            nil
        }
    }

    static func resetHard() -> EvaluationResult {
        let match = RuleMatch(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            severity: .critical,
            reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
        )
        return EvaluationResult(outcome: .deny(Deny(ruleID: match.ruleID, reason: match.reason), matched: match))
    }

    static func rmRfHome() -> EvaluationResult {
        let ruleID = RuleID(pack: PackID(rawValue: "core.filesystem"), pattern: "rm-rf-root-home")
        let reason = "rm -rf on root or home paths is EXTREMELY DANGEROUS. This command will NOT be executed. "
            + "Ask the user to run it manually if truly needed."
        let match = RuleMatch(ruleID: ruleID, severity: .critical, reason: reason)
        return EvaluationResult(outcome: .deny(Deny(ruleID: ruleID, reason: reason), matched: match))
    }

    /// The four stops: a minted unlock with a safer command, a stop the
    /// pack's `who_acts` routes, an unfinished check, and a timed-out rvd.
    static func stops(_ codec: any HostCodec) throws -> [(name: String, wire: HookWire)] {
        let code = try #require(AllowOnceUnlockCode(validating: "a7c835"))
        return [
            (
                "reset-hard, minted code",
                hookWire(
                    from: resetHard(), command: ShellCommand(rawValue: "git reset --hard origin/main"),
                    using: codec, intent: .firstCall(verdict: .ask, unlockCode: .code(code)), voice: voice)
            ),
            (
                "rm -rf home, who_acts",
                hookWire(
                    from: rmRfHome(), command: ShellCommand(rawValue: "rm -rf ~"),
                    using: codec, intent: .firstCall(verdict: .deny, unlockCode: nil), voice: voice)
            ),
            (
                "unresolved invocation",
                hookWire(
                    from: EvaluationResult(outcome: .indeterminate(.unresolvedInvocation)),
                    command: ShellCommand(rawValue: "$TOOL --apply"),
                    using: codec, intent: .firstCall(verdict: .deny, unlockCode: nil), voice: voice)
            ),
            ("rvd timed out", codec.encodeDeny(hookCallStopPresentation(.timedOut, voice: voice))),
        ]
    }

    static func render(_ stops: [(name: String, wire: HookWire)]) -> String {
        stops.map { stop in
            var block = "== \(stop.name)\nexit \(stop.wire.exitCode)\nstdout \(stop.wire.stdout)"
            if stop.wire.stdout.hasSuffix("\n") == false { block += "\n" }
            if stop.wire.stderr.isEmpty == false {
                block += "stderr \(stop.wire.stderr)"
                if stop.wire.stderr.hasSuffix("\n") == false { block += "\n" }
            }
            return block
        }.joined(separator: "\n")
    }

    static func goldenURL(_ host: HookHost) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stop-shape/\(host.rawValue).txt")
    }

    @Test(arguments: HookHost.allCases)
    func everyCodecWritesTheGolden(_ host: HookHost) throws {
        let actual = Self.render(try Self.stops(productionHostCodec(host)))
        let url = Self.goldenURL(host)
        guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("wrote a new golden for \(host); review it and run again")
            return
        }
        #expect(actual == golden, "\(host)")
    }

    /// The shape, checked apart from the bytes: every stop's text has the
    /// verdict line with its rule id, one why under ten words, at most one
    /// safer line, exactly one who line asking the owner by name, and no
    /// line telling the agent to run an unlock.
    @Test(arguments: HookHost.allCases)
    func everyStopHasTheShape(_ host: HookHost) throws {
        let codec = productionHostCodec(host)
        let code = try #require(AllowOnceUnlockCode(validating: "a7c835"))
        let notices = [
            stopNotice(
                command: ShellCommand(rawValue: "git reset --hard origin/main"),
                deny: Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x destroys things."),
                kind: .ask(recorded: true), unlock: .code(code), voice: Self.voice),
            indeterminateStopNotice(.commandTooLarge, command: nil, voice: Self.voice),
            hookCallStopNotice(.timedOut, voice: Self.voice),
        ]
        for notice in notices {
            let lines = notice.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(lines.first?.hasPrefix("✕ Stopped   ") == true)
            #expect(lines.first?.hasSuffix("(\(notice.rule))") == true)
            #expect(lines.filter { $0.hasPrefix("why     ") }.count == 1)
            #expect(notice.why.split(separator: " ").count <= stopWhyWordLimit)
            #expect(lines.filter { $0.hasPrefix("safer   ") }.count <= 1)
            #expect(lines.filter { $0.hasPrefix("who     ") }.count == 1)
            #expect(lines.last?.hasPrefix("who     ask Chris ") == true)
            #expect(notice.text.contains("\u{1B}") == false)
            // The agent is never the one told to unlock.
            for line in lines where line.hasPrefix("who     ") == false {
                #expect(line.contains("allow-once") == false)
                #expect(line.contains(" unlock") == false)
            }
            let wire = codec.encodeDeny(HookDenyPresentation(reason: notice.text, nextText: notice.who))
            #expect(wire.stdout.contains("\u{1B}") == false, "\(host)")
            #expect(wire.stderr.contains("\u{1B}") == false, "\(host)")
        }
    }
}
