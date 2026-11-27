#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import Observation
import RVGlance

/// The menu bar's one live view of rvd. It owns the polling task and the
/// clock the glyph reads; views bind it and never write to rvd.
@MainActor
@Observable
public final class GlanceModel {
    public private(set) var state: GlanceState
    public private(set) var now: Date
    public let calendar: Calendar

    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    /// Between events the clock only moves idle labels along.
    static let idleTick: TimeInterval = 15

    public init(state: GlanceState? = nil, now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        self.state = state ?? GlanceState(now: now, calendar: calendar)
    }

    public var glyph: GlanceGlyph { state.glyph(at: now) }

    /// Starts polling rvd through `reader`. Calling it again restarts.
    public func start(reader: GlanceReader, posture: @escaping @Sendable () -> GlancePosture) {
        stop()
        let calendar = calendar
        // The task holds the model until `stop` cancels it; the app keeps
        // one model for its whole life.
        feedTask = Task { [self] in
            var feed = GlanceFeed(reader: reader, calendar: calendar, posture: posture)
            await feed.run { state in
                await self.publish(state)
            }
        }
        rescheduleClock()
    }

    public func stop() {
        feedTask?.cancel()
        clockTask?.cancel()
        feedTask = nil
        clockTask = nil
    }

    private func publish(_ state: GlanceState) {
        self.state = state
        now = Date()
        rescheduleClock()
    }

    /// Wakes when the stop flash ends, else after `idleTick`.
    private func rescheduleClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextTick() else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }

    private func nextTick() -> TimeInterval {
        guard glyph == .justStopped, let stop = state.lastStop else { return Self.idleTick }
        let end = stop.at.addingTimeInterval(GlanceState.stopFlash).timeIntervalSince(now)
        return max(0.05, min(end, Self.idleTick))
    }
}
#endif
