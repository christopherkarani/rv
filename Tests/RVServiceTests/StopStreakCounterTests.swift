import Foundation
import RVDomain
import RVHooks
@testable import RVService
import Testing

/// B5: rvd's in-memory count of one session's stops of one rule in a row.
struct StopStreakCounterTests {
    private static func key(_ session: String, rule: String = "core.git:reset-hard") -> StopStreakKey {
        StopStreakKey(host: .claude, session: SessionID(rawValue: session)!, rule: rule)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsInARow() {
        let counter = StopStreakCounter()
        #expect((0..<3).map { counter.record(Self.key("s"), now: start.addingTimeInterval(Double($0) * 30)) } == [1, 2, 3])
    }

    @Test func aLongQuiet_startsAgain() {
        let counter = StopStreakCounter()
        _ = counter.record(Self.key("s"), now: start)
        _ = counter.record(Self.key("s"), now: start.addingTimeInterval(60))
        #expect(counter.record(Self.key("s"), now: start.addingTimeInterval(60 + StopStreakCounter.window + 1)) == 1)
    }

    @Test func rulesAndSessionsCountApart() {
        let counter = StopStreakCounter()
        _ = counter.record(Self.key("s"), now: start)
        _ = counter.record(Self.key("s"), now: start)
        #expect(counter.record(Self.key("s", rule: "core.git:clean-force"), now: start) == 1)
        #expect(counter.record(Self.key("t"), now: start) == 1)
        #expect(counter.record(Self.key("s"), now: start) == 3)
    }

    @Test func staysBounded_forgettingTheOldest() {
        let counter = StopStreakCounter()
        _ = counter.record(Self.key("oldest"), now: start)
        _ = counter.record(Self.key("oldest"), now: start)
        for index in 0..<StopStreakCounter.maximumSessions {
            _ = counter.record(Self.key("s\(index)"), now: start.addingTimeInterval(Double(index + 1) * 0.001))
        }
        // Within the window: kept, it would read 3.
        #expect(counter.record(Self.key("oldest"), now: start.addingTimeInterval(1)) == 1)
    }
}
