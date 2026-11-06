#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import RVTheme

@Suite("Terminal background")
struct TerminalBackgroundTests {
    /// Scripted terminal: records what was asked, answers with `reply`.
    final class ScriptedChannel: TerminalQueryChannel {
        let reply: [UInt8]?
        private(set) var requests: [[UInt8]] = []

        init(reply: [UInt8]?) {
            self.reply = reply
        }

        convenience init(_ text: String) {
            self.init(reply: Array(text.utf8))
        }

        func exchange(_ request: [UInt8], timeout: Duration, isComplete: ([UInt8]) -> Bool) -> [UInt8]? {
            requests.append(request)
            return reply
        }
    }

    static let interactive = TTYPair(stdinIsTTY: true, stdoutIsTTY: true)
    static let colorful = OutputForbid(
        json: false, robot: false, plain: false, ci: false,
        noColor: OutputForbid.NoColor(flag: false, env: false, termDumb: false))
    static let da1 = "\u{1B}[?62;22c"

    // MARK: Reply grammar

    static let replies: [(String, Double, Double, Double)] = [
        ("\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\", 1.0, 1.0, 1.0),
        ("\u{1B}]11;rgb:0000/0000/0000\u{07}", 0.0, 0.0, 0.0),
        ("\u{1B}]11;rgb:ff/80/00\u{07}", 1.0, 128.0 / 255.0, 0.0),
        ("\u{1B}]11;rgb:f/8/0\u{07}", 1.0, 8.0 / 15.0, 0.0),
        ("\u{1B}]11;rgb:fff/800/000\u{07}", 1.0, 2048.0 / 4095.0, 0.0),
        ("\u{1B}]11;rgba:1e1e/2222/2a2a/ffff\u{1B}\\", 0x1E1E / 65535.0, 0x2222 / 65535.0, 0x2A2A / 65535.0),
        ("noise\u{1B}]11;rgb:FFFF/FFFF/FFFF\u{07}\u{1B}[?62c", 1.0, 1.0, 1.0),
    ]

    @Test(arguments: replies)
    func parsesBackgroundReplies(reply: String, red: Double, green: Double, blue: Double) throws {
        let color = try #require(BackgroundColorQuery.parseReply(Array(reply.utf8)))
        #expect(abs(color.red - red) < 1e-9)
        #expect(abs(color.green - green) < 1e-9)
        #expect(abs(color.blue - blue) < 1e-9)
    }

    @Test(arguments: [
        "",
        "\u{1B}[?62;22c",
        "\u{1B}]11;rgb:ffff/ffff/ffff",
        "\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}",
        "\u{1B}]11;rgb:ffff/ffff\u{07}",
        "\u{1B}]11;rgb:ffff/ffff/ffff/ffff\u{07}",
        "\u{1B}]11;rgb:fffff/0/0\u{07}",
        "\u{1B}]11;rgb:/0/0\u{07}",
        "\u{1B}]11;rgb:-1/0/0\u{07}",
        "\u{1B}]11;rgb:+f/0/0\u{07}",
        "\u{1B}]11;rgb:gg/0/0\u{07}",
        "\u{1B}]11;#ffffff\u{07}",
        "\u{1B}]10;rgb:ffff/ffff/ffff\u{07}",
        "\u{1B}]11;?\u{07}",
    ])
    func rejectsMalformedReplies(reply: String) {
        #expect(BackgroundColorQuery.parseReply(Array(reply.utf8)) == nil)
    }

    @Test func deviceAttributesReplyEndsTheExchange() {
        #expect(BackgroundColorQuery.isComplete(Array("\u{1B}]11;rgb:0/0/0\u{07}\u{1B}[?62;22c".utf8)))
        #expect(BackgroundColorQuery.isComplete(Array("\u{1B}[?1c".utf8)))
        #expect(BackgroundColorQuery.isComplete(Array("\u{1B}]11;rgb:0/0/0\u{07}".utf8)) == false)
        #expect(BackgroundColorQuery.isComplete(Array("\u{1B}[?62;22".utf8)) == false)
        #expect(BackgroundColorQuery.isComplete([]) == false)
    }

    @Test func requestAsksForTheBackgroundThenDeviceAttributes() {
        #expect(BackgroundColorQuery.request == Array("\u{1B}]11;?\u{1B}\\\u{1B}[c".utf8))
    }

    // MARK: Luminance

    static let backgrounds: [(TerminalColor, TerminalBackground)] = [
        (TerminalColor(red: 1, green: 1, blue: 1), .light),
        (TerminalColor(red: 0, green: 0, blue: 0), .dark),
        (TerminalColor(red: 0x1E / 255.0, green: 0x22 / 255.0, blue: 0x2A / 255.0), .dark), // Nord-ish
        (TerminalColor(red: 0xFD / 255.0, green: 0xF6 / 255.0, blue: 0xE3 / 255.0), .light), // Solarized light
        (TerminalColor(red: 0x00, green: 0x2B / 255.0, blue: 0x36 / 255.0), .dark), // Solarized dark
        (TerminalColor(red: 0.4, green: 0.4, blue: 0.4), .dark),
        (TerminalColor(red: 0.6, green: 0.6, blue: 0.6), .light),
        (TerminalColor(red: 0, green: 0, blue: 1), .dark), // pure blue is dark
        (TerminalColor(red: 0, green: 1, blue: 0), .light), // pure green is light
    ]

    @Test(arguments: backgrounds)
    func classifiesByPerceivedLightness(color: TerminalColor, expected: TerminalBackground) {
        #expect(color.background == expected)
    }

    @Test func lightnessEndpoints() {
        #expect(abs(TerminalColor(red: 1, green: 1, blue: 1).perceivedLightness - 100) < 1e-6)
        #expect(TerminalColor(red: 0, green: 0, blue: 0).perceivedLightness == 0)
        // sRGB 119/255 grey sits at L* ≈ 50.
        #expect(abs(TerminalColor(red: 119 / 255.0, green: 119 / 255.0, blue: 119 / 255.0).perceivedLightness - 50) < 0.5)
    }

    // MARK: Preference

    static let preferences: [([String: String], ThemePreference)] = [
        ([:], .automatic),
        (["RV_THEME": "dark"], .dark),
        (["RV_THEME": "LIGHT"], .light),
        (["RV_THEME": "auto"], .automatic),
        (["RV_THEME": "solarized"], .automatic),
    ]

    @Test(arguments: preferences)
    func readsThePreferenceFromTheEnvironment(environment: [String: String], expected: ThemePreference) {
        #expect(ThemePreference(environment: environment) == expected)
    }

    // MARK: Probe

    @Test func lightReplyGivesLight() {
        let channel = ScriptedChannel("\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\" + Self.da1)
        let background = BackgroundProbe.detect(
            preference: .automatic, terminal: Self.interactive, forbid: Self.colorful, channel: channel)
        #expect(background == .light)
        #expect(channel.requests == [BackgroundColorQuery.request])
    }

    @Test func darkReplyGivesDark() {
        let channel = ScriptedChannel("\u{1B}]11;rgb:1e1e/2222/2a2a\u{07}" + Self.da1)
        #expect(BackgroundProbe.detect(
            preference: .automatic, terminal: Self.interactive, forbid: Self.colorful, channel: channel) == .dark)
    }

    static let failedReplies: [String?] = [nil, "", da1, "\u{1B}]11;rgb:zz/zz/zz\u{07}"]

    @Test(arguments: failedReplies)
    func anyFailureKeepsDark(reply: String?) {
        let channel = ScriptedChannel(reply: reply.map { Array($0.utf8) })
        #expect(BackgroundProbe.detect(
            preference: .automatic, terminal: Self.interactive, forbid: Self.colorful, channel: channel) == .dark)
    }

    @Test func explicitPreferenceNeverAsks() {
        let channel = ScriptedChannel("\u{1B}]11;rgb:ffff/ffff/ffff\u{07}")
        #expect(BackgroundProbe.detect(
            preference: .dark, terminal: Self.interactive, forbid: Self.colorful, channel: channel) == .dark)
        #expect(BackgroundProbe.detect(
            preference: .light, terminal: TTYPair(stdinIsTTY: false, stdoutIsTTY: false),
            forbid: Self.colorful, channel: channel) == .light)
        #expect(channel.requests.isEmpty)
    }

    static func forbid(json: Bool = false, plain: Bool = false, ci: Bool = false, env: Bool = false, dumb: Bool = false)
        -> OutputForbid
    {
        OutputForbid(
            json: json, robot: false, plain: plain, ci: ci,
            noColor: OutputForbid.NoColor(flag: false, env: env, termDumb: dumb))
    }

    static let quietTerminals: [(TTYPair, OutputForbid)] = [
        (TTYPair(stdinIsTTY: false, stdoutIsTTY: true), colorful),
        (TTYPair(stdinIsTTY: true, stdoutIsTTY: false), colorful),
        (interactive, forbid(env: true)),
        (interactive, forbid(dumb: true)),
        (interactive, forbid(json: true)),
        (interactive, forbid(plain: true)),
        (interactive, forbid(ci: true)),
    ]

    @Test(arguments: quietTerminals)
    func neverAsksWithoutAnInteractiveColorTerminal(terminal: TTYPair, forbid: OutputForbid) {
        let channel = ScriptedChannel("\u{1B}]11;rgb:ffff/ffff/ffff\u{07}")
        #expect(BackgroundProbe.detect(
            preference: .automatic, terminal: terminal, forbid: forbid, channel: channel) == .dark)
        #expect(channel.requests.isEmpty)
    }

    @Test func unavailableChannelKeepsDark() {
        #expect(BackgroundProbe.detect(
            preference: .automatic, terminal: Self.interactive, forbid: Self.colorful,
            channel: UnavailableTerminalChannel()) == .dark)
    }

    @Test func probeDefaultsToDark() {
        #expect(ThemeProbe(terminal: Self.interactive, forbid: Self.colorful).background == .dark)
        #expect(ThemeProbe(terminal: Self.interactive, forbid: Self.colorful, background: .light).background == .light)
    }

    @Test func liveChannelRefusesNonTerminals() {
        // Test processes run with pipes, never the operator's terminal.
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer { _ = close(fds[0]); _ = close(fds[1]) }
        let channel = StandardTerminalChannel(input: fds[0], output: fds[1])
        #expect(channel.exchange(BackgroundColorQuery.request, timeout: .milliseconds(10)) { _ in true } == nil)
    }

    // MARK: Palette

    @Test func darkPaletteIsUnchanged() {
        let on = ColorCapability(colorsEnabled: true)
        #expect(Palette(for: on, background: .dark) == Palette(for: on))
        #expect(Palette(for: on).mark == "\u{001B}[1;33m")
    }

    @Test func lightPaletteDropsYellowAndBrightCyan() {
        let light = Palette(for: ColorCapability(colorsEnabled: true), background: .light)
        #expect(light.colorsEnabled)
        #expect(light != Palette(for: ColorCapability(colorsEnabled: true)))
        for ink in [light.mark, light.heading, light.allow, light.silver, light.regex.meta, light.regex.escape] {
            #expect(ink.contains("33m") == false && ink.contains("96m") == false && ink.contains("36m") == false)
        }
    }

    @Test func colorOffPaletteIgnoresBackground() {
        let off = ColorCapability(colorsEnabled: false)
        #expect(Palette(for: off, background: .light) == colorOffPalette)
    }
}
