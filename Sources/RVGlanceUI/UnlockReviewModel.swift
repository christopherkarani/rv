#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import Observation
import RVGlance
import RVIPC

/// The menu bar's unlock review (K2). A thin shell over `UnlockReview`: it
/// runs the reducer's commands through `UnlockReviewRunner` and keeps the
/// list fresh. Everything decisive is in the reducer and in rvd; this only
/// schedules.
@MainActor
@Observable
public final class UnlockReviewModel {
    public private(set) var review = UnlockReview()
    public private(set) var now = Date()

    @ObservationIgnored private let bridge: any UnlockBridge
    @ObservationIgnored private let authenticator: any UnlockAuthenticator
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Told each time the waiting asks change, so the Glance state and the
    /// banner etiquette can follow them.
    @ObservationIgnored public var onAsksChanged: (([String: GlanceUnlockAsk]) -> Void)?
    @ObservationIgnored private var lastAsks: [String: GlanceUnlockAsk] = [:]

    /// How often the list is re-read while nothing else prompts it.
    static let pollInterval: Duration = .seconds(4)

    public init(bridge: any UnlockBridge, authenticator: any UnlockAuthenticator) {
        self.bridge = bridge
        self.authenticator = authenticator
    }

    /// The sheet for the ask under review, if any.
    public var sheet: UnlockSheet? {
        review.onSheet.map { UnlockSheet($0.item, now: now) }
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.send(.refreshRequested)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Opens the sheet for one ask; `then` (from a banner's Allow once)
    /// starts Touch ID as soon as rvd binds the review.
    public func open(codeHash: String, then: UIUnlockDecision? = nil) {
        Task { await send(.openTapped(codeHash: codeHash, then: then)) }
    }

    public func allow(_ decision: UIUnlockDecision) {
        Task { await send(.allowTapped(decision)) }
    }

    public func deny() {
        Task { await send(.denyTapped) }
    }

    public func close() {
        Task { await send(.closeTapped) }
    }

    /// Each reduce is one short synchronous access; commands run between
    /// them, so the view can read `review` while a call is in flight.
    func send(_ event: UnlockReview.Event) async {
        now = Date()
        var queue = review.reduce(event)
        while !queue.isEmpty {
            let command = queue.removeFirst()
            if let reply = await UnlockReviewRunner.run(command, bridge: bridge, authenticator: authenticator) {
                now = Date()
                queue += review.reduce(reply)
            }
        }
        let asks = GlanceUnlockAsk.asks(from: review.waiting)
        if asks != lastAsks {
            lastAsks = asks
            onAsksChanged?(asks)
        }
    }
}
#endif
