import Testing
import RVTheme
@testable import RVCLI

/// The CLI side of terminal-background detection: `RV_THEME`, the probe
/// channel, and the palette renderers get.
struct ThemeBackgroundWiringTests {
    /// Answers every query with `reply`; records nothing.
    struct Answering: TerminalQueryChannel {
        let reply: String

        func exchange(_ request: [UInt8], timeout: Duration, isComplete: ([UInt8]) -> Bool) -> [UInt8]? {
            Array(reply.utf8)
        }
    }

    static let whiteBackground = Answering(reply: "\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\\u{1B}[?62;22c")

    static func probe(
        tty: Bool, environment: [String: String], channel: any TerminalQueryChannel = UnavailableTerminalChannel()
    ) -> ThemeProbe {
        ThemeProbeFactory.make(
            jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false,
            stdinIsTTY: tty, stdoutIsTTY: tty, environment: environment, terminal: channel)
    }

    @Test func makeWithoutAChannelStaysDark() {
        #expect(Self.probe(tty: true, environment: [:]).background == .dark)
    }

    @Test func makeAsksTheChannelOnAnInteractiveTerminal() {
        #expect(Self.probe(tty: true, environment: [:], channel: Self.whiteBackground).background == .light)
        #expect(Self.probe(tty: false, environment: [:], channel: Self.whiteBackground).background == .dark)
        #expect(Self.probe(tty: true, environment: ["NO_COLOR": "1"], channel: Self.whiteBackground).background == .dark)
    }

    @Test func sshSessionsNeverQueryTheTerminal() {
        #expect(Self.probe(tty: true, environment: ["SSH_TTY": "/dev/ttys004"], channel: Self.whiteBackground)
            .background == .dark)
        #expect(Self.probe(tty: true, environment: ["SSH_CONNECTION": "a 1 b 22"], channel: Self.whiteBackground)
            .background == .dark)
        #expect(Self.probe(tty: true, environment: ["SSH_TTY": "/dev/ttys004", "RV_THEME": "light"])
            .background == .light)
    }

    @Test func rvThemeOverridesDetection() {
        #expect(Self.probe(tty: false, environment: ["RV_THEME": "light"]).background == .light)
        #expect(Self.probe(tty: true, environment: ["RV_THEME": "dark"], channel: Self.whiteBackground).background == .dark)
    }

    @Test func installedProcessContextNeverQueriesTheTerminal() throws {
        let probe = try withCLIProcess(environment: [:], stdinIsTTY: true, stdoutIsTTY: true) {
            ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false)
        }
        #expect(probe.background == .dark)
        let light = try withCLIProcess(environment: ["RV_THEME": "light"], stdinIsTTY: true, stdoutIsTTY: true) {
            ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false)
        }
        #expect(light.background == .light)
    }

    @Test func prettyAppearanceUsesTheProbeBackground() {
        let probe = Self.probe(tty: true, environment: ["RV_THEME": "light"])
        #expect(
            CommandContext.resolveAppearance(probe: probe, requested: .automatic)
                == .pretty(Palette(for: ColorCapability(colorsEnabled: true), background: .light))
        )
    }
}
