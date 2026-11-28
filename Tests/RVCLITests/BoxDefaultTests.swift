import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import Testing
@testable import RVCLI

/// L5: boxed by default is opt-in (Q6), and turning it on or off is the
/// owner's alone: a terminal, then the owner check.
@Suite("rv box default")
struct BoxDefaultTests {
    /// A terminal with colour off, so the words compare as typed.
    static let plain = ["NO_COLOR": "1", "TERM": "xterm-256color"]

    @Test func itIsOffUntilTheOwnerTurnsItOn() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            try await BoxDefaultFlow.run(.show, supportsBoxes: true)
        }
        #expect(capture.stdout == """
            ◆ rv · boxed by default is off · agents start on your Mac
              → turn it on: rv box default on

            """)
        #expect(BoxDefaultSetting.isOn(home: home) == false)
        #expect(OpenCodeRun.startsBoxed(executable: nil, workspace: nil, home: home) == false)
    }

    @Test(arguments: [true, false])
    func withoutATerminalNothingChanges(on: Bool) async throws {
        let home = try isolatedHome()
        if on == false { try BoxDefaultSetting.write(true, home: home) }
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, ownerAuthOutcome: .authenticated, output: capture) {
            await #expect(throws: ExitCode(OwnerConfirmation.refusalExitCode)) {
                try await BoxDefaultFlow.run(.turn(on: on), supportsBoxes: true)
            }
        }
        let word = on ? "on" : "off"
        #expect(capture.stderr == """
            ✕ Only you can turn boxed by default \(word), at your terminal.
              → type it in Terminal: rv box default \(word)

            """)
        #expect(BoxDefaultSetting.isOn(home: home) == (on == false))
    }

    @Test func atATerminalItStillNeedsTheOwner() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, environment: Self.plain, stdinIsTTY: true, stdoutIsTTY: true, output: capture) {
            await #expect(throws: ExitCode(OwnerConfirmation.refusalExitCode)) {
                try await BoxDefaultFlow.run(.turn(on: true), supportsBoxes: true)
            }
        }
        #expect(capture.stderr.contains("turn boxed by default on needs owner authentication"))
        #expect(BoxDefaultSetting.isOn(home: home) == false)
    }

    @Test func theOwnerTurnsItOn_andHearsWhichAgentsItReaches() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(
            home: home, environment: Self.plain, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated, output: capture
        ) {
            try await BoxDefaultFlow.run(.turn(on: true), supportsBoxes: true)
        }
        #expect(capture.stdout == """
              ✓ Boxed by default. rv opencode starts in a box, and its changes come home as a review.
              ◐ claude isn't boxed yet: rv hears its tool calls, not its start · rv box claude boxes it
              ◐ codex isn't boxed yet: rv hears its tool calls, not its start · rv box codex boxes it
              ◐ cursor isn't boxed yet: it's an app, and rv can't start an app in a box
              → Undo: rv box default off

            """)
        #expect(BoxDefaultSetting.isOn(home: home))
        #expect(OpenCodeRun.startsBoxed(executable: nil, workspace: nil, home: home))
        // Typed flags keep the launch as typed.
        #expect(OpenCodeRun.startsBoxed(executable: "/opt/homebrew/bin/opencode", workspace: nil, home: home) == false)
        // The change is in the audit log, with how the owner was checked.
        let audit = try String(contentsOf: RVPolicyPaths.configDirectory(home: home).appendingPathComponent("audit.jsonl"), encoding: .utf8)
        #expect(audit.contains("box.default"))
        #expect(audit.contains(OwnerConfirmation.testAuthorization))

        let status = CLIOutputCapture()
        try await withCLIProcess(home: home, output: status) {
            try await BoxDefaultFlow.run(.show, supportsBoxes: true)
        }
        #expect(status.stdout == """
            ◆ rv · boxed by default is on · changes come home as a review
              ✓ opencode · rv opencode starts in a box
              ◐ claude isn't boxed yet: rv hears its tool calls, not its start · rv box claude boxes it
              ◐ codex isn't boxed yet: rv hears its tool calls, not its start · rv box codex boxes it
              ◐ cursor isn't boxed yet: it's an app, and rv can't start an app in a box
              → turn it off: rv box default off

            """)
    }

    @Test func theOwnerTurnsItOff() async throws {
        let home = try isolatedHome()
        try BoxDefaultSetting.write(true, home: home)
        let capture = CLIOutputCapture()
        try await withCLIProcess(
            home: home, environment: Self.plain, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated, output: capture
        ) {
            try await BoxDefaultFlow.run(.turn(on: false), supportsBoxes: true)
        }
        #expect(capture.stdout == """
              ✓ Agents start on your Mac again, outside a box.
              → Turn it back on: rv box default on

            """)
        #expect(BoxDefaultSetting.isOn(home: home) == false)
    }

    @Test func alreadyThereAsksNobody() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            try await BoxDefaultFlow.run(.turn(on: false), supportsBoxes: true)
        }
        #expect(capture.stdout == "  ✓ Boxed by default is already off.\n")
    }

    @Test func whereBoxesCantRunItWontTurnOn() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(
            home: home, environment: Self.plain, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated, output: capture
        ) {
            await #expect(throws: ExitCode(1)) {
                try await BoxDefaultFlow.run(.turn(on: true), supportsBoxes: false)
            }
        }
        #expect(capture.stderr.hasPrefix("✕ Boxes run on macOS only today"))
        #expect(BoxDefaultSetting.isOn(home: home) == false)
    }

    @Test func anUnreadableSettingIsOff() throws {
        let home = try isolatedHome()
        let url = BoxDefaultSetting.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(BoxDefaultSetting.isOn(home: home) == false)
    }

    @Test func theWordsParse() {
        #expect(BoxPlan.target(["default"]) == .success(.defaultSwitch(.show)))
        #expect(BoxPlan.target(["default", "on"]) == .success(.defaultSwitch(.turn(on: true))))
        #expect(BoxPlan.target(["default", "off"]) == .success(.defaultSwitch(.turn(on: false))))
        #expect(BoxPlan.target(["done"]) == .success(.done))
        #expect(BoxPlan.target(["done", "--help"]) == .success(.done))
        #expect(BoxPlan.target(["--", "done"]) == .success(.command("done", arguments: [])))
        guard case .failure(let maybe) = BoxPlan.target(["default", "maybe"]),
              case .failure(let extra) = BoxPlan.target(["done", "now"]),
              case .failure(let wall) = BoxPlan.target(["done", "--linux"])
        else {
            Issue.record("default, done and walls must refuse stray words")
            return
        }
        #expect(maybe.text == "✕ rv box default takes on or off.\n  → rv box default on\n")
        #expect(extra.text == "✕ rv box done takes no now.\n  → rv box done\n")
        #expect(wall.text == "✕ rv box done takes no --linux, --mac or --profile.\n  → rv box done\n")
        #expect(BoxPlan.checkFlags(linux: false, mac: true, profile: nil, target: .defaultSwitch(.show))?.text
            == "✕ rv box default takes no --linux, --mac or --profile.\n  → rv box default\n")
    }

    @Test func theBoxedLineIsTheOnlySign() {
        let launch = BoxLaunch(
            wall: .cage, project: "/Users/chris/code/app", executable: "/opt/homebrew/bin/opencode", arguments: [],
            hook: .opencode, profile: nil, keys: .placeholders(["ANTHROPIC_API_KEY"]))
        #expect(BoxPlan.boxedLine(launch, home: "/Users/chris")
            == "◆ boxed · ~/code/app · keys via rv · public HTTPS only\n")
        var keyless = launch
        keyless.keys = .none(next: "rv init")
        #expect(BoxPlan.boxedLine(keyless, home: "/Users/chris")
            == "◆ boxed · ~/code/app · no keys staged · public HTTPS only\n  → rv init\n")
        #expect(launch.agentName == "opencode")
    }
}
