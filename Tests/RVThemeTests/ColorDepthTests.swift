import Testing
@testable import RVTheme

private struct DepthCase: CustomTestStringConvertible {
    var name: String
    var environment: [String: String]
    var tty = true
    var depth: ColorDepth
    var testDescription: String { name }
}

private let depthCases: [DepthCase] = [
    DepthCase(name: "pipe", environment: ["COLORTERM": "truecolor"], tty: false, depth: .none),
    DepthCase(name: "NO_COLOR", environment: ["NO_COLOR": "1", "COLORTERM": "truecolor"], depth: .none),
    DepthCase(name: "empty NO_COLOR still counts", environment: ["NO_COLOR": ""], depth: .none),
    DepthCase(name: "dumb", environment: ["TERM": "dumb"], depth: .none),
    DepthCase(name: "override cannot beat NO_COLOR", environment: ["NO_COLOR": "1", "RV_COLOR_DEPTH": "truecolor"], depth: .none),
    DepthCase(name: "override down", environment: ["COLORTERM": "truecolor", "RV_COLOR_DEPTH": "16"], depth: .ansi16),
    DepthCase(name: "override up", environment: ["TERM": "xterm", "RV_COLOR_DEPTH": "256"], depth: .ansi256),
    DepthCase(name: "override none", environment: ["COLORTERM": "truecolor", "RV_COLOR_DEPTH": "none"], depth: .none),
    DepthCase(name: "unknown override is ignored", environment: ["TERM": "xterm-256color", "RV_COLOR_DEPTH": "lots"], depth: .ansi256),
    DepthCase(name: "COLORTERM truecolor", environment: ["TERM": "xterm-256color", "COLORTERM": "truecolor"], depth: .truecolor),
    DepthCase(name: "COLORTERM 24bit", environment: ["TERM": "screen", "COLORTERM": "24bit"], depth: .truecolor),
    DepthCase(name: "direct terminfo", environment: ["TERM": "xterm-direct"], depth: .truecolor),
    DepthCase(name: "iTerm without COLORTERM", environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "iTerm.app"], depth: .truecolor),
    DepthCase(name: "kitty", environment: ["TERM": "xterm-kitty"], depth: .truecolor),
    DepthCase(name: "Terminal.app", environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal"], depth: .ansi256),
    DepthCase(name: "tmux", environment: ["TERM": "tmux-256color", "TMUX": "/tmp/tmux-501/default,1,0"], depth: .ansi256),
    DepthCase(name: "plain xterm", environment: ["TERM": "xterm"], depth: .ansi16),
    DepthCase(name: "linux console", environment: ["TERM": "linux"], depth: .ansi16),
    DepthCase(name: "no TERM on a tty", environment: [:], depth: .ansi16),
]

@Test(arguments: depthCases)
private func colorDepth_detection(_ c: DepthCase) {
    #expect(ColorDepth(environment: c.environment, stdoutIsTTY: c.tty) == c.depth)
}

@Test func colorDepth_ordersFromNoneToTruecolor() {
    #expect(ColorDepth.allCases.sorted() == [.none, .ansi16, .ansi256, .truecolor])
}

@Test func xterm256_cubeAndRampValues() {
    #expect(Xterm256.color(at: 15) == nil)
    #expect(Xterm256.color(at: 16) == RGB24(red: 0, green: 0, blue: 0))
    #expect(Xterm256.color(at: 196) == RGB24(red: 255, green: 0, blue: 0))
    #expect(Xterm256.color(at: 231) == RGB24(red: 255, green: 255, blue: 255))
    #expect(Xterm256.color(at: 232) == RGB24(red: 8, green: 8, blue: 8))
    #expect(Xterm256.color(at: 255) == RGB24(red: 238, green: 238, blue: 238))
}

@Test func xterm256_exactColorsRoundTrip() {
    for index in UInt8(16)...UInt8(255) {
        guard let color = Xterm256.color(at: index) else {
            Issue.record("no colour at \(index)")
            continue
        }
        let back = Xterm256.nearest(color)
        #expect(Xterm256.color(at: back) == color, "index \(index) came back as \(back)")
    }
}

@Test func xterm256_greysStayGrey() {
    let mid = Xterm256.nearest(RGB24(hex: 0x808080))
    #expect(mid >= 232 || Xterm256.color(at: mid).map { $0.red == $0.green && $0.green == $0.blue } == true)
}

@Test func xterm256_inksKeepTheirHue() {
    // rv's stop red and ok green must not collapse to grey or swap hue.
    let stop = Xterm256.color(at: Xterm256.nearest(RGB24(hex: 0xFF7A7A)))
    let ok = Xterm256.color(at: Xterm256.nearest(RGB24(hex: 0x6EE7B7)))
    #expect(stop.map { $0.red > $0.green && $0.red > $0.blue } == true)
    #expect(ok.map { $0.green > $0.red && $0.green > $0.blue } == true)
}

@Test func terminalInk_sgrPerDepth() {
    let stop = TerminalInk(rgb: RGB24(hex: 0xFF7A7A), ansi16: 9)
    #expect(stop.foreground(.none) == nil)
    #expect(stop.foreground(.ansi16) == "91")
    #expect(stop.foreground(.ansi256) == "38;5;\(Xterm256.nearest(RGB24(hex: 0xFF7A7A)))")
    #expect(stop.foreground(.truecolor) == "38;2;255;122;122")
    #expect(stop.background(.ansi16) == "101")
    #expect(stop.background(.truecolor) == "48;2;255;122;122")
    let red = TerminalInk(rgb: RGB24(hex: 0xCF222E), ansi16: 1)
    #expect(red.foreground(.ansi16) == "31")
    #expect(red.background(.ansi16) == "41")
}

@Test func terminalInk_clampsTheSlot() {
    #expect(TerminalInk(rgb: RGB24(hex: 0), ansi16: 40).ansi16 == 15)
}
