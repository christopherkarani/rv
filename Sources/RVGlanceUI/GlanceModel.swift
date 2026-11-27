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

    /// Plain-English lines already worked out, by request. Display only.
    private var plainLines: [PlainRequest: PlainLine] = [:]

    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private let explainer: any PlainExplainer
    @ObservationIgnored private var etiquette = GlanceEtiquette()
    /// Set by `start`; internal so tests can give a model a sink alone.
    @ObservationIgnored var notices: (any GlanceNoticeSink)?
    /// Deliveries run one after another, in the order they were planned.
    @ObservationIgnored private var delivery: Task<Void, Never>?
    /// Bumped by `stop`; deliveries planned before it are dropped.
    @ObservationIgnored private var deliveryGeneration = 0
    /// Between events the clock only moves idle labels along.
    static let idleTick: TimeInterval = 15
    static let plainCacheLimit = 32

    public init(
        state: GlanceState? = nil, now: Date = Date(), calendar: Calendar = .current,
        explainer: (any PlainExplainer)? = nil
    ) {
        self.now = now
        self.calendar = calendar
        self.state = state ?? GlanceState(now: now, calendar: calendar)
        self.explainer = explainer ?? Self.defaultExplainer()
    }

    public var glyph: GlanceGlyph { state.glyph(at: now) }

    /// The last stop's plain line once worked out; nil until then (the
    /// row shows the template line meanwhile).
    public var lastStopPlain: PlainLine? {
        state.lastStop.flatMap { plainLines[PlainRequest($0)] }
    }

    /// The on-device model behind the template, where this Mac has one.
    static func defaultExplainer() -> any PlainExplainer {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), PlainOnDeviceExplainer.isAvailable {
            return PlainFallback(primary: PlainOnDeviceExplainer())
        }
        #endif
        return PlainTemplate()
    }

    /// Works out the last stop's line in the background, once per request.
    func explainLastStop() {
        guard let stop = state.lastStop else { return }
        let request = PlainRequest(stop)
        // Every publish calls this; one session per request, not per publish.
        guard plainLines[request] == nil, !explaining.contains(request) else { return }
        explaining.insert(request)
        let explainer = explainer
        Task { [weak self] in
            let line = await explainer.explain(request)
            self?.explaining.remove(request)
            self?.remember(line, for: request)
        }
    }

    /// Requests being worked out now. Internal for tests.
    @ObservationIgnored var explaining: Set<PlainRequest> = []

    private func remember(_ line: PlainLine, for request: PlainRequest) {
        if plainLines.count >= Self.plainCacheLimit { plainLines.removeAll() }
        plainLines[request] = line
    }

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
        explainLastStop()
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
