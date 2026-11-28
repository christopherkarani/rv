import Foundation

/// A stretch of wall-clock time a guard change holds for, stored in
/// `config.json` as whole Unix seconds: `{"from": 1764250000, "until": 1764253600}`.
///
/// Two changes use one: an agent's block of a host that expires on its own
/// (`guard.temporary_blocks.<host>`), and the owner's `rv pause`
/// (`guard.pause`). Neither ever overwrites the mode it covers, so when the
/// window closes nothing has to be restored: the stored mode was there all
/// along. The window is open only from `from` up to `until` and only when it
/// is no longer than its kind allows: a clock set back before `from`, or a
/// record stretched past the limit, reads as closed, so a block can never
/// stick and a pause can never last longer than the owner asked.
public struct GuardWindow: Sendable, Equatable {
    public var from: Date
    public var until: Date

    /// The longest an agent's block of a host lasts (Q4, 2026-11-27).
    public static let temporaryBlockLimit: TimeInterval = 60 * 60
    /// After an agent's block of a host ends, how long before another
    /// agent's block of it may start without the owner.
    public static let temporaryBlockCooldown: TimeInterval = 6 * 60 * 60
    /// The longest `rv pause` lasts.
    public static let pauseLimit: TimeInterval = 60 * 60

    public init(from: Date, until: Date) {
        self.from = from
        self.until = until
    }

    /// `duration` seconds from `now`, both on whole seconds (what the file
    /// keeps), so a written window reads back equal.
    public init(startingAt now: Date, lasting duration: TimeInterval) {
        let start = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        self.init(from: start, until: start.addingTimeInterval(duration.rounded(.down)))
    }

    /// True while `now` is inside the window and the window is no longer
    /// than `limit`.
    public func isOpen(at now: Date, limit: TimeInterval) -> Bool {
        from <= now && now < until && until.timeIntervalSince(from) <= limit
    }

    /// This window cut short at `now` (whole seconds), still a valid
    /// record: the cooldown then counts from `now`.
    public func ended(at now: Date) -> GuardWindow {
        let end = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return GuardWindow(from: min(from, end.addingTimeInterval(-1)), until: end)
    }

    /// Whole seconds left at `now`, 0 once closed.
    public func secondsLeft(at now: Date) -> Int {
        max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// The stored form.
    public var json: JSONValue {
        .object([
            "from": .number(from.timeIntervalSince1970.rounded(.down)),
            "until": .number(until.timeIntervalSince1970.rounded(.down)),
        ])
    }

    /// Decodes the stored form; nil unless both keys are whole seconds and
    /// `from` is before `until`.
    public init?(json: JSONValue?) {
        guard let json,
              let from = json["from"]?.int,
              let until = json["until"]?.int,
              from < until
        else { return nil }
        self.init(from: Date(timeIntervalSince1970: TimeInterval(from)), until: Date(timeIntervalSince1970: TimeInterval(until)))
    }
}
