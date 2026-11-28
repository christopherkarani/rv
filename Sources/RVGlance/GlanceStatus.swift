import Foundation
import RVIPC

/// The one sentence Siri speaks and Spotlight shows for rv's state.
public enum GlanceStatusSentence {
    public static func make(_ state: GlanceState, now: Date, calendar: Calendar) -> String {
        let glyph = state.glyph(at: now)
        switch glyph {
        case .connecting:
            return "rv is connecting to rvd — nothing is confirmed yet"
        case .notRunning:
            return "rv isn't running — agents are unguarded"
        default:
            break
        }
        var parts = [lead(glyph), detail(GlanceHeadline(state, now: now, calendar: calendar))]
        if state.link == .live {
            let checked = GlanceHeadline.plural(state.today.checked, "command")
            parts.append("\(checked) checked, \(state.today.stopped) stopped today")
        }
        return parts.joined(separator: " · ")
    }

    static func lead(_ glyph: GlanceGlyph) -> String {
        switch glyph {
        case .guarding: "rv is guarding"
        case .watching: "rv is watching"
        case .needsYou: "rv needs you"
        case .justStopped: "rv just stopped a command"
        case .boxed: "rv is guarding a box"
        case .paused: "rv is paused"
        case .notRunning: "rv isn't running"
        case .connecting: "rv is connecting to rvd"
        }
    }

    /// The headline's subtitle without "rvd healthy", which a sentence needn't say.
    static func detail(_ headline: GlanceHeadline) -> String {
        let healthy = " · " + GlanceHeadline.rvdWords(.live)
        guard headline.subtitle.hasSuffix(healthy) else { return headline.subtitle }
        return String(headline.subtitle.dropLast(healthy.count))
    }
}

extension GlanceReader {
    /// One read for a status question: the asks, then every event rvd still
    /// holds, without waiting. Read-only, like everything the reader does.
    public func status(
        now: Date, calendar: Calendar, posture: GlancePosture = .guarding
    ) async -> GlanceState {
        var state = GlanceState(now: now, calendar: calendar)
        state.posture = posture
        switch await pendingAsks() {
        case .success(let asks):
            state.replacePending(asks)
        case .failure(let failure):
            state.markDown(failure.reason, at: now)
            return state
        }
        if case .success(let ids) = await pendingProposals() { state.replaceProposals(ids) }
        switch await events(EventsParams(after: 0, waitMs: 0)) {
        case .events(let reply):
            state.apply(reply, now: now, calendar: calendar)
        case .unsupported:
            state.link = .liveWithoutEvents
        case .down(let reason):
            state.markDown(reason, at: now)
        }
        return state
    }
}

/// What App Intents reach: a read-only reader and the freeze control.
/// Nothing here can thaw, resolve an ask, or change a rule or mode.
public struct GlanceIntentServices: Sendable {
    /// Said when the app hasn't handed intents a reader.
    public static let notConnected = "rv's menu bar app isn't connected to rvd yet"
    /// Before the app sets them up: no reader, and no freeze.
    public static let unconnected = GlanceIntentServices(reader: nil)

    public var reader: GlanceReader?
    public var freeze: any GlanceFreezeControl
    public var calendar: Calendar
    public var posture: @Sendable () -> GlancePosture

    public init(
        reader: GlanceReader?,
        freeze: any GlanceFreezeControl = UnavailableFreezeControl(),
        calendar: Calendar = .current,
        posture: @escaping @Sendable () -> GlancePosture = { .guarding }
    ) {
        self.reader = reader
        self.freeze = freeze
        self.calendar = calendar
        self.posture = posture
    }

    public func statusSentence(now: Date) async -> String {
        guard let reader else { return Self.notConnected }
        let state = await reader.status(now: now, calendar: calendar, posture: posture())
        return GlanceStatusSentence.make(state, now: now, calendar: calendar)
    }

    public func freezeAll(origin: GlanceFreezeOrigin) async -> GlanceFreezeOutcome {
        await freeze.freezeAll(origin: origin)
    }

    /// Runs what the planner allows for a Focus change: a freeze on start
    /// if asked for, nothing on end.
    public func focusChanged(
        _ filter: GlanceFocusFilter, _ transition: GlanceFocusTransition
    ) async -> [GlanceFreezeOutcome] {
        var outcomes: [GlanceFreezeOutcome] = []
        for action in GlanceFocusPlanner.actions(for: filter, on: transition) {
            switch action {
            case .freeze: outcomes.append(await freeze.freezeAll(origin: .focus))
            }
        }
        return outcomes
    }
}
