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
    @ObservationIgnored private var etiquette = GlanceEtiquette()
    /// Set by `start`; internal so tests can give a model a sink alone.
    @ObservationIgnored var notices: (any GlanceNoticeSink)?
    /// Deliveries run one after another, in the order they were planned.
    @ObservationIgnored private var delivery: Task<Void, Never>?
    /// Bumped by `stop`; deliveries planned before it are dropped.
    @ObservationIgnored private var deliveryGeneration = 0
    /// Between events the clock only moves idle labels along.
    static let idleTick: TimeInterval = 15

    public init(state: GlanceState? = nil, now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        self.state = state ?? GlanceState(now: now, calendar: calendar)
    }

    public var glyph: GlanceGlyph { state.glyph(at: now) }

    /// Starts polling rvd through `reader`, sending what the etiquette
    /// allows to `notices`. Calling it again restarts.
    public func start(
        reader: GlanceReader,
        notices: (any GlanceNoticeSink)? = nil,
        posture: @escaping @Sendable () -> GlancePosture
    ) {
        stop()
        self.notices = notices
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
        delivery?.cancel()
        deliveryGeneration &+= 1
        feedTask = nil
        clockTask = nil
        delivery = nil
    }

    private func publish(_ state: GlanceState) {
        let old = self.state
        self.state = state
        now = Date()
        notify(etiquette.plan(from: old, to: state, now: now))
        rescheduleClock()
    }

    /// Queues `actions` behind earlier deliveries. Internal for tests.
    func notify(_ actions: [GlanceNoticeAction]) {
        guard let notices, !actions.isEmpty else { return }
        let previous = delivery
        let generation = deliveryGeneration
        delivery = Task { [weak self] in
            await previous?.value
            // A stopped (or restarted) model posts nothing more: every link
            // still queued from before `stop` sees the generation move on.
            guard let self, !Task.isCancelled, generation == self.deliveryGeneration else { return }
            await notices.deliver(actions)
        }
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
