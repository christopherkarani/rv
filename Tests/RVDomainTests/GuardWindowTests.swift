import Foundation
import Testing
import RVDomain

/// F3 (an agent's block that ends on its own) and H4 (`rv pause`): both are
/// a `GuardWindow` the resolution reads against the clock, so neither ever
/// needs a write, or rvd, to end.
@Suite("Guard windows")
struct GuardWindowTests {
    private static let start = Date(timeIntervalSince1970: 1_764_250_000)

    private static func config(_ json: String) throws -> GuardConfig {
        try #require(GuardConfig(validatingJSON: Data(json.utf8)))
    }

    private static func blockJSON(host: String = "claude", stored: String = "observe", from: Int, until: Int) -> String {
        #"{"guard":{"hosts":{"\#(host)":"\#(stored)"},"temporary_blocks":{"\#(host)":{"from":\#(from),"until":\#(until)}}}}"#
    }

    @Test func temporaryBlock_enforcesForOneHourThenTheStoredModeIsBack() throws {
        let from = Int(Self.start.timeIntervalSince1970)
        let config = try Self.config(Self.blockJSON(from: from, until: from + 3600))
        #expect(config.hosts[.claude] == .observe)
        let resolve = { (offset: TimeInterval) in
            GuardModeResolution.resolve(config, host: .claude, environment: [:], now: Self.start.addingTimeInterval(offset))
        }
        #expect(resolve(0) == .enforce)
        #expect(resolve(3599) == .enforce)
        // Expired: the stored observe, never stuck in block. A fresh read
        // (rvd restarted) resolves the same way; nothing needed rewriting.
        #expect(resolve(3600) == .observe)
        #expect(resolve(86_400) == .observe)
        // Other hosts are not touched.
        #expect(GuardModeResolution.resolve(config, host: .cursor, environment: [:], now: Self.start) == .enforce)
        #expect(config.temporaryBlock(for: .cursor, at: Self.start) == nil)
    }

    @Test func temporaryBlock_withNoStoredEntry_fallsBackToTheGlobalMode() throws {
        let from = Int(Self.start.timeIntervalSince1970)
        let json = #"{"guard":{"mode":"observe","temporary_blocks":{"codex":{"from":\#(from),"until":\#(from + 3600)}}}}"#
        let config = try Self.config(json)
        #expect(GuardModeResolution.resolve(config, host: .codex, environment: [:], now: Self.start) == .enforce)
        #expect(GuardModeResolution.resolve(config, host: .codex, environment: [:], now: Self.start.addingTimeInterval(3600)) == .observe)
    }

    /// A clock set back before the window, or a record stretched past the
    /// hour (by hand or a bad clock), reads as closed: a block never sticks.
    @Test(arguments: [
        (offset: -1.0, length: 3600),
        (offset: 10.0, length: 3601),
        (offset: 10.0, length: 86_400 * 365),
    ])
    func temporaryBlock_outsideOrOverlong_isClosed(offset: Double, length: Int) throws {
        let from = Int(Self.start.timeIntervalSince1970)
        let config = try Self.config(Self.blockJSON(from: from, until: from + length))
        let now = Self.start.addingTimeInterval(offset)
        #expect(config.temporaryBlock(for: .claude, at: now) == nil)
        #expect(GuardModeResolution.resolve(config, host: .claude, environment: [:], now: now) == .observe)
    }

    @Test(arguments: [
        #"{"from":10,"until":5}"#,
        #"{"from":10}"#,
        #"{"from":"10","until":"20"}"#,
        #"{"from":10.5,"until":20}"#,
        #""block""#,
    ])
    func malformedWindow_isNoWindow(_ window: String) throws {
        let json = #"{"guard":{"hosts":{"claude":"observe"},"temporary_blocks":{"claude":\#(window)},"pause":\#(window)}}"#
        let config = try Self.config(json)
        #expect(config.temporaryBlocks.isEmpty)
        #expect(config.pause == nil)
    }

    @Test func pause_observesEveryHostWhileOpen_thenTheStoredModesAreBack() throws {
        let from = Int(Self.start.timeIntervalSince1970)
        let json = #"{"guard":{"hosts":{"claude":"block"},"pause":{"from":\#(from),"until":\#(from + 600)}}}"#
        let config = try Self.config(json)
        for host in HookHost.allCases {
            #expect(GuardModeResolution.resolve(config, host: host, environment: [:], now: Self.start) == .observe)
        }
        #expect(GuardModeResolution.resolve(config, host: nil, environment: [:], now: Self.start) == .observe)
        let back = Self.start.addingTimeInterval(600)
        #expect(GuardModeResolution.resolve(config, host: .claude, environment: [:], now: back) == .enforce)
        #expect(GuardModeResolution.resolve(config, host: .cursor, environment: [:], now: back) == .enforce)
        // The stored posture never reads as paused.
        #expect(config.machineMode == .enforce)
    }

    @Test func pause_neverOutranksTheEnvironmentsEnforce() throws {
        let from = Int(Self.start.timeIntervalSince1970)
        let config = try Self.config(#"{"guard":{"pause":{"from":\#(from),"until":\#(from + 600)}}}"#)
        #expect(GuardModeResolution.resolve(
            config, host: .claude, environment: ["RV_GUARD_MODE": "enforce"], now: Self.start) == .enforce)
    }

    /// A pause can never last longer than the hour the owner may ask for,
    /// whatever the file says or the clock does.
    @Test func pause_overlongOrBeforeItStarts_isClosed() throws {
        let from = Int(Self.start.timeIntervalSince1970)
        let long = try Self.config(#"{"guard":{"pause":{"from":\#(from),"until":\#(from + 3601)}}}"#)
        #expect(long.activePause(at: Self.start.addingTimeInterval(1)) == nil)
        #expect(GuardModeResolution.resolve(long, host: .claude, environment: [:], now: Self.start.addingTimeInterval(1)) == .enforce)
        let normal = try Self.config(#"{"guard":{"pause":{"from":\#(from),"until":\#(from + 600)}}}"#)
        #expect(normal.activePause(at: Self.start.addingTimeInterval(-60)) == nil)
    }

    @Test func window_roundTripsOnWholeSeconds() {
        let window = GuardWindow(startingAt: Self.start.addingTimeInterval(0.75), lasting: 600)
        #expect(window.from == Self.start)
        #expect(window.until == Self.start.addingTimeInterval(600))
        #expect(GuardWindow(json: window.json) == window)
        #expect(window.secondsLeft(at: Self.start.addingTimeInterval(599.5)) == 1)
        #expect(window.secondsLeft(at: Self.start.addingTimeInterval(700)) == 0)
    }
}
