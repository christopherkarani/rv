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

    public init(bridge: any UnlockBridge, authenticator: any UnlockAuthenticator) {
        self.bridge = bridge
        self.authenticator = authenticator
    }

    /// The sheet for the ask under review, if any, naming its challenge.
    public var sheet: UnlockSheet? {
        review.onSheet.map { UnlockSheet($0.item, challengeID: $0.challenge.challengeID, now: now) }
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.send(.refreshRequested)
                // 4 s while rvd answers; backs off to 5 minutes when it
                // refuses (an unpinned build) or is down.
                let delay = self?.review.pollDelay ?? .seconds(4)
                try? await Task.sleep(for: delay)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Opens the sheet for one ask. Touch ID waits for an Allow tap on it.
    public func open(codeHash: String) {
        Task { await send(.openTapped(codeHash: codeHash)) }
    }

    /// An Allow tap on the sheet that showed `challenge`.
    public func allow(_ decision: UIUnlockDecision, on challenge: UUID) {
        Task { await send(.allowTapped(challenge: challenge, decision)) }
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
