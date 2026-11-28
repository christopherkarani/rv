import Foundation
import RVDomain
import RVHooks
import Synchronization

/// B5: how many stops of one rule in a row one agent session has hit, in
/// rvd's memory.
///
/// A stop counts when it lands within `window` of the previous stop under
/// the same key; a longer quiet starts the count again. Nothing is written to disk
/// and nothing here decides a verdict: the count only adds the calm "stop
/// and ask" line to the third and later stops. Bounded: past
/// `maximumSessions` the oldest session is forgotten.
package final class StopStreakCounter: Sendable {
    package static let shared = StopStreakCounter()

    package static let window: TimeInterval = 10 * 60
    package static let maximumSessions = 512

    private struct Streak {
        var count: Int
        var last: Date
    }

    private let streaks = Mutex<[StopStreakKey: Streak]>([:])

    package init() {}

    /// Counts one stop for `key` at `now` and returns the streak, this
    /// stop included.
    package func record(_ key: StopStreakKey, now: Date) -> Int {
        streaks.withLock { streaks in
            var streak = streaks[key].flatMap { now.timeIntervalSince($0.last) <= Self.window ? $0 : nil }
                ?? Streak(count: 0, last: now)
            streak.count += 1
            streak.last = now
            streaks[key] = streak
            if streaks.count > Self.maximumSessions,
               let oldest = streaks.min(by: { $0.value.last < $1.value.last })?.key {
                streaks.removeValue(forKey: oldest)
            }
            return streak.count
        }
    }
}
